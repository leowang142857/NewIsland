import Foundation

/// One piece of a split task, handed to its own cloud agent.
struct SplitSubtask: Equatable, Sendable, Codable {
    var title: String
    var prompt: String
}

/// Two to four subtasks that can run at the same time.
struct SplitPlan: Equatable, Sendable {
    var subtasks: [SplitSubtask]
}

/// What one worker agent returned. A failure still carries the error text for the summary.
struct SplitSubtaskOutcome: Equatable, Sendable {
    var title: String
    var prompt: String
    var succeeded: Bool
    var text: String
    var link: String?
}

/// The combined result written into the run journal.
struct SplitCollaborationResult: Equatable, Sendable {
    var markdown: String
    var headline: String
    var outcomes: [SplitSubtaskOutcome]
    var link: String?

    var anySucceeded: Bool { outcomes.contains(where: \.succeeded) }
}

struct SplitTaskRequest: Sendable, Equatable {
    var task: String
    var resources: [ResourceItem]
    var images: [PromptImage]
}

/// Hooks the island uses to journal each subtask while the agents are still running.
struct SplitTaskCallbacks: Sendable {
    var onPlannerProgress: @Sendable (ExecutionProgress) async -> Void
    var onPlan: @Sendable (SplitPlan) async -> Void
    var onSubtaskProgress: @Sendable (Int, ExecutionProgress) async -> Void
    var onSubtaskFinished: @Sendable (Int, SplitSubtaskOutcome) async -> Void
    var onSummaryProgress: @Sendable (ExecutionProgress) async -> Void

    static let ignore = SplitTaskCallbacks(
        onPlannerProgress: { _ in },
        onPlan: { _ in },
        onSubtaskProgress: { _, _ in },
        onSubtaskFinished: { _, _ in },
        onSummaryProgress: { _ in }
    )
}

protocol SplitTaskCollaborating: Sendable {
    func collaborate(
        _ request: SplitTaskRequest,
        callbacks: SplitTaskCallbacks
    ) async throws -> SplitCollaborationResult
}

/// Turns a planner agent's text into 2–4 subtasks.
enum SplitPlanParser {
    static let minimumCount = 2
    static let maximumCount = 4

    static func parse(_ text: String) throws -> SplitPlan {
        let data = try jsonData(from: text)
        let wires: [Wire]
        if let wrapped = try? JSONDecoder().decode(Wrapper.self, from: data) {
            wires = wrapped.subtasks
        } else if let array = try? JSONDecoder().decode([Wire].self, from: data) {
            wires = array
        } else {
            throw IslandError.executorFailed("规划结果不是可识别的子任务列表。")
        }

        var subtasks: [SplitSubtask] = []
        for wire in wires {
            let prompt = clip(wire.resolvedPrompt, limit: 4000)
            guard !prompt.isEmpty else { continue }
            let rawTitle = clip(wire.resolvedTitle, limit: 16)
            let title = rawTitle.isEmpty ? clip(prompt, limit: 16) : rawTitle
            guard !title.isEmpty else { continue }
            subtasks.append(SplitSubtask(title: title, prompt: prompt))
        }
        guard subtasks.count >= minimumCount else {
            throw IslandError.executorFailed("规划结果不足 \(minimumCount) 个子任务。")
        }
        return SplitPlan(subtasks: Array(subtasks.prefix(maximumCount)))
    }

    private struct Wrapper: Decodable {
        var subtasks: [Wire]
    }

    private struct Wire: Decodable {
        var title: String?
        var name: String?
        var prompt: String?
        var task: String?

        var resolvedTitle: String { title ?? name ?? "" }
        var resolvedPrompt: String { prompt ?? task ?? "" }
    }

    private static func jsonData(from text: String) throws -> Data {
        let source = fencedJSON(in: text) ?? text
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(where: { $0 == "{" || $0 == "[" }),
              let end = trimmed.lastIndex(where: { $0 == "}" || $0 == "]" }),
              start <= end
        else {
            throw IslandError.executorFailed("规划结果里没有 JSON。")
        }
        return Data(trimmed[start...end].utf8)
    }

    private static func fencedJSON(in text: String) -> String? {
        guard let open = text.range(of: "```") else { return nil }
        var body = text[open.upperBound...]
        if body.lowercased().hasPrefix("json") {
            body = body.dropFirst(4)
        }
        guard let close = body.range(of: "```") else { return nil }
        return String(body[..<close.lowerBound])
    }

    private static func clip(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit))
    }
}

/// Prompts that hand the original task to workers and worker results to the summarizer.
enum SplitTaskPrompts {
    static func planner(task: String, attachment: String) -> String {
        """
        你是规划 agent。把下面的大任务拆成 \(SplitPlanParser.minimumCount) 到 \(SplitPlanParser.maximumCount) 个可以同时做的子任务，彼此不要依赖对方的结果。
        只回复一个 JSON 对象，不要加解释。格式：
        {"subtasks":[{"title":"短标题","prompt":"交给执行 agent 的完整说明"}]}
        title 不超过 16 个字。prompt 要写清该子任务的目标和交付物。

        大任务：
        \(task)
        \(attachmentBlock(attachment))
        \(GrokPromptBuilder.answerRules)
        """
    }

