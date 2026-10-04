import XCTest
#if canImport(GrokIslandCore)
@testable import GrokIslandCore
#else
@testable import GrokIsland
#endif

private func makeStorage() -> IslandSettingsStorage {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("GrokIslandShortcuts-\(UUID().uuidString)", isDirectory: true)
    return IslandSettingsStorage(folder: folder, defaultsSuite: "GrokIslandTests-\(UUID().uuidString)")
}

private func suiteDefaults(_ storage: IslandSettingsStorage) -> UserDefaults {
    UserDefaults(suiteName: storage.defaultsSuite!)!
}

private func writeRaw(_ json: String, to storage: IslandSettingsStorage) {
    suiteDefaults(storage).set(Data(json.utf8), forKey: "islandShortcutButtons")
}

private func store(_ slots: [[String: String]], in storage: IslandSettingsStorage) throws {
    let data = try JSONSerialization.data(withJSONObject: ["slots": slots])
    suiteDefaults(storage).set(data, forKey: "islandShortcutButtons")
}

private func slot(
    _ kind: String,
    _ action: String,
    title: String = "",
    prompt: String = "",
    symbol: String = "sparkles"
) -> [String: String] {
    [
        "kind": kind,
        "actionRaw": action,
        "customTitle": title,
        "customPrompt": prompt,
        "customSymbol": symbol
    ]
}

@MainActor
final class IslandShortcutTests: XCTestCase {
    func testMissingValueIsTheDefaultThreeActions() async {
        let storage = makeStorage()
        let buttons = storage.islandShortcutButtons
        XCTAssertEqual(buttons, .default)
        XCTAssertEqual(buttons.slots.map(\.kind), [.builtin, .builtin, .builtin])
        XCTAssertEqual(buttons.slots.map(\.actionRaw), GrokQuickAction.buttons.map(\.rawValue))
        XCTAssertEqual(
            GrokQuickAction.buttons,
            [.organizeMistakes, .solveProblems, .reviewPageCode]
        )
    }

    func testCustomMiddleSlotSurvivesStorageAndSettingsRelaunch() async {
        let storage = makeStorage()
        let settings = IslandSettings(storage: storage)
        var buttons = settings.shortcutButtons
        buttons.slots[1].kind = .custom
        buttons.slots[1].customTitle = "翻译"
        buttons.slots[1].customPrompt = "把页面翻译成英文"
        buttons.slots[1].customSymbol = "globe"
        settings.shortcutButtons = buttons

        XCTAssertNotNil(suiteDefaults(storage).data(forKey: "islandShortcutButtons"))

        let saved = IslandSettingsStorage(folder: storage.folder, defaultsSuite: storage.defaultsSuite)
            .islandShortcutButtons
        XCTAssertEqual(saved.slots[0], IslandShortcutButtons.default.slots[0])
        XCTAssertEqual(saved.slots[2], IslandShortcutButtons.default.slots[2])
        XCTAssertEqual(saved.slots[1].kind, .custom)
        XCTAssertEqual(saved.slots[1].actionRaw, GrokQuickAction.solveProblems.rawValue)
        XCTAssertEqual(saved.slots[1].customTitle, "翻译")
        XCTAssertEqual(saved.slots[1].customPrompt, "把页面翻译成英文")
        XCTAssertEqual(saved.slots[1].customSymbol, "globe")

        let relaunched = IslandSettings(
            storage: IslandSettingsStorage(folder: storage.folder, defaultsSuite: storage.defaultsSuite)
        )
        XCTAssertEqual(relaunched.shortcutButtons, saved)
    }

    func testEditingDoesNotWriteTheSanitizedValueBack() async {
        let storage = makeStorage()
        let settings = IslandSettings(storage: storage)
        var buttons = settings.shortcutButtons
        buttons.slots[0].kind = .custom
        let typed = "   " + String(repeating: "字", count: 20)
        buttons.slots[0].customTitle = typed
        buttons.slots[0].customPrompt = "  先别裁  "
        settings.shortcutButtons = buttons

        XCTAssertEqual(settings.shortcutButtons.slots[0].customTitle, typed)
        XCTAssertEqual(settings.shortcutButtons.slots[0].customPrompt, "  先别裁  ")
        XCTAssertEqual(settings.shortcutButtons.slots[0].kind, .custom)
        let stored = storage.islandShortcutButtons.slots[0]
        XCTAssertEqual(stored.customTitle, String(repeating: "字", count: 16))
        XCTAssertEqual(stored.customPrompt, "先别裁")
        XCTAssertEqual(stored.kind, .custom)
    }

