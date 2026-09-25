import XCTest
#if canImport(GrokIslandCore)
@testable import GrokIslandCore
#else
@testable import GrokIsland
#endif

@MainActor
final class ModuleStoreTests: XCTestCase {
    private func makeStore() throws -> ModuleStore {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrokIslandTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return ModuleStore(fileURL: folder.appendingPathComponent("function-modules.json"))
    }

    func testCRUDAndPersistence() async throws {
        let store = try makeStore()
        XCTAssertTrue(store.modules.isEmpty)

        let created = try store.create(name: " 翻译 ", prompt: " 译成中文 ", executor: .grokBot)
        XCTAssertEqual(created.name, "翻译")
        XCTAssertEqual(created.prompt, "译成中文")
        XCTAssertEqual(store.modules.count, 1)

        var edited = created
        edited.prompt = "保持术语"
        edited.executor = .local
        let updated = try store.update(edited)
        XCTAssertEqual(updated.prompt, "保持术语")
        XCTAssertEqual(updated.executor, .local)

        let renamed = try store.rename(id: created.id, to: "整理笔记")
        XCTAssertEqual(renamed.name, "整理笔记")

        let reloaded = ModuleStore(fileURL: store.storageURL)
        XCTAssertEqual(reloaded.modules.count, 1)
        XCTAssertEqual(reloaded.modules.first?.name, "整理笔记")
        XCTAssertEqual(reloaded.modules.first?.executor, .local)

        try store.delete(id: created.id)
        XCTAssertTrue(store.modules.isEmpty)
        let emptyReload = ModuleStore(fileURL: store.storageURL)
        XCTAssertTrue(emptyReload.modules.isEmpty)
    }

    func testRejectsEmptyName() async {
        let store = try! makeStore()
        XCTAssertThrowsError(try store.create(name: "   ", prompt: "x", executor: .grokBot)) { error in
            XCTAssertEqual(error as? IslandError, .moduleNameEmpty)
        }
    }

    func testDeleteMissingThrows() async {
        let store = try! makeStore()
        XCTAssertThrowsError(try store.delete(id: UUID())) { error in
            XCTAssertEqual(error as? IslandError, .moduleNotFound)
        }
    }
}

@MainActor
final class ResourceInboxTests: XCTestCase {
    func testIngestDedupesByLocation() async {
        let inbox = ResourceInbox()
        let a = ResourceItem(kind: .file, name: "a.txt", location: "/tmp/a.txt")
        let b = ResourceItem(kind: .file, name: "a-copy", location: "/tmp/a.txt")
        let c = ResourceItem(kind: .url, name: "example", location: "https://example.com")
        inbox.ingest([a, b, c])
        XCTAssertEqual(inbox.count, 2)
        inbox.remove(id: a.id)
        XCTAssertEqual(inbox.items.map(\.location), ["https://example.com"])
        inbox.clear()
        XCTAssertTrue(inbox.isEmpty)
    }
}

final class ResourceIntakeTests: XCTestCase {
    func testHTTPAndFileStrings() {
        let items = ResourceIntake.items(fromStrings: [
            "https://example.com/doc",
            "   ",
            "not-a-resource"
        ])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.kind, .url)
        XCTAssertEqual(items.first?.location, "https://example.com/doc")
    }

    func testFileURLMetadata() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("island-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: file)
        let item = ResourceIntake.makeItem(from: file)
        XCTAssertEqual(item.kind, .file)
        XCTAssertEqual(item.name, file.lastPathComponent)
        XCTAssertEqual(item.location, file.path)
        XCTAssertEqual(item.fileSize, 5)
    }
}

@MainActor
final class RunJournalTests: XCTestCase {
    func testStateMachineAndStickyTerminal() async {
        let journal = RunJournal()
        let module = FunctionModule(name: "翻译", prompt: "zh", executor: .grokBot)
        let record = journal.enqueue(
            module: module,
            name: module.name,
            executor: .grokBot,
            resources: [],
            extraPrompt: nil
        )
        XCTAssertEqual(record.phase, .queued)
        journal.apply(progress: ExecutionProgress(fraction: 0.4, message: "working"), to: record.id)
        XCTAssertEqual(journal.record(id: record.id)?.phase, .running)
        journal.cancel(id: record.id)
        XCTAssertEqual(journal.record(id: record.id)?.phase, .cancelled)
        journal.succeed(id: record.id, result: ExecutionResult(summary: "nope", detail: nil))
        XCTAssertEqual(journal.record(id: record.id)?.phase, .cancelled)
        journal.clearFinished()
        XCTAssertTrue(journal.runs.isEmpty)
    }
}

