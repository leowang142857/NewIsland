import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(GrokIslandCore)
@testable import GrokIslandCore
#else
@testable import GrokIsland
#endif

/// Canned Cloud Agents API for the split-task orchestrator.
private final class SplitAPI: HTTPTransport, @unchecked Sendable {
    struct Script: Sendable {
        var plannerResult: String
        var workerResult: @Sendable (String) -> (String, String?)
        var summaryResult: String?
        var summaryStatus: Int = 200
        var workerDelay: Duration = .milliseconds(1)
    }

    private let lock = NSLock()
    private let script: Script
    private var requests: [URLRequest] = []
    private var inFlightWorkers = 0
    private var maxInFlightWorkers = 0
    private var seq = 0

    init(_ script: Script) {
        self.script = script
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        let name = (jsonObject(request)["name"] as? String) ?? ""
        let isWorker = begin(request, name: name, method: method, path: path)
        if isWorker {
            try await Task.sleep(for: script.workerDelay)
        }
        let response = finish(name: name, method: method, path: path, isWorker: isWorker)
        let http = HTTPURLResponse(url: request.url!, statusCode: response.0, httpVersion: nil, headerFields: nil)!
        return (Data(response.1.utf8), http)
    }

    func snapshot() -> (requests: [URLRequest], maxInFlightWorkers: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (requests, maxInFlightWorkers)
    }

    private func begin(_ request: URLRequest, name: String, method: String, path: String) -> Bool {
        let isWorker = method == "POST" && path == "/v1/agents" && name.contains("子任务")
        lock.lock()
        requests.append(request)
        if isWorker {
            inFlightWorkers += 1
            maxInFlightWorkers = max(maxInFlightWorkers, inFlightWorkers)
        }
        lock.unlock()
        return isWorker
    }

    private func finish(name: String, method: String, path: String, isWorker: Bool) -> (Int, String) {
        lock.lock()
        defer { lock.unlock() }
        if isWorker { inFlightWorkers -= 1 }
        return makeResponse(method: method, path: path, name: name)
    }