    static func worker(
        task: String,
        subtask: SplitSubtask,
        siblings: [String],
        attachment: String
    ) -> String {
        let others = siblings.isEmpty ? "（没有）" : siblings.joined(separator: "、")
        return """
        你和其他 agent 并行，只做分配给你的子任务。做完后结果会原样交给汇总 agent，请给出完整、可独立阅读的结论。
        \(GrokPromptBuilder.answerRules)

        大任务：
        \(task)

        你的子任务：\(subtask.title)
        \(subtask.prompt)

        其他子任务（不要做）：\(others)
        \(attachmentBlock(attachment))
        """
    }

    static func summarizer(task: String, outcomes: [SplitSubtaskOutcome]) -> String {
        let blocks = outcomes.map { outcome -> String in
            let status = outcome.succeeded ? "完成" : "失败"
            return """
            ### \(outcome.title)（\(status)）
            \(outcome.text)
            """
        }.joined(separator: "\n\n")
        return """
        你是汇总 agent。下面是同一个大任务拆开后、由其他 agent 并行做完的结果。请合成一份中文 Markdown：先给总括，再按子任务保留要点。失败的子任务必须明确标出，不要当成成功，也不要编造它的结论。
        \(GrokPromptBuilder.answerRules)

        大任务：
        \(task)

        各子任务结果：
        \(blocks)
        """
    }

    private static func attachmentBlock(_ attachment: String) -> String {
        let trimmed = attachment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return "\n附件：\n\(trimmed)\n"
    }
}

/// Builds the journal body. The failure mark stays even when the summarizer skips a failed subtask.
enum SplitTaskSummary {
    static let failedMark = "【失败】"
    static let doneMark = "【完成】"

    static func headline(for outcomes: [SplitSubtaskOutcome]) -> String {
        let failed = outcomes.filter { !$0.succeeded }.count
        if failed == 0 { return "已汇总 \(outcomes.count) 个子任务" }
        if failed == outcomes.count { return "\(outcomes.count) 个子任务都失败了" }
        return "\(outcomes.count - failed)/\(outcomes.count) 完成，\(failed) 个失败"
    }

    static func compose(
        task: String,
        outcomes: [SplitSubtaskOutcome],
        narrative: String?
    ) -> String {
        let headline = headline(for: outcomes)
        var parts: [String] = ["## 汇总", headline]
        let story = narrative?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if story.isEmpty {
            parts.append("汇总 agent 没有返回正文，下面是各子任务的原始结果。")
        } else {
            parts.append(story)
        }
        parts.append("任务：\(task)")
        parts.append("## 子任务")
        for (index, outcome) in outcomes.enumerated() {
            let mark = outcome.succeeded ? doneMark : failedMark
            var block = "### \(index + 1). \(outcome.title) \(mark)\n\n\(outcome.text)"
            if let link = outcome.link, !link.isEmpty {
                block += "\n\n链接：\(link)"
            }
            parts.append(block)
        }
        return parts.joined(separator: "\n\n")
    }

    static func result(
        task: String,
        outcomes: [SplitSubtaskOutcome],
        narrative: String?,
        link: String?
    ) -> SplitCollaborationResult {
        SplitCollaborationResult(
            markdown: compose(task: task, outcomes: outcomes, narrative: narrative),
            headline: headline(for: outcomes),
            outcomes: outcomes,
            link: link
        )
    }
}

/// Plans one task, runs the subtasks as parallel cloud agents, then hands every result to a summarizer.
struct CursorSplitTaskOrchestrator: SplitTaskCollaborating {
    var credentials: @Sendable () -> CursorCredentials?
    var transport: any HTTPTransport = URLSessionTransport()
    var pollInterval: Duration = .seconds(2)
    var timeout: TimeInterval = 20 * 60

    static let plannerName = "grok岛 · 规划"
    static let summaryName = "grok岛 · 汇总"

    static func workerName(_ title: String) -> String {
        "grok岛 · 子任务 · \(title)"
    }

    func collaborate(
        _ request: SplitTaskRequest,
        callbacks: SplitTaskCallbacks
    ) async throws -> SplitCollaborationResult {
        guard let credentials = credentials() else {
            throw IslandError.executorFailed("还没有 Cursor API key：点岛右上角的齿轮填入（cursor.com/dashboard → API Keys）。")
        }
        let api = CursorCloudAPI(apiKey: credentials.apiKey, transport: transport)
        let modelID: String?
        if credentials.modelID.isEmpty {
            modelID = await GrokModelPicker.shared.modelID(using: api)
        } else {
            modelID = credentials.modelID
        }

        var images = Array(request.images.prefix(GrokPromptBuilder.maxImages))
        let attachment = GrokPromptBuilder.resourceSection(resources: request.resources, images: &images)
        let plan = try await plan(
            task: request.task,
            attachment: attachment,
            images: images,
            api: api,
            modelID: modelID,
            callbacks: callbacks
        )
        await callbacks.onPlan(plan)

        let outcomes = try await runWorkers(
            plan: plan,
            task: request.task,
            attachment: attachment,
            images: images,
            api: api,
            modelID: modelID,
            callbacks: callbacks
        )

        let narrative = try await summarize(
            task: request.task,
            outcomes: outcomes,
            api: api,
            modelID: modelID,
            callbacks: callbacks
        )
        return SplitTaskSummary.result(
            task: request.task,
            outcomes: outcomes,
            narrative: narrative.text,
            link: narrative.link
        )
    }