    func testCorruptOrEmptyDataReturnsTheDefault() async {
        let storage = makeStorage()
        writeRaw("not json", to: storage)
        XCTAssertEqual(storage.islandShortcutButtons, .default)

        suiteDefaults(storage).set(Data(), forKey: "islandShortcutButtons")
        XCTAssertEqual(storage.islandShortcutButtons, .default)

        writeRaw("null", to: storage)
        XCTAssertEqual(storage.islandShortcutButtons, .default)

        writeRaw("{\"slots\":null}", to: storage)
        XCTAssertEqual(storage.islandShortcutButtons, .default)
    }

    func testUnknownActionOnFirstSlotKeepsTheOtherSlots() async throws {
        let storage = makeStorage()
        try store([
            slot("builtin", "nope", title: "留着", prompt: "草稿", symbol: "book"),
            slot("custom", "solveProblems", title: "翻译", prompt: "译", symbol: "globe"),
            slot("builtin", GrokQuickAction.reviewPageCode.rawValue, symbol: "lightbulb")
        ], in: storage)

        let slots = storage.islandShortcutButtons.slots
        XCTAssertEqual(slots[0].kind, .builtin)
        XCTAssertEqual(slots[0].actionRaw, GrokQuickAction.organizeMistakes.rawValue)
        XCTAssertEqual(slots[0].customTitle, "留着")
        XCTAssertEqual(slots[0].customPrompt, "草稿")
        XCTAssertEqual(slots[0].customSymbol, "book")
        XCTAssertEqual(slots[1].kind, .custom)
        XCTAssertEqual(slots[1].customTitle, "翻译")
        XCTAssertEqual(slots[1].customPrompt, "译")
        XCTAssertEqual(slots[1].customSymbol, "globe")
        XCTAssertEqual(slots[2].kind, .builtin)
        XCTAssertEqual(slots[2].actionRaw, GrokQuickAction.reviewPageCode.rawValue)
        XCTAssertEqual(slots[2].customSymbol, "lightbulb")
    }

    func testAskAboutPageIsRejectedAsABuiltinSlot() async throws {
        let storage = makeStorage()
        try store([
            slot("builtin", GrokQuickAction.askAboutPage.rawValue, title: "留着", prompt: "也留", symbol: "book"),
            slot("custom", "solveProblems", title: "中", prompt: "间", symbol: "globe"),
            slot("builtin", GrokQuickAction.reviewPageCode.rawValue)
        ], in: storage)

        let slots = storage.islandShortcutButtons.slots
        XCTAssertEqual(slots[0].actionRaw, GrokQuickAction.organizeMistakes.rawValue)
        XCTAssertEqual(slots[0].kind, .builtin)
        XCTAssertEqual(slots[0].customTitle, "留着")
        XCTAssertEqual(slots[0].customPrompt, "也留")
        XCTAssertEqual(slots[1].kind, .custom)
        XCTAssertEqual(slots[1].customTitle, "中")
        XCTAssertEqual(slots[1].customPrompt, "间")
        XCTAssertEqual(slots[2].actionRaw, GrokQuickAction.reviewPageCode.rawValue)
    }

    func testUnknownKindBecomesTheDefaultSlotForThatIndex() async throws {
        let storage = makeStorage()
        try store([
            slot("plugin", "solveProblems", title: "不要", prompt: "整段丢掉", symbol: "book"),
            slot("custom", "organizeMistakes", title: "留", prompt: "下", symbol: "globe"),
            slot("builtin", GrokQuickAction.reviewPageCode.rawValue)
        ], in: storage)

        let slots = storage.islandShortcutButtons.slots
        XCTAssertEqual(slots[0], IslandShortcutButtons.default.slots[0])
        XCTAssertEqual(slots[1].kind, .custom)
        XCTAssertEqual(slots[1].customTitle, "留")
        XCTAssertEqual(slots[1].customPrompt, "下")
        XCTAssertEqual(slots[2], IslandShortcutButtons.default.slots[2])
    }