@MainActor
final class IslandEngineTests: XCTestCase {
    private func makeEngine() throws -> IslandEngine {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrokIslandEngine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return IslandEngine(
            moduleStore: ModuleStore(fileURL: folder.appendingPathComponent("m.json")),
            inbox: ResourceInbox(),
            journal: RunJournal(),
            grokBot: GrokBotExecutor(instant: true),
            local: LocalExecutor()
        )
    }

    func testAssignInboxRequiresResources() async throws {
        let engine = try makeEngine()
        let module = try engine.createModule(name: "翻译", prompt: "zh", executor: .grokBot)
        XCTAssertThrowsError(try engine.assignInbox(to: module.id)) { error in
            XCTAssertEqual(error as? IslandError, .inboxEmpty)
        }
    }

    func testAssignInboxRunsGrokStub() async throws {
        let engine = try makeEngine()
        let module = try engine.createModule(name: "翻译", prompt: "zh", executor: .grokBot)
        engine.ingestDroppedStrings(["https://example.com/a"])
        let record = try engine.assignInbox(to: module.id)
        XCTAssertTrue(engine.inboxItems.isEmpty)
        XCTAssertEqual(record.resources.count, 1)
        try await waitUntil(timeout: 1.0) {
            engine.runs.first?.phase == .succeeded
        }
        XCTAssertEqual(engine.runs.first?.moduleName, "翻译")
    }

    func testLocalRequiresConfirmationThenCompletes() async throws {
        let engine = try makeEngine()
        let module = try engine.createModule(name: "打开文件", prompt: "open", executor: .local)
        engine.ingest([ResourceItem(kind: .file, name: "a.txt", location: "/tmp/a.txt")])
        let record = try engine.assignInbox(to: module.id)
        XCTAssertEqual(record.phase, .awaitingConfirmation)
        XCTAssertNotNil(engine.pendingLocal)
        try engine.confirmPendingLocal(openAttachedFiles: false, shellCommand: "")
        XCTAssertNil(engine.pendingLocal)
        try await waitUntil(timeout: 1.0) {
            engine.runs.first?.phase == .succeeded
        }
    }

    func testCancelPendingLocal() async throws {
        let engine = try makeEngine()
        let module = try engine.createModule(name: "打开文件", prompt: "open", executor: .local)
        engine.ingestDroppedStrings(["https://example.com"])
        let record = try engine.assignInbox(to: module.id)
        engine.cancelPendingLocal()
        XCTAssertNil(engine.pendingLocal)
        XCTAssertEqual(engine.journal.record(id: record.id)?.phase, .cancelled)
    }

    func testQuickAskRejectsEmpty() async throws {
        let engine = try makeEngine()
        XCTAssertThrowsError(try engine.quickAskGrok("   ")) { error in
            XCTAssertEqual(error as? IslandError, .emptyInput)
        }
    }

    func testRenameAndDelete() async throws {
        let engine = try makeEngine()
        let module = try engine.createModule(name: "A", prompt: "", executor: .grokBot)
        _ = try engine.renameModule(id: module.id, to: "B")
        XCTAssertEqual(engine.modules.first?.name, "B")
        try engine.deleteModule(id: module.id)
        XCTAssertTrue(engine.modules.isEmpty)
    }
}

final class ExecutorTests: XCTestCase {
    func testLocalWithoutOptionsThrows() async {
        let executor = LocalExecutor()
        let module = FunctionModule(name: "local", prompt: "x", executor: .local)
        let request = ExecutionRequest(module: module, resources: [], extraPrompt: nil, local: nil)
        do {
            _ = try await executor.run(request) { _ in }
            XCTFail("expected confirmation error")
        } catch let error as IslandError {
            XCTAssertEqual(error, .localConfirmationRequired)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testGrokWirePayload() {
        let module = FunctionModule(name: "翻译", prompt: "zh", executor: .grokBot)
        let resource = ResourceItem(kind: .url, name: "ex", location: "https://example.com")
        let request = ExecutionRequest(module: module, resources: [resource], extraPrompt: "go", local: nil)
        let wire = request.grokWirePayload()
        XCTAssertEqual(wire.name, "翻译")
        XCTAssertEqual(wire.resources.first?.location, "https://example.com")
        XCTAssertEqual(GrokBotTransport.urlScheme, "grok-island")
    }

    func testHTTPClientIsNotWired() async {
        let client = HTTPGrokBotClient()
        let module = FunctionModule(name: "翻译", prompt: "zh", executor: .grokBot)
        let request = ExecutionRequest(module: module, resources: [], extraPrompt: nil, local: nil)
        do {
            _ = try await client.execute(request) { _ in }
            XCTFail("expected not-wired error")
        } catch let error as IslandError {
            guard case .executorFailed(let message) = error else {
                return XCTFail("wrong error \(error)")
            }
            XCTAssertTrue(message.contains("not wired"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}

@MainActor
private func waitUntil(timeout: TimeInterval, _ predicate: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail("timed out waiting for condition")
}
