import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(GrokIslandCore)
@testable import GrokIslandCore
#else
@testable import GrokIsland
#endif

/// Canned Cursor API: answers by "METHOD /path" and records every request.
private final class StubTransport: HTTPTransport, @unchecked Sendable {
    typealias Handler = (URLRequest) -> (Int, String)

    private let lock = NSLock()
    private var handler: Handler
    private(set) var requests: [URLRequest] = []

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, body) = record(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }

    private func record(_ request: URLRequest) -> (Int, String) {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        return handler(request)
    }

    func requests(matching path: String) -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests.filter { $0.url?.path == path }
    }
}

private func route(_ request: URLRequest) -> String {
    "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
}

private func jsonBody(_ request: URLRequest) -> [String: Any] {
    guard let data = request.httpBody,
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return object
}

final class OriginPRParserTests: XCTestCase {
    func testStaleAndCheckStates() throws {
        let json = """
        [
          {"number": 3, "title": "Old fix", "url": "https://cursor.com/codebase/o/r/pull/3", "headRef": "cursor/a",
           "ciState": {"checkRunGroups": [{"checkRuns": [{"status": "completed", "conclusion": "success"}]}]},
           "mergeability": {"mergeable": false, "mergeability": {"blockers": [{"kind": "nothing-to-merge"}]}}},
          {"number": 5, "title": "New feature", "url": "https://cursor.com/codebase/o/r/pull/5", "headRef": "cursor/b",
           "ciState": {"checkRunGroups": [{"checkRuns": [{"status": "in_progress"}]}]},
           "mergeability": {"mergeable": true, "mergeability": {"blockers": []}}},
          {"number": 6, "title": "Broken", "ciState": {"checkRunGroups": [{"checkRuns": [{"status": "completed", "conclusion": "failure"}]}]}},
          {"number": 7, "title": "No CI"}
        ]
        """
        let prs = try OriginPRParser.parse(Data(json.utf8))
        XCTAssertEqual(prs.map(\.number), [3, 5, 6, 7])
        XCTAssertEqual(prs.map(\.isStale), [true, false, false, false])
        XCTAssertEqual(prs.map(\.checks), [.passed, .running, .failed, CheckState.none])
        XCTAssertEqual(prs[1].headRef, "cursor/b")
    }

