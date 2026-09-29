import XCTest
#if canImport(GrokIslandCore)
@testable import GrokIslandCore
#else
@testable import GrokIsland
#endif

private func tempURL(_ name: String) throws -> URL {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("GrokIslandUpgrade-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.appendingPathComponent(name)
}

@MainActor
private func waitFor(timeout: TimeInterval = 1.0, _ predicate: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail("timed out waiting for condition")
}

@MainActor
final class RunJournalPersistenceTests: XCTestCase {
    func testAnswersSurviveRelaunchAndActiveRunsComeBackInterrupted() async throws {
        let url = try tempURL("run-journal.json")
        let journal = RunJournal(fileURL: url)
        let module = FunctionModule(name: "问 Grok", prompt: "q", executor: .grokBot)
        let answered = journal.enqueue(
            module: module, name: "问 Grok", executor: .grokBot, resources: [],
            extraPrompt: "q", origin: .quickAsk, question: "这题怎么做？"
        )
        journal.succeed(id: answered.id, result: ExecutionResult(
            summary: "思路", detail: "## 思路\n完整答案", link: "https://cursor.com/agents/a"
        ))
        let inFlight = journal.enqueue(
            module: module, name: "翻译", executor: .grokBot, resources: [], extraPrompt: nil
        )
        journal.transition(id: inFlight.id, phase: .running, progress: 0.4, message: "Grok 正在解答")

        let reloaded = RunJournal(fileURL: url)
        XCTAssertEqual(reloaded.runs.map(\.id), [inFlight.id, answered.id])

        let answer = try XCTUnwrap(reloaded.record(id: answered.id))
        XCTAssertEqual(answer.phase, .succeeded)
        XCTAssertEqual(answer.resultSummary, "## 思路\n完整答案")
        XCTAssertEqual(answer.question, "这题怎么做？")
        XCTAssertEqual(answer.origin, .quickAsk)
        XCTAssertNil(answer.moduleID, "quick asks are not tied to a module tile")
        XCTAssertEqual(answer.link, "https://cursor.com/agents/a")

        let interrupted = try XCTUnwrap(reloaded.record(id: inFlight.id))
        XCTAssertEqual(interrupted.phase, .cancelled)
        XCTAssertEqual(interrupted.message, RunJournal.interruptedMessage)
        XCTAssertTrue(reloaded.activeRuns.isEmpty)
    }

    func testDecodesRecordsWithoutNewFields() async throws {
        let json = """
        [{"id":"\(UUID().uuidString)","moduleName":"翻译","executor":"grokBot","phase":"succeeded",
          "createdAt":"2026-09-28T08:00:00Z"}]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let runs = try decoder.decode([RunRecord].self, from: Data(json.utf8))
        XCTAssertEqual(runs.first?.origin, .module)
        XCTAssertEqual(runs.first?.resources, [])
        XCTAssertEqual(runs.first?.updatedAt, runs.first?.createdAt)
    }

    func testRemoveSelectedAndClearFinishedPersist() async throws {
        let url = try tempURL("run-journal.json")
        let journal = RunJournal(fileURL: url)
        let ids = (0..<4).map { index in
            journal.enqueue(module: nil, name: "r\(index)", executor: .grokBot, resources: [], extraPrompt: nil).id
        }
        journal.succeed(id: ids[0], result: ExecutionResult(summary: "ok"))
        journal.fail(id: ids[1], message: "bad")
        XCTAssertEqual(journal.finishedCount, 2)

        XCTAssertEqual(journal.remove(ids: [ids[3], UUID()]), 1)
        XCTAssertEqual(journal.clearFinished(), 2)
        XCTAssertEqual(journal.runs.map(\.id), [ids[2]])
        XCTAssertEqual(RunJournal(fileURL: url).runs.map(\.id), [ids[2]])
    }
}

@MainActor
final class EngineRecordAndDropTests: XCTestCase {
    private func makeEngine() throws -> IslandEngine {
        IslandEngine(
            moduleStore: ModuleStore(fileURL: try tempURL("m.json")),
            inbox: ResourceInbox(),
            journal: RunJournal(),
            grokBot: GrokBotExecutor(instant: true),
            local: LocalExecutor()
        )
    }

    func testQuickAskKeepsQuestionAndAnswerOnTheIsland() async throws {
        let engine = try makeEngine()
        let record = try engine.quickAskGrok("  总结这页  ")
        XCTAssertEqual(record.origin, .quickAsk)
        XCTAssertEqual(record.question, "总结这页")
        XCTAssertEqual(record.moduleName, "问 Grok")
        try await waitFor { engine.journal.record(id: record.id)?.phase == .succeeded }
        XCTAssertNotNil(engine.journal.record(id: record.id)?.resultSummary)
    }

    func testDeleteRunsCancelsActiveAndClearFinishedCounts() async throws {
        let engine = try makeEngine()
        let local = try engine.createModule(name: "打开文件", prompt: "open", executor: .local)
        let grok = try engine.createModule(name: "翻译", prompt: "zh", executor: .grokBot)
        let done = try engine.runModule(id: grok.id, resources: [])
        try await waitFor { engine.journal.record(id: done.id)?.phase == .succeeded }
        let pending = try engine.runModule(id: local.id, resources: [])
        XCTAssertNotNil(engine.pendingLocal)

        XCTAssertEqual(engine.deleteRuns(ids: [pending.id]), 1)
        XCTAssertNil(engine.pendingLocal, "deleting a waiting local run also drops its confirmation")
        XCTAssertNil(engine.journal.record(id: pending.id))
        XCTAssertEqual(engine.clearFinishedRuns(), 1)
        XCTAssertTrue(engine.runs.isEmpty)
    }

    func testRunDroppedReportsOutcomeForTheTile() async throws {
        let engine = try makeEngine()
        let module = try engine.createModule(name: "翻译", prompt: "zh", executor: .grokBot)

        XCTAssertEqual(engine.runDropped([], on: module.id), .rejected(IslandError.dropEmpty.localizedDescription))
        XCTAssertEqual(engine.lastError, IslandError.dropEmpty.localizedDescription)

        let items = ResourceIntake.items(fromStrings: ["https://example.com/a", "https://example.com/b"])
        guard case .started(let runID, let count) = engine.runDropped(items, on: module.id) else {
            return XCTFail("expected the run to start")
        }
        XCTAssertEqual(count, 2)
        XCTAssertEqual(engine.journal.record(id: runID)?.moduleID, module.id)
        try await waitFor { engine.journal.record(id: runID)?.phase == .succeeded }

        guard case .rejected = engine.runDropped(items, on: UUID()) else {
            return XCTFail("unknown module should be rejected")
        }
    }
}

final class TaskLightBoardTests: XCTestCase {
    private func run(_ name: String, _ phase: RunPhase, updated: Date, link: String? = nil) -> RunRecord {
        RunRecord(
            id: UUID(), moduleID: nil, moduleName: name, executor: .grokBot, resources: [],
            extraPrompt: nil, phase: phase, progress: 0.5, message: "", resultSummary: nil,
            createdAt: updated, updatedAt: updated, link: link
        )
    }

    func testOneLightPerTaskWithRecentResultsAndDedupedAgents() {
        let now = Date()
        let running = run("翻译", .running, updated: now, link: "https://cursor.com/agents/mine")
        let justFailed = run("检查代码", .failed, updated: now.addingTimeInterval(-10))
        let old = run("整理错题", .succeeded, updated: now.addingTimeInterval(-600))
        var snapshot = CloudActivitySnapshot()
        snapshot.agents = [
            CloudAgentSummary(id: "mine", name: "grok岛 · 翻译", status: "ACTIVE", url: "https://cursor.com/agents/mine"),
            CloudAgentSummary(id: "other", name: "Fix login", status: "ACTIVE", url: "https://cursor.com/agents/other")
        ]
        snapshot.pullRequests = [
            PullRequestActivity(number: 7, title: "UI", url: nil, headRef: nil, checks: .failed, isStale: false),
            PullRequestActivity(number: 8, title: "Docs", url: nil, headRef: nil, checks: .none, isStale: false)
        ]

        let lights = TaskLightBoard.lights(runs: [running, justFailed, old], snapshot: snapshot, now: now)
        XCTAssertEqual(lights.map(\.id), [
            "run:\(running.id.uuidString)", "run:\(justFailed.id.uuidString)", "agent:other", "pr:7", "pr:8"
        ])
        XCTAssertEqual(lights.map(\.state), [.running, .failed, .running, .failed, .idle])
        XCTAssertEqual(lights[0].progress, 0.5)
        XCTAssertEqual(lights[0].runID, running.id)
        XCTAssertEqual(lights.map(\.kind), [.grok, .grok, .cloudAgent, .pullRequest, .pullRequest])
    }

    func testQuestionShowsInLightTitle() {
        var record = run("问 Grok", .queued, updated: Date())
        record.question = "这题"
        XCTAssertEqual(TaskLightBoard.light(for: record).title, "问 Grok：这题")
        XCTAssertTrue(TaskLightBoard.light(for: record).state.isAnimated)
    }
}

final class DeadlineParserTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    /// Wednesday 2026-09-30 10:00 in Shanghai.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 10))!
    }

    private func date(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int, year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func parse(_ text: String) -> ParsedDeadline {
        DeadlineParser.parse(text, now: now, calendar: calendar)
    }

    func testRelativeDaysAndTimes() {
        XCTAssertEqual(parse("明天 18:00 交数学作业"), ParsedDeadline(
            title: "交数学作业", due: date(10, 1, 18, 0), matched: ["明天", "18:00"]
        ))
        XCTAssertEqual(parse("两天后 还书").due, date(10, 2, 23, 59))
        XCTAssertEqual(parse("两天后 还书").title, "还书")
        XCTAssertEqual(parse("3小时后 开会").due, now.addingTimeInterval(3 * 3600))
        XCTAssertEqual(parse("晚上8点半 跑步").due, date(9, 30, 20, 30))
        XCTAssertEqual(parse("今晚八点 看直播").due, date(9, 30, 20, 0))
        XCTAssertEqual(parse("明天下午3点 组会"), ParsedDeadline(
            title: "组会", due: date(10, 1, 15, 0), matched: ["明天", "下午3点"]
        ))
        XCTAssertEqual(parse("9:00 早会").due, date(10, 1, 9, 0), "a time already passed today rolls to tomorrow")
    }

    func testWeekdaysAndCalendarDates() {
        let friday = parse("周五前交实验报告")
        XCTAssertEqual(friday.title, "交实验报告")
        XCTAssertEqual(friday.due, date(10, 2, 23, 59))
        XCTAssertEqual(parse("周三 例会").due, date(9, 30, 23, 59))
        XCTAssertEqual(parse("下周一 9点 组会"), ParsedDeadline(
            title: "组会", due: date(10, 5, 9, 0), matched: ["下周一", "9点"]
        ))
        XCTAssertEqual(parse("10月3日 提交论文").due, date(10, 3, 23, 59))
        XCTAssertEqual(parse("9月1日 旧事").due, date(9, 1, 23, 59, year: 2027))
        XCTAssertEqual(parse("下午三点 DDL 数据库作业"), ParsedDeadline(
            title: "数据库作业", due: date(9, 30, 15, 0), matched: ["下午三点"]
        ))
    }

    func testEnergyLoadFollowsCellCount() {
        XCTAssertEqual(EnergyLoad.level(for: 0), .calm)
        XCTAssertEqual(EnergyLoad.level(for: 1), .calm)
        XCTAssertEqual(EnergyLoad.level(for: 3), .calm)
        XCTAssertEqual(EnergyLoad.level(for: 4), .busy)
        XCTAssertEqual(EnergyLoad.level(for: 6), .busy)
        XCTAssertEqual(EnergyLoad.level(for: 7), .overloaded)
        XCTAssertEqual(EnergyLoad.level(for: 12), .overloaded)
    }

    func testPlainTextHasNoDate() {
        XCTAssertEqual(parse("  交报告 "), ParsedDeadline(title: "交报告", due: nil, matched: []))
    }

    func testChineseNumbers() {
        XCTAssertEqual(DeadlineParser.number("十二"), 12)
        XCTAssertEqual(DeadlineParser.number("二十三"), 23)
        XCTAssertEqual(DeadlineParser.number("两"), 2)
        XCTAssertEqual(DeadlineParser.number("15"), 15)
        XCTAssertNil(DeadlineParser.number("十十"))
    }

    func testFormatting() {
        XCTAssertEqual(DeadlineFormat.countdown(5 * 3600 + 20 * 60), "还剩 5 小时 20 分")
        XCTAssertEqual(DeadlineFormat.countdown(-2 * 86_400), "超时 2 天")
        XCTAssertEqual(DeadlineFormat.short(45 * 60), "45分")
        XCTAssertEqual(DeadlineFormat.short(30 * 3600), "1天")
        XCTAssertEqual(DeadlineFormat.dueLabel(date(10, 1, 9, 5), now: now, calendar: calendar), "明天 09:05")
        XCTAssertEqual(DeadlineFormat.dueLabel(date(10, 3, 18, 0), now: now, calendar: calendar), "周六 18:00")
        XCTAssertEqual(DeadlineFormat.dueLabel(date(10, 20, 18, 0), now: now, calendar: calendar), "10月20日 18:00")
    }
}

@MainActor
final class DeadlineStoreTests: XCTestCase {
    func testEnergyAndUrgencyDrainTowardDue() async {
        let now = Date()
        let item = DeadlineItem(title: "x", due: now.addingTimeInterval(10 * 3600), createdAt: now.addingTimeInterval(-10 * 3600))
        XCTAssertEqual(item.energy(now: now), 0.5, accuracy: 0.001)
        XCTAssertEqual(item.urgency(now: now), .critical)
        XCTAssertEqual(item.energy(now: now.addingTimeInterval(11 * 3600)), 0)
        XCTAssertEqual(item.urgency(now: now.addingTimeInterval(11 * 3600)), .overdue)
        XCTAssertEqual(item.urgency(now: now.addingTimeInterval(-3 * 86_400)), .relaxed)
        XCTAssertTrue(DeadlineUrgency.soon.isPressing)
        XCTAssertFalse(DeadlineUrgency.relaxed.isPressing)
    }

    func testCRUDSortingSummaryAndPersistence() async throws {
        let url = try tempURL("deadlines.json")
        let store = DeadlineStore(fileURL: url)
        let now = Date()
        let later = try store.add(title: " 论文 ", due: now.addingTimeInterval(5 * 86_400), now: now)
        let soon = try store.add(title: "作业", due: now.addingTimeInterval(3600), now: now)
        let overdue = try store.add(title: "报名", due: now.addingTimeInterval(-60), now: now)
        XCTAssertEqual(later.title, "论文")
        XCTAssertEqual(store.items.map(\.id), [overdue.id, soon.id, later.id])
        XCTAssertThrowsError(try store.add(title: "  ", due: now)) { error in
            XCTAssertEqual(error as? IslandError, .deadlineTitleEmpty)
        }

        let summary = store.summary(now: now)
        XCTAssertEqual(summary.next?.id, overdue.id)
        XCTAssertEqual(summary.overdueCount, 1)
        XCTAssertEqual(summary.withinWeekCount, 2)
        XCTAssertEqual(summary.pendingCount, 3)

        store.toggleDone(id: overdue.id)
        XCTAssertEqual(store.pending.map(\.id), [soon.id, later.id])
        let moved = try store.update(id: later.id, title: "论文终稿", due: now.addingTimeInterval(1800))
        XCTAssertEqual(moved.title, "论文终稿")
        XCTAssertEqual(store.pending.map(\.id), [later.id, soon.id])
        XCTAssertThrowsError(try store.update(id: UUID(), title: "x", due: now))

        let reloaded = DeadlineStore(fileURL: url)
        XCTAssertEqual(reloaded.items.map(\.title), ["报名", "论文终稿", "作业"])
        XCTAssertEqual(reloaded.items.first?.isDone, true)

        XCTAssertEqual(store.clearDone(), 1)
        store.delete(id: soon.id)
        XCTAssertEqual(DeadlineStore(fileURL: url).items.map(\.id), [later.id])
    }
}