    private func plan(
        task: String,
        attachment: String,
        images: [PromptImage],
        api: CursorCloudAPI,
        modelID: String?,
        callbacks: SplitTaskCallbacks
    ) async throws -> SplitPlan {
        let finish = try await api.completeAgent(
            name: Self.plannerName,
            prompt: SplitTaskPrompts.planner(task: task, attachment: attachment),
            images: images,
            modelID: modelID,
            activity: "正在拆分任务",
            pollInterval: pollInterval,
            timeout: timeout,
            progress: callbacks.onPlannerProgress
        )
        switch finish {
        case .finished(let text, _):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw IslandError.executorFailed("规划 agent 没有返回可执行的子任务。")
            }
            return try SplitPlanParser.parse(trimmed)
        case .failed(let status, _):
            throw IslandError.executorFailed("规划失败：\(status)")
        }
    }

    private func runWorkers(
        plan: SplitPlan,
        task: String,
        attachment: String,
        images: [PromptImage],
        api: CursorCloudAPI,
        modelID: String?,
        callbacks: SplitTaskCallbacks
    ) async throws -> [SplitSubtaskOutcome] {
        try await withThrowingTaskGroup(of: (Int, SplitSubtaskOutcome).self) { group in
            for (index, subtask) in plan.subtasks.enumerated() {
                let siblings = plan.subtasks.enumerated().compactMap { offset, other in
                    offset == index ? nil : other.title
                }
                group.addTask {
                    let outcome = try await self.runWorker(
                        index: index,
                        subtask: subtask,
                        siblings: siblings,
                        task: task,
                        attachment: attachment,
                        images: images,
                        api: api,
                        modelID: modelID,
                        callbacks: callbacks
                    )
                    await callbacks.onSubtaskFinished(index, outcome)
                    return (index, outcome)
                }
            }
            var pairs: [(Int, SplitSubtaskOutcome)] = []
            for try await pair in group {
                pairs.append(pair)
            }
            return pairs.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func runWorker(
        index: Int,
        subtask: SplitSubtask,
        siblings: [String],
        task: String,
        attachment: String,
        images: [PromptImage],
        api: CursorCloudAPI,
        modelID: String?,
        callbacks: SplitTaskCallbacks
    ) async throws -> SplitSubtaskOutcome {
        try Task.checkCancellation()
        let prompt = SplitTaskPrompts.worker(
            task: task,
            subtask: subtask,
            siblings: siblings,
            attachment: attachment
        )
        do {
            let finish = try await api.completeAgent(
                name: Self.workerName(subtask.title),
                prompt: prompt,
                images: images,
                modelID: modelID,
                activity: subtask.title,
                pollInterval: pollInterval,
                timeout: timeout
            ) { progress in
                await callbacks.onSubtaskProgress(index, progress)
            }
            switch finish {
            case .finished(let text, let link):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return SplitSubtaskOutcome(
                    title: subtask.title,
                    prompt: subtask.prompt,
                    succeeded: true,
                    text: trimmed.isEmpty ? "（没有文字结果）" : trimmed,
                    link: link
                )
            case .failed(let status, let link):
                return SplitSubtaskOutcome(
                    title: subtask.title,
                    prompt: subtask.prompt,
                    succeeded: false,
                    text: "运行结束状态：\(status)",
                    link: link
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return SplitSubtaskOutcome(
                title: subtask.title,
                prompt: subtask.prompt,
                succeeded: false,
                text: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                link: nil
            )
        }
    }

    /// The summarizer failing does not drop the worker results; the combined markdown still lists them.
    private func summarize(
        task: String,
        outcomes: [SplitSubtaskOutcome],
        api: CursorCloudAPI,
        modelID: String?,
        callbacks: SplitTaskCallbacks
    ) async throws -> (text: String?, link: String?) {
        do {
            let finish = try await api.completeAgent(
                name: Self.summaryName,
                prompt: SplitTaskPrompts.summarizer(task: task, outcomes: outcomes),
                images: [],
                modelID: modelID,
                activity: "正在汇总",
                pollInterval: pollInterval,
                timeout: timeout,
                progress: callbacks.onSummaryProgress
            )
            switch finish {
            case .finished(let text, let link):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return (trimmed.isEmpty ? nil : trimmed, link)
            case .failed(_, let link):
                return (nil, link)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return (nil, nil)
        }
    }
}