    func testRejectsNonArray() {
        XCTAssertThrowsError(try OriginPRParser.parse(Data(#"{"error":"nope"}"#.utf8)))
    }
}

@MainActor
final class CloudActivityMonitorTests: XCTestCase {
    private func storage(withKey key: String?) throws -> IslandSettingsStorage {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrokIslandSettings-\(UUID().uuidString)", isDirectory: true)
        let storage = IslandSettingsStorage(folder: folder, defaultsSuite: "GrokIslandTests-\(UUID().uuidString)")
        try storage.saveAPIKey(key)
        return storage
    }

    func testRefreshFiltersAndFlashesOnChange() async throws {
        let agents = [
            CloudAgentSummary(id: "bc-1", name: "Busy", status: "ACTIVE"),
            CloudAgentSummary(id: "bc-2", name: "Done", status: "IDLE")
        ]
        let prs = [
            PullRequestActivity(number: 1, title: "stale", checks: .passed, isStale: true),
            PullRequestActivity(number: 2, title: "live", checks: .running, isStale: false)
        ]
        let monitor = CloudActivityMonitor(
            storage: try storage(withKey: "crsr_test"),
            fetchAgents: { credentials in
                XCTAssertEqual(credentials.apiKey, "crsr_test")
                return agents
            },
            fetchPRs: { _ in prs }
        )
        await monitor.refresh()
        XCTAssertEqual(monitor.snapshot.agents.map(\.id), ["bc-1"])
        XCTAssertEqual(monitor.snapshot.pullRequests.map(\.number), [2])
        XCTAssertEqual(monitor.snapshot.stalePullRequests.map(\.number), [1])
        XCTAssertEqual(monitor.snapshot.busyCount, 2)
        XCTAssertEqual(monitor.flashCount, 1)

        await monitor.refresh()
        XCTAssertEqual(monitor.flashCount, 1, "same activity should not blink again")

        monitor.apply(CloudActivitySnapshot(updatedAt: Date()))
        XCTAssertEqual(monitor.flashCount, 2, "finishing work blinks once")
        XCTAssertFalse(monitor.snapshot.isBusy)
    }

    func testKeySavedMidRefreshRefetchesWithNewKey() async throws {
        let storage = try storage(withKey: nil)
        let seenKeys = StringRecorder()
        let monitor = CloudActivityMonitor(
            storage: storage,
            fetchAgents: { credentials in
                await seenKeys.add(credentials.apiKey)
                return [CloudAgentSummary(id: "bc-1", status: "ACTIVE")]
            },
            fetchPRs: { _ in
                try await Task.sleep(for: .milliseconds(80))
                return []
            }
        )
        let inFlight = Task { await monitor.refresh() }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(monitor.isRefreshing)

        try storage.saveAPIKey("crsr_new")
        monitor.refreshSoon(minimumAge: 0)
        await inFlight.value

        let keys = await seenKeys.values
        XCTAssertEqual(keys, ["crsr_new"])
        XCTAssertEqual(monitor.snapshot.agents.map(\.id), ["bc-1"])
        XCTAssertNil(monitor.snapshot.agentNote)
        XCTAssertFalse(monitor.isRefreshing)
    }

    func testMissingKeyAndPRFailureAreNotes() async throws {
        let monitor = CloudActivityMonitor(
            storage: try storage(withKey: nil),
            fetchAgents: { _ in
                XCTFail("should not call the API without a key")
                return []
            },
            fetchPRs: { _ in throw IslandError.executorFailed("no origin") }
        )
        await monitor.refresh()
        XCTAssertEqual(monitor.snapshot.agentNote, "未设置 Cursor API key")
        XCTAssertEqual(monitor.snapshot.prNote, "no origin")
        XCTAssertEqual(monitor.flashCount, 0)
    }
}

final class IslandSettingsStorageTests: XCTestCase {
    func testAPIKeyRoundTripIsPrivate() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrokIslandKey-\(UUID().uuidString)", isDirectory: true)
        let storage = IslandSettingsStorage(folder: folder, defaultsSuite: "GrokIslandTests-\(UUID().uuidString)")
        XCTAssertNil(storage.credentials())

        try storage.saveAPIKey("  crsr_abc \n")
        XCTAssertEqual(storage.loadAPIKey(), "crsr_abc")
        let attributes = try FileManager.default.attributesOfItem(
            atPath: folder.appendingPathComponent("cursor-api-key").path
        )
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        XCTAssertEqual(storage.prRepo, IslandSettingsStorage.defaultPRRepo)
        storage.grokModelID = " grok-x "
        XCTAssertEqual(storage.credentials(), CursorCredentials(apiKey: "crsr_abc", modelID: "grok-x"))

        try storage.saveAPIKey(nil)
        XCTAssertNil(storage.loadAPIKey())
    }
}

final class CursorAgentGrokClientTests: XCTestCase {
    private func request(images: [PromptImage] = []) -> ExecutionRequest {
        let module = FunctionModule(name: "解答题目", prompt: "解答附图题目", executor: .grokBot)
        return ExecutionRequest(module: module, resources: [], extraPrompt: "网址：https://example.com", local: nil, images: images)
    }

    func testCreatesAgentPollsAndReturnsAnswer() async throws {
        var polls = 0
        let transport = StubTransport { request in
            switch route(request) {
            case "GET /v1/models":
                return (200, #"{"items":[{"id":"composer-2"},{"id":"grok-4.7","displayName":"Grok 4.7"}]}"#)
            case "POST /v1/agents":
                return (200, """
                {"agent":{"id":"bc-9","name":"NewIsland","status":"ACTIVE","url":"https://cursor.com/agents/bc-9"},
                 "run":{"id":"run-1","agentId":"bc-9","status":"CREATING"}}
                """)
            case "GET /v1/agents/bc-9/runs/run-1":
                polls += 1
                return polls < 2
                    ? (200, #"{"id":"run-1","status":"RUNNING"}"#)
                    : (200, ####"{"id":"run-1","status":"FINISHED","result":"### 第 1 题\n答案：42"}"####)
            default:
                return (404, #"{"error":{"message":"unexpected"}}"#)
            }
        }
        let client = CursorAgentGrokClient(
            credentials: { CursorCredentials(apiKey: "crsr_test", modelID: "") },
            transport: transport,
            pollInterval: .milliseconds(1)
        )
        let png = PromptImage(data: Data([0x89, 0x50, 0x4E, 0x47]), mimeType: "image/png")
        let links = StringRecorder()
        let result = try await client.execute(request(images: [png])) { progress in
            if let link = progress.link { await links.add(link) }
        }

        XCTAssertEqual(result.summary, "第 1 题")
        XCTAssertEqual(result.detail, "### 第 1 题\n答案：42")
        XCTAssertEqual(result.link, "https://cursor.com/agents/bc-9")
        let seenLinks = await links.values
        XCTAssertTrue(seenLinks.contains("https://cursor.com/agents/bc-9"))

        let create = try XCTUnwrap(transport.requests(matching: "/v1/agents").first)
        XCTAssertEqual(create.value(forHTTPHeaderField: "Authorization"), "Bearer crsr_test")
        let body = jsonBody(create)
        XCTAssertEqual((body["model"] as? [String: Any])?["id"] as? String, "grok-4.7")
        XCTAssertNil(body["repos"], "answers run on a no-repo agent")
        let prompt = try XCTUnwrap(body["prompt"] as? [String: Any])
        let text = try XCTUnwrap(prompt["text"] as? String)
        XCTAssertTrue(text.contains("解答附图题目"))
        XCTAssertTrue(text.contains("https://example.com"))
        XCTAssertTrue(text.contains("不要创建分支或 PR"))
        let images = try XCTUnwrap(prompt["images"] as? [[String: Any]])
        XCTAssertEqual(images.first?["mimeType"] as? String, "image/png")
        XCTAssertEqual(images.first?["data"] as? String, png.data.base64EncodedString())
    }

    func testExplicitModelSkipsModelLookup() async throws {
        let transport = StubTransport { request in
            switch route(request) {
            case "POST /v1/agents":
                return (200, #"{"agent":{"id":"bc-1","status":"ACTIVE"},"run":{"id":"run-1","status":"FINISHED","result":"ok"}}"#)
            default:
                return (500, "")
            }
        }
        let client = CursorAgentGrokClient(
            credentials: { CursorCredentials(apiKey: "k", modelID: "grok-custom") },
            transport: transport,
            pollInterval: .milliseconds(1)
        )
        let result = try await client.execute(request()) { _ in }
        XCTAssertEqual(result.detail, "ok")
        XCTAssertTrue(transport.requests(matching: "/v1/models").isEmpty)
        let body = jsonBody(try XCTUnwrap(transport.requests(matching: "/v1/agents").first))
        XCTAssertEqual((body["model"] as? [String: Any])?["id"] as? String, "grok-custom")
    }

    func testFailuresSurfaceAsErrors() async {
        let noKey = CursorAgentGrokClient(credentials: { nil })
        do {
            _ = try await noKey.execute(request()) { _ in }
            XCTFail("expected missing-key error")
        } catch let error as IslandError {
            XCTAssertTrue(error.localizedDescription.contains("API key"))
        } catch {
            XCTFail("unexpected \(error)")
        }

        let unauthorized = CursorAgentGrokClient(
            credentials: { CursorCredentials(apiKey: "bad", modelID: "grok") },
            transport: StubTransport { _ in (401, #"{"error":{"message":"Unauthorized"}}"#) }
        )
        do {
            _ = try await unauthorized.execute(request()) { _ in }
            XCTFail("expected HTTP error")
        } catch let error as CursorAPIError {
            XCTAssertEqual(error, .http(status: 401, message: "Unauthorized"))
        } catch {
            XCTFail("unexpected \(error)")
        }

        let errored = CursorAgentGrokClient(
            credentials: { CursorCredentials(apiKey: "k", modelID: "grok") },
            transport: StubTransport { _ in
                (200, #"{"agent":{"id":"bc-1","status":"ACTIVE"},"run":{"id":"run-1","status":"ERROR"}}"#)
            }
        )
        do {
            _ = try await errored.execute(request()) { _ in }
            XCTFail("expected run error")
        } catch let error as IslandError {
            XCTAssertTrue(error.localizedDescription.contains("ERROR"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testModelPickerPrefersGrok() {
        XCTAssertEqual(GrokModelPicker.choose(from: [
            CloudModel(id: "composer-2", displayName: "Composer 2"),
            CloudModel(id: "grok-4.7", displayName: "Grok 4.7")
        ]), "grok-4.7")
        XCTAssertEqual(GrokModelPicker.choose(from: [CloudModel(id: "x-1", displayName: "xAI Grok")]), "x-1")
        XCTAssertNil(GrokModelPicker.choose(from: [CloudModel(id: "composer-2", displayName: nil)]))
    }
}

private actor StringRecorder {
    private(set) var values: [String] = []
    func add(_ value: String) { values.append(value) }
}

final class GrokPromptBuilderTests: XCTestCase {
    func testAttachesImagesAndInlinesText() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrokPrompt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let picture = folder.appendingPathComponent("page.png")
        try Data([1, 2, 3]).write(to: picture)
        let notes = folder.appendingPathComponent("notes.py")
        try Data("print('hi')".utf8).write(to: notes)

        let module = FunctionModule(name: "检查", prompt: "检查代码", executor: .grokBot)
        let request = ExecutionRequest(
            module: module,
            resources: [
                ResourceItem(kind: .file, name: "page.png", location: picture.path),
                ResourceItem(kind: .file, name: "notes.py", location: notes.path),
                ResourceItem(kind: .url, name: "ex", location: "https://example.com/x")
            ],
            extraPrompt: nil,
            local: nil
        )
        let payload = GrokPromptBuilder.build(request)
        XCTAssertEqual(payload.images, [PromptImage(data: Data([1, 2, 3]), mimeType: "image/png")])
        XCTAssertTrue(payload.text.hasPrefix("检查代码"))
        XCTAssertTrue(payload.text.contains("```py\nprint('hi')\n```"))
        XCTAssertTrue(payload.text.contains("- 链接：https://example.com/x"))
        XCTAssertTrue(payload.text.contains("已附上 1 张图片"))
    }

    func testHeadlineSkipsMarkdownMarks() {
        XCTAssertEqual(GrokPromptBuilder.headline(of: "\n\n## **总结**\n正文"), "总结")
        XCTAssertEqual(GrokPromptBuilder.headline(of: "- 第一条"), "第一条")
        XCTAssertNil(GrokPromptBuilder.headline(of: "  \n "))
    }
}

/// Records what the engine hands to Grok without any network.
private struct CapturingExecutor: ModuleExecuting {
    let seen: RequestBox
    var kind: ExecutorKind { .grokBot }

    func run(
        _ request: ExecutionRequest,
        progress: @escaping @Sendable (ExecutionProgress) async -> Void
    ) async throws -> ExecutionResult {
        await seen.store(request)
        await progress(ExecutionProgress(fraction: 0.5, message: "working", link: "https://cursor.com/agents/bc-x"))
        return ExecutionResult(summary: "done", detail: "full answer", link: "https://cursor.com/agents/bc-x")
    }
}

private actor RequestBox {
    private(set) var request: ExecutionRequest?
    func store(_ request: ExecutionRequest) { self.request = request }
}

@MainActor
final class QuickActionEngineTests: XCTestCase {
    private func makeEngine(_ grok: ModuleExecuting) throws -> IslandEngine {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrokIslandQuick-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return IslandEngine(
            moduleStore: ModuleStore(fileURL: folder.appendingPathComponent("m.json")),
            inbox: ResourceInbox(),
            journal: RunJournal(),
            grokBot: grok,
            local: LocalExecutor()
        )
    }

    func testRequiresPageOrQuestion() async throws {
        let engine = try makeEngine(GrokBotExecutor(instant: true))
        let empty = PageSnapshot(captureNote: "需要屏幕录制权限")
        XCTAssertThrowsError(try engine.runQuickAction(.solveProblems, page: empty)) { error in
            XCTAssertEqual(error as? IslandError, .pageCaptureFailed("需要屏幕录制权限"))
        }
        XCTAssertThrowsError(try engine.runQuickAction(.askAboutPage, page: empty, question: "  ")) { error in
            XCTAssertEqual(error as? IslandError, .emptyInput)
        }
        XCTAssertTrue(engine.runs.isEmpty)
    }

    func testSendsScreenshotAndContextThenStoresAnswer() async throws {
        let box = RequestBox()
        let engine = try makeEngine(CapturingExecutor(seen: box))
        let shot = PromptImage(data: Data([9, 9]), mimeType: "image/png")
        let page = PageSnapshot(
            appName: "Safari",
            windowTitle: "期中试卷",
            pageURL: "https://example.com/exam",
            screenshot: shot
        )
        let record = try engine.runQuickAction(.organizeMistakes, page: page, question: "重点看第 3 题")
        XCTAssertEqual(record.moduleName, "整理错题")

        try await waitFor { engine.runs.first?.phase == .succeeded }
        let run = try XCTUnwrap(engine.runs.first)
        XCTAssertEqual(run.resultSummary, "full answer")
        XCTAssertEqual(run.link, "https://cursor.com/agents/bc-x")

        let captured = await box.request
        let sent = try XCTUnwrap(captured)
        XCTAssertEqual(sent.images, [shot])
        XCTAssertEqual(sent.module.prompt, GrokQuickAction.organizeMistakes.prompt)
        let extra = try XCTUnwrap(sent.extraPrompt)
        XCTAssertTrue(extra.contains("Safari — 期中试卷"))
        XCTAssertTrue(extra.contains("https://example.com/exam"))
        XCTAssertTrue(extra.contains("我的问题：重点看第 3 题"))
    }

    func testURLOnlyPageStillRuns() async throws {
        let engine = try makeEngine(GrokBotExecutor(instant: true))
        let page = PageSnapshot(appName: "Chrome", pageURL: "https://example.com/code", captureNote: "截图失败")
        XCTAssertNoThrow(try engine.runQuickAction(.reviewPageCode, page: page))
        XCTAssertTrue(page.contextDescription?.contains("没有截到页面图片") ?? false)
    }

    private func waitFor(timeout: TimeInterval = 1.0, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out")
    }
}