    func testPartialSlotDecodesWithoutCrashing() async throws {
        let storage = makeStorage()
        writeRaw("{\"slots\":[{\"kind\":\"custom\",\"customTitle\":\"Hi\"}]}", to: storage)
        let slots = storage.islandShortcutButtons.slots
        XCTAssertEqual(slots.count, 3)
        XCTAssertEqual(slots[0].kind, .custom)
        XCTAssertEqual(slots[0].customTitle, "Hi")
        XCTAssertEqual(slots[0].customPrompt, "")
        XCTAssertEqual(slots[0].customSymbol, "sparkles")
        XCTAssertEqual(slots[0].actionRaw, GrokQuickAction.organizeMistakes.rawValue)
        XCTAssertEqual(slots[1], IslandShortcutButtons.default.slots[1])
        XCTAssertEqual(slots[2], IslandShortcutButtons.default.slots[2])
        XCTAssertFalse(storage.islandShortcutButtons.resolved()[0].isReady)
    }

    func testSlotCountNormalizesToThree() async throws {
        let storage = makeStorage()
        try store([
            slot("custom", "organizeMistakes", title: "仅有", prompt: "一条", symbol: "book")
        ], in: storage)
        var slots = storage.islandShortcutButtons.slots
        XCTAssertEqual(slots.count, 3)
        XCTAssertEqual(slots[0].kind, .custom)
        XCTAssertEqual(slots[0].customTitle, "仅有")
        XCTAssertEqual(slots[0].customPrompt, "一条")
        XCTAssertEqual(slots[1], IslandShortcutButtons.default.slots[1])
        XCTAssertEqual(slots[2], IslandShortcutButtons.default.slots[2])

        try store([
            slot("custom", "organizeMistakes", title: "一", prompt: "甲", symbol: "book"),
            slot("custom", "solveProblems", title: "二", prompt: "乙", symbol: "globe"),
            slot("builtin", GrokQuickAction.reviewPageCode.rawValue),
            slot("custom", "organizeMistakes", title: "丢掉", prompt: "四", symbol: "book"),
            slot("custom", "solveProblems", title: "也丢掉", prompt: "五", symbol: "globe")
        ], in: storage)
        slots = storage.islandShortcutButtons.slots
        XCTAssertEqual(slots.count, 3)
        XCTAssertEqual(slots.map(\.customTitle), ["一", "二", ""])
        XCTAssertEqual(slots[0].customPrompt, "甲")
        XCTAssertEqual(slots[1].customPrompt, "乙")
        XCTAssertEqual(slots[2].actionRaw, GrokQuickAction.reviewPageCode.rawValue)
        XCTAssertFalse(slots.contains { $0.customTitle == "丢掉" || $0.customTitle == "也丢掉" })
    }

    func testSymbolOutsideTheAllowlistBecomesSparklesOnRead() async throws {
        let storage = makeStorage()
        try store([
            slot("custom", "solveProblems", title: "译", prompt: "翻", symbol: "paperplane")
        ], in: storage)
        let slot = storage.islandShortcutButtons.slots[0]
        XCTAssertEqual(slot.customSymbol, "sparkles")
        XCTAssertEqual(slot.kind, .custom)
        XCTAssertEqual(slot.customTitle, "译")
        XCTAssertEqual(slot.customPrompt, "翻")
        XCTAssertEqual(storage.islandShortcutButtons.resolved()[0].symbolName, "sparkles")
    }

    func testOverlongTitleAndPromptAreTruncatedOnRead() async throws {
        let storage = makeStorage()
        let title = "   " + String(repeating: "字", count: IslandShortcutSlot.maxTitleLength + 1) + "  "
        let prompt = "\n" + String(repeating: "a", count: IslandShortcutSlot.maxPromptLength + 25) + " "
        try store([
            slot("custom", "organizeMistakes", title: title, prompt: prompt, symbol: "lightbulb")
        ], in: storage)
        let saved = storage.islandShortcutButtons.slots[0]
        XCTAssertEqual(saved.customTitle, String(repeating: "字", count: IslandShortcutSlot.maxTitleLength))
        XCTAssertEqual(saved.customPrompt, String(repeating: "a", count: IslandShortcutSlot.maxPromptLength))
        XCTAssertEqual(saved.customSymbol, "lightbulb")
        XCTAssertEqual(saved.kind, .custom)
    }

    func testResolvedDefaultMatchesTheQuickActions() async {
        let resolved = IslandShortcutButtons.default.resolved()
        XCTAssertEqual(resolved.map(\.title), GrokQuickAction.buttons.map(\.title))
        XCTAssertEqual(resolved.map(\.symbolName), GrokQuickAction.buttons.map(\.symbolName))
        XCTAssertEqual(resolved.map(\.prompt), GrokQuickAction.buttons.map(\.prompt))
        XCTAssertTrue(resolved.allSatisfy(\.isReady))
    }