    private func makeResponse(method: String, path: String, name: String) -> (Int, String) {
        guard method == "POST", path == "/v1/agents" else {
            return (404, #"{"error":{"message":"unexpected"}}"#)
        }
        seq += 1
        let id = "bc-\(seq)"
        if name.contains("规划") {
            return (200, agentJSON(id: id, status: "FINISHED", result: script.plannerResult))
        }
        if name.contains("汇总") {
            if script.summaryStatus != 200 {
                return (script.summaryStatus, #"{"error":{"message":"summary down"}}"#)
            }
            return (200, agentJSON(id: id, status: "FINISHED", result: script.summaryResult ?? "汇总完成"))
        }
        if name.contains("子任务") {
            let (status, result) = script.workerResult(name)
            return (200, agentJSON(id: id, status: status, result: result))
        }
        return (404, #"{"error":{"message":"unknown agent"}}"#)
    }

    private func agentJSON(id: String, status: String, result: String?) -> String {
        var run: [String: Any] = ["id": "run-\(id)", "agentId": id, "status": status]
        if let result { run["result"] = result }
        let object: [String: Any] = [
            "agent": [
                "id": id,
                "name": "n",
                "status": "ACTIVE",
                "url": "https://cursor.com/agents/\(id)"
            ],
            "run": run
        ]
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }
}

private func jsonObject(_ request: URLRequest) -> [String: Any] {
    guard let data = request.httpBody,
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return object
}

private func promptText(_ body: [String: Any]) -> String {
    (body["prompt"] as? [String: Any])?["text"] as? String ?? ""
}

private func posts(_ api: SplitAPI) -> [[String: Any]] {
    api.snapshot().requests
        .filter { $0.httpMethod == "POST" && $0.url?.path == "/v1/agents" }
        .map(jsonObject)
}

private func orchestrator(_ api: SplitAPI) -> CursorSplitTaskOrchestrator {
    CursorSplitTaskOrchestrator(
        credentials: { CursorCredentials(apiKey: "crsr_test", modelID: "grok-test") },
        transport: api,
        pollInterval: .milliseconds(1)
    )
}

private func planJSON(_ titles: [String]) -> String {
    let items = titles.map { #"{"title":"\#($0)","prompt":"做\#($0)"}"# }.joined(separator: ",")
    return """
    ```json
    {"subtasks":[\(items)]}
    ```
    """
}

final class SplitPlanParserTests: XCTestCase {
    func testReadsFencedJSONAndClampsToFour() throws {
        let plan = try SplitPlanParser.parse(planJSON(["一", "二", "三", "四", "五"]))
        XCTAssertEqual(plan.subtasks.map(\.title), ["一", "二", "三", "四"])
        XCTAssertEqual(plan.subtasks.map(\.prompt), ["做一", "做二", "做三", "做四"])
    }

    func testRejectsASingleSubtask() {
        XCTAssertThrowsError(try SplitPlanParser.parse(#"{"subtasks":[{"title":"只有","prompt":"一个"}]}"#)) { error in
            XCTAssertTrue(String(describing: error).contains("不足") || (error as? LocalizedError)?.errorDescription?.contains("不足") == true)
        }
    }
}

final class SplitTaskSummaryTests: XCTestCase {
    func testFailureMarkStaysWhenNarrativeOmitsIt() {
        let text = SplitTaskSummary.compose(
            task: "写报告",
            outcomes: [
                SplitSubtaskOutcome(title: "调研", prompt: "收集", succeeded: true, text: "发现 A", link: nil),
                SplitSubtaskOutcome(title: "起草", prompt: "写", succeeded: false, text: "超时", link: "https://cursor.com/agents/bc-x")
            ],
            narrative: "一切顺利，没有问题。"
        )
        XCTAssertTrue(text.contains("一切顺利"))
        XCTAssertTrue(text.contains("发现 A"))
        XCTAssertTrue(text.contains("起草 \(SplitTaskSummary.failedMark)"))
        XCTAssertTrue(text.contains("超时"))
        XCTAssertTrue(text.contains("https://cursor.com/agents/bc-x"))
        XCTAssertEqual(SplitTaskSummary.headline(for: [
            SplitSubtaskOutcome(title: "调研", prompt: "p", succeeded: true, text: "ok", link: nil),
            SplitSubtaskOutcome(title: "起草", prompt: "p", succeeded: false, text: "超时", link: nil)
        ]), "1/2 完成，1 个失败")
    }
}

final class SplitOrchestratorTests: XCTestCase {
    func testPlanClampsPlannerOutputToFourAgents() async throws {
        let api = SplitAPI(.init(
            plannerResult: planJSON(["一", "二", "三", "四", "五"]),
            workerResult: { _ in ("FINISHED", "做好了") },
            summaryResult: "四件事都完成了"
        ))
        let result = try await orchestrator(api).collaborate(
            SplitTaskRequest(task: "准备发布", resources: [], images: []),
            callbacks: .ignore
        )

        let created = posts(api)
        let names = created.compactMap { $0["name"] as? String }
        XCTAssertEqual(names.filter { $0.contains("子任务") }.count, 4)
        XCTAssertFalse(names.contains { $0.contains("五") })
        XCTAssertTrue(names.contains(CursorSplitTaskOrchestrator.plannerName))
        XCTAssertTrue(names.contains(CursorSplitTaskOrchestrator.summaryName))
        let planner = try XCTUnwrap(created.first { ($0["name"] as? String)?.contains("规划") == true })
        XCTAssertEqual((planner["model"] as? [String: Any])?["id"] as? String, "grok-test")
        XCTAssertNil(planner["repos"])
        XCTAssertTrue(promptText(planner).contains("准备发布"))
        XCTAssertEqual(result.outcomes.map(\.title), ["一", "二", "三", "四"])
        XCTAssertTrue(result.markdown.contains("四件事都完成了"))
    }

    func testPlanRejectsFewerThanTwoSubtasks() async {
        let api = SplitAPI(.init(
            plannerResult: #"{"subtasks":[{"title":"只有","prompt":"一个"}]}"#,
            workerResult: { _ in ("FINISHED", "不应该跑") }
        ))
        do {
            _ = try await orchestrator(api).collaborate(
                SplitTaskRequest(task: "太小", resources: [], images: []),
                callbacks: .ignore
            )
            XCTFail("expected the planner result to be rejected")
        } catch let error as IslandError {
            XCTAssertTrue(error.localizedDescription.contains("不足"))
        } catch {
            XCTFail("unexpected \(error)")
        }
        let names = posts(api).compactMap { $0["name"] as? String }
        XCTAssertEqual(names, [CursorSplitTaskOrchestrator.plannerName])
    }

    func testWorkersRunInParallelAndSummaryReceivesEveryResult() async throws {
        let api = SplitAPI(.init(
            plannerResult: planJSON(["调研", "起草", "校对"]),
            workerResult: { name in
                if name.contains("调研") { return ("FINISHED", "发现 A") }
                if name.contains("起草") { return ("FINISHED", "草稿 B") }
                return ("FINISHED", "校对 C")
            },
            summaryResult: "三部分合成一份说明",
            workerDelay: .milliseconds(80)
        ))
        let image = PromptImage(data: Data([1, 2, 3]), mimeType: "image/png")
        let result = try await orchestrator(api).collaborate(
            SplitTaskRequest(task: "写一份说明", resources: [], images: [image]),
            callbacks: .ignore
        )

        XCTAssertGreaterThanOrEqual(api.snapshot().maxInFlightWorkers, 2)
        let created = posts(api)
        let workers = created.filter { ($0["name"] as? String)?.contains("子任务") == true }
        XCTAssertEqual(workers.count, 3)
        for worker in workers {
            let text = promptText(worker)
            XCTAssertTrue(text.contains("写一份说明"))
            XCTAssertTrue(text.contains("交给汇总 agent"))
            let images = (worker["prompt"] as? [String: Any])?["images"] as? [[String: Any]]
            XCTAssertEqual(images?.first?["mimeType"] as? String, "image/png")
        }
        let summary = try XCTUnwrap(created.first { ($0["name"] as? String)?.contains("汇总") == true })
        let summaryPrompt = promptText(summary)
        XCTAssertTrue(summaryPrompt.contains("发现 A"))
        XCTAssertTrue(summaryPrompt.contains("草稿 B"))
        XCTAssertTrue(summaryPrompt.contains("校对 C"))
        XCTAssertNil((summary["prompt"] as? [String: Any])?["images"])
        XCTAssertTrue(result.markdown.contains("三部分合成一份说明"))
        XCTAssertTrue(result.markdown.contains("发现 A"))
        XCTAssertTrue(result.markdown.contains("草稿 B"))
        XCTAssertTrue(result.markdown.contains("校对 C"))
        XCTAssertFalse(result.markdown.contains(SplitTaskSummary.failedMark))
        XCTAssertEqual(result.headline, "已汇总 3 个子任务")
    }

    func testPartialFailureMarksTheFailedSubtaskAndKeepsTheOthers() async throws {
        let api = SplitAPI(.init(
            plannerResult: planJSON(["调研", "起草"]),
            workerResult: { name in
                if name.contains("起草") { return ("ERROR", nil) }
                return ("FINISHED", "发现 A")
            },
            summaryResult: "调研可用，起草没有完成。"
        ))
        let result = try await orchestrator(api).collaborate(
            SplitTaskRequest(task: "写报告", resources: [], images: []),
            callbacks: .ignore
        )

        XCTAssertEqual(result.headline, "1/2 完成，1 个失败")
        XCTAssertTrue(result.anySucceeded)
        XCTAssertTrue(result.markdown.contains("发现 A"))
        XCTAssertTrue(result.markdown.contains("调研 \(SplitTaskSummary.doneMark)"))
        XCTAssertTrue(result.markdown.contains("起草 \(SplitTaskSummary.failedMark)"))
        XCTAssertTrue(result.markdown.contains("ERROR"))
        XCTAssertTrue(result.markdown.contains("调研可用，起草没有完成。"))

        let summaryPrompt = promptText(try XCTUnwrap(posts(api).first { ($0["name"] as? String)?.contains("汇总") == true }))
        XCTAssertTrue(summaryPrompt.contains("发现 A"))
        XCTAssertTrue(summaryPrompt.contains("失败"))
        XCTAssertTrue(summaryPrompt.contains("ERROR"))
    }
}

private struct ScriptedSplit: SplitTaskCollaborating {
    func collaborate(
        _ request: SplitTaskRequest,
        callbacks: SplitTaskCallbacks
    ) async throws -> SplitCollaborationResult {
        let plan = SplitPlan(subtasks: [
            SplitSubtask(title: "调研", prompt: "收集"),
            SplitSubtask(title: "起草", prompt: "写")
        ])
        await callbacks.onPlan(plan)
        let ok = SplitSubtaskOutcome(title: "调研", prompt: "收集", succeeded: true, text: "发现 A", link: "https://cursor.com/agents/a")
        let bad = SplitSubtaskOutcome(title: "起草", prompt: "写", succeeded: false, text: "写挂了", link: nil)
        await callbacks.onSubtaskFinished(0, ok)
        await callbacks.onSubtaskFinished(1, bad)
        return SplitTaskSummary.result(task: request.task, outcomes: [ok, bad], narrative: "汇总正文", link: "https://cursor.com/agents/sum")
    }
}

@MainActor
final class SplitTaskEngineTests: XCTestCase {
    func testJournalsCombinedResultAndOneLightPerSubtask() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrokIslandSplit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let engine = IslandEngine(
            moduleStore: ModuleStore(fileURL: folder.appendingPathComponent("m.json")),
            inbox: ResourceInbox(),
            journal: RunJournal(fileURL: folder.appendingPathComponent("runs.json")),
            collaborator: ScriptedSplit()
        )
        XCTAssertThrowsError(try engine.splitTask("  ")) { error in
            XCTAssertEqual(error as? IslandError, .emptyInput)
        }

        let parent = try engine.splitTask("写一份报告")
        try await waitUntil { engine.journal.record(id: parent.id)?.phase == .succeeded }

        let saved = try XCTUnwrap(engine.journal.record(id: parent.id))
        XCTAssertEqual(saved.origin, .splitTask)
        XCTAssertEqual(saved.question, "写一份报告")
        XCTAssertEqual(saved.message, "1/2 完成，1 个失败")
        let summary = try XCTUnwrap(saved.resultSummary)
        XCTAssertTrue(summary.contains("汇总正文"))
        XCTAssertTrue(summary.contains("发现 A"))
        XCTAssertTrue(summary.contains("起草 \(SplitTaskSummary.failedMark)"))
        XCTAssertTrue(summary.contains("写挂了"))

        let children = engine.runs.filter { $0.origin == .splitSubtask }
        XCTAssertEqual(Set(children.map(\.moduleName)), ["调研", "起草"])
        XCTAssertEqual(Set(children.map(\.parentRunID)), [parent.id])
        XCTAssertEqual(children.first { $0.moduleName == "起草" }?.phase, .failed)
        XCTAssertEqual(children.first { $0.moduleName == "调研" }?.phase, .succeeded)

        let lights = TaskLightBoard.lights(runs: engine.runs, snapshot: CloudActivitySnapshot())
        XCTAssertEqual(Set(lights.map(\.title)), ["调研", "起草"])
        XCTAssertFalse(lights.contains { $0.runID == parent.id })
        XCTAssertEqual(lights.first { $0.title == "起草" }?.state, .failed)
        XCTAssertEqual(lights.first { $0.title == "调研" }?.state, .succeeded)

        let reloaded = RunJournal(fileURL: folder.appendingPathComponent("runs.json"))
        let stored = try XCTUnwrap(reloaded.record(id: parent.id))
        XCTAssertEqual(stored.resultSummary, summary)
        XCTAssertEqual(stored.origin, .splitTask)
    }

    private func waitUntil(timeout: TimeInterval = 1.0, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out")
    }
}