    func testBlankCustomPromptIsNotReadyAndDoesNotUseABuiltinPrompt() async {
        var buttons = IslandShortcutButtons.default
        buttons.slots[1].kind = .custom
        buttons.slots[1].customTitle = "  \n"
        buttons.slots[1].customPrompt = " \n "
        buttons.slots[1].customSymbol = "nope"
        let resolved = buttons.resolved()[1]
        XCTAssertEqual(resolved.title, "自定义")
        XCTAssertEqual(resolved.prompt, "")
        XCTAssertEqual(resolved.symbolName, "sparkles")
        XCTAssertFalse(resolved.isReady)
        XCTAssertNotEqual(resolved.prompt, GrokQuickAction.solveProblems.prompt)
        XCTAssertEqual(buttons.slots[1].kind, .custom, "resolving must not rewrite the value being edited")
        XCTAssertEqual(buttons.slots[1].customPrompt, " \n ")
        XCTAssertEqual(buttons.sanitized().slots[1].kind, .custom)
        XCTAssertEqual(buttons.sanitized().slots[1].customPrompt, "")
    }

    func testBuiltinSlotKeepsTheCustomDraft() async {
        var buttons = IslandShortcutButtons.default
        buttons.slots[1].customTitle = "草稿"
        buttons.slots[1].customPrompt = "以后再用"
        buttons.slots[1].customSymbol = "lightbulb"
        let saved = buttons.sanitized().slots[1]
        XCTAssertEqual(saved.kind, .builtin)
        XCTAssertEqual(saved.actionRaw, GrokQuickAction.solveProblems.rawValue)
        XCTAssertEqual(saved.customTitle, "草稿")
        XCTAssertEqual(saved.customPrompt, "以后再用")
        XCTAssertEqual(saved.customSymbol, "lightbulb")
        let resolved = buttons.resolved()[1]
        XCTAssertEqual(resolved.title, GrokQuickAction.solveProblems.title)
        XCTAssertEqual(resolved.symbolName, GrokQuickAction.solveProblems.symbolName)
        XCTAssertEqual(resolved.prompt, GrokQuickAction.solveProblems.prompt)
        XCTAssertTrue(resolved.isReady)
    }

    func testRunShortcutSendsTheCustomPromptUnderTheCustomTitle() async throws {
        let box = RequestBox()
        let engine = try makeEngine(CapturingExecutor(seen: box))
        let shot = PromptImage(data: Data([4, 5]), mimeType: "image/png")
        let page = PageSnapshot(appName: "Safari", windowTitle: "笔记", screenshot: shot)
        let record = try engine.runShortcut(title: "翻译这段", prompt: "把附图翻译成英文", page: page)
        XCTAssertEqual(record.moduleName, "翻译这段")
        XCTAssertEqual(record.origin, .quickAction)

        try await waitFor { engine.runs.first?.phase == .succeeded }
        let captured = await box.request
        let sent = try XCTUnwrap(captured)
        XCTAssertEqual(sent.module.prompt, "把附图翻译成英文")
        XCTAssertNotEqual(sent.module.prompt, GrokQuickAction.organizeMistakes.prompt)
        XCTAssertEqual(sent.images, [shot])
    }

    func testRunQuickActionOrganizeMistakesStillSendsItsPreset() async throws {
        let box = RequestBox()
        let engine = try makeEngine(CapturingExecutor(seen: box))
        let page = PageSnapshot(screenshot: PromptImage(data: Data([1]), mimeType: "image/png"))
        let record = try engine.runQuickAction(.organizeMistakes, page: page)
        XCTAssertEqual(record.moduleName, GrokQuickAction.organizeMistakes.title)
        XCTAssertEqual(record.origin, .quickAction)

        try await waitFor { engine.runs.first?.phase == .succeeded }
        let captured = await box.request
        let sent = try XCTUnwrap(captured)
        XCTAssertEqual(sent.module.prompt, GrokQuickAction.organizeMistakes.prompt)
    }

    private func makeEngine(_ grok: ModuleExecuting) throws -> IslandEngine {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrokIslandShortcutEngine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return IslandEngine(
            moduleStore: ModuleStore(fileURL: folder.appendingPathComponent("m.json")),
            inbox: ResourceInbox(),
            journal: RunJournal(),
            grokBot: grok,
            local: LocalExecutor()
        )
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
