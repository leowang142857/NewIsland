import Foundation

/// One-tap Grok jobs that read whatever page is frontmost.
enum GrokQuickAction: String, CaseIterable, Identifiable, Sendable {
    case organizeMistakes
    case solveProblems
    case reviewPageCode
    case askAboutPage

    static let buttons: [GrokQuickAction] = [.organizeMistakes, .solveProblems, .reviewPageCode]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .organizeMistakes: "整理错题"
        case .solveProblems: "解答题目"
        case .reviewPageCode: "检查代码"
        case .askAboutPage: "问 Grok"
        }
    }

    var symbolName: String {
        switch self {
        case .organizeMistakes: "checklist"
        case .solveProblems: "graduationcap"
        case .reviewPageCode: "chevron.left.forwardslash.chevron.right"
        case .askAboutPage: "sparkles"
        }
    }

    var prompt: String {
        switch self {
        case .organizeMistakes:
            """
            附图是我当前屏幕上的页面（作业、试卷、练习或批改结果）。把其中做错、被标记为错误或没做出来的题整理成错题本。每道题按下面的格式：
            ### 第 N 题
            - 题目：（原文）
            - 我的答案：（截图里能看到的话）
            - 正确答案：
            - 错因：
            - 知识点：
            - 同类题提醒：
            最后用 3 条以内总结我最该补的知识点。页面上看不出对错时，逐题判断我的作答是否正确再整理。
            """
        case .solveProblems:
            """
            解答附图（我当前屏幕上的页面）里的题目。每道题按下面的格式：
            ### 第 N 题
            - 思路：
            - 步骤：（逐步推导，公式用 LaTeX）
            - 答案：
            有多道题时全部解答；题目不完整时说明缺了什么。
            """
        case .reviewPageCode:
            """
            检查我当前页面上的代码（附图是页面截图；如果给了网址，可以直接打开或下载页面源码查看）。按严重程度列出：
            1. Bug 和会导致出错的问题
            2. 安全隐患
            3. 性能和可读性改进
            每条都指出位置、原因，并给出修改后的代码片段。没有问题的部分不用复述。
            """
        case .askAboutPage:
            "结合附图（我当前屏幕上的页面）回答我的问题。"
        }
    }
}

/// One of the three shortcut buttons: a built-in quick action, or a custom title and prompt.
///
/// Custom text is kept when the slot is switched back to a built-in, the same way a custom
/// island background keeps its colors when the kind changes.
struct IslandShortcutSlot: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case builtin
        case custom
    }

    static let symbolAllowlist = [
        "checklist",
        "graduationcap",
        "chevron.left.forwardslash.chevron.right",
        "sparkles",
        "text.quote",
        "doc.text.magnifyingglass",
        "function",
        "globe",
        "book",
        "lightbulb"
    ]
    static let fallbackSymbol = "sparkles"
    static let maxTitleLength = 16
    static let maxPromptLength = 4000

    var kind: Kind
    var actionRaw: String
    var customTitle: String
    var customPrompt: String
    var customSymbol: String
    /// Saved kind was neither builtin nor custom. Dropped by `IslandShortcutButtons.sanitized()`.
    var hasUnknownKind: Bool

    static func builtin(_ action: GrokQuickAction) -> IslandShortcutSlot {
        IslandShortcutSlot(
            kind: .builtin,
            actionRaw: action.rawValue,
            customTitle: "",
            customPrompt: "",
            customSymbol: fallbackSymbol
        )
    }

    init(
        kind: Kind,
        actionRaw: String,
        customTitle: String,
        customPrompt: String,
        customSymbol: String,
        hasUnknownKind: Bool = false
    ) {
        self.kind = kind
        self.actionRaw = actionRaw
        self.customTitle = customTitle
        self.customPrompt = customPrompt
        self.customSymbol = customSymbol
        self.hasUnknownKind = hasUnknownKind
    }

    private enum CodingKeys: String, CodingKey {
        case kind, actionRaw, customTitle, customPrompt, customSymbol
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedKind = Self.decodeKind(from: container)
        kind = decodedKind.kind
        hasUnknownKind = decodedKind.unknown
        actionRaw = (try? container.decodeIfPresent(String.self, forKey: .actionRaw)) ?? ""
        customTitle = (try? container.decodeIfPresent(String.self, forKey: .customTitle)) ?? ""
        customPrompt = (try? container.decodeIfPresent(String.self, forKey: .customPrompt)) ?? ""
        customSymbol = (try? container.decodeIfPresent(String.self, forKey: .customSymbol)) ?? Self.fallbackSymbol
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(actionRaw, forKey: .actionRaw)
        try container.encode(customTitle, forKey: .customTitle)
        try container.encode(customPrompt, forKey: .customPrompt)
        try container.encode(customSymbol, forKey: .customSymbol)
    }

    private static func decodeKind(
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> (kind: Kind, unknown: Bool) {
        guard container.contains(.kind) else { return (.builtin, false) }
        if (try? container.decodeNil(forKey: .kind)) == true { return (.builtin, false) }
        guard let raw = try? container.decode(String.self, forKey: .kind) else { return (.builtin, true) }
        guard let kind = Kind(rawValue: raw) else { return (.builtin, true) }
        return (kind, false)
    }

    fileprivate static func clipped(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit))
    }
}

/// The three shortcut buttons shown in the expanded island.
struct IslandShortcutButtons: Codable, Equatable, Sendable {
    static let count = 3

    var slots: [IslandShortcutSlot]

    static let `default` = IslandShortcutButtons(
        slots: GrokQuickAction.buttons.map(IslandShortcutSlot.builtin)
    )

    init(slots: [IslandShortcutSlot]) {
        self.slots = slots
    }

    /// Exactly three slots, with limits and the symbol allowlist applied. Unknown kinds and
    /// unusable built-in actions fall back per index; custom text is kept.
    func sanitized() -> IslandShortcutButtons {
        var next: [IslandShortcutSlot] = []
        next.reserveCapacity(Self.count)
        for index in 0..<Self.count {
            let fallback = Self.fallbackAction(at: index)
            guard slots.indices.contains(index), !slots[index].hasUnknownKind else {
                next.append(.builtin(fallback))
                continue
            }
            var slot = slots[index]
            if Self.selectableAction(slot.actionRaw) == nil {
                slot.actionRaw = fallback.rawValue
            }
            slot.customTitle = IslandShortcutSlot.clipped(slot.customTitle, limit: IslandShortcutSlot.maxTitleLength)
            slot.customPrompt = IslandShortcutSlot.clipped(slot.customPrompt, limit: IslandShortcutSlot.maxPromptLength)
            if !IslandShortcutSlot.symbolAllowlist.contains(slot.customSymbol) {
                slot.customSymbol = IslandShortcutSlot.fallbackSymbol
            }
            slot.hasUnknownKind = false
            next.append(slot)
        }
        return IslandShortcutButtons(slots: next)
    }

    /// Titles, symbols, and prompts the buttons should show. Limits apply here too, and the
    /// receiver is left as the user edited it.
    func resolved() -> [ResolvedIslandShortcut] {
        sanitized().slots.map { slot in
            switch slot.kind {
            case .builtin:
                let action = Self.selectableAction(slot.actionRaw) ?? .organizeMistakes
                return ResolvedIslandShortcut(
                    title: action.title,
                    symbolName: action.symbolName,
                    prompt: action.prompt,
                    isReady: true
                )
            case .custom:
                return ResolvedIslandShortcut(
                    title: slot.customTitle.isEmpty ? "自定义" : slot.customTitle,
                    symbolName: slot.customSymbol,
                    prompt: slot.customPrompt,
                    isReady: !slot.customPrompt.isEmpty
                )
            }
        }
    }

    private static func fallbackAction(at index: Int) -> GrokQuickAction {
        let actions = GrokQuickAction.buttons
        guard actions.indices.contains(index) else { return .organizeMistakes }
        return actions[index]
    }

    /// Built-in slot actions. `askAboutPage` stays the free-form field, never a button.
    private static func selectableAction(_ raw: String) -> GrokQuickAction? {
        guard let action = GrokQuickAction(rawValue: raw), action != .askAboutPage else { return nil }
        return GrokQuickAction.buttons.contains(action) ? action : nil
    }

    private enum CodingKeys: String, CodingKey { case slots }

    private struct LooseSlot: Decodable {
        var slot: IslandShortcutSlot

        init(from decoder: Decoder) throws {
            if let slot = try? IslandShortcutSlot(from: decoder) {
                self.slot = slot
            } else {
                self.slot = IslandShortcutSlot(
                    kind: .builtin,
                    actionRaw: "",
                    customTitle: "",
                    customPrompt: "",
                    customSymbol: IslandShortcutSlot.fallbackSymbol,
                    hasUnknownKind: true
                )
            }
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        slots = (try? container.decodeIfPresent([LooseSlot].self, forKey: .slots))?.map(\.slot) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(slots, forKey: .slots)
    }
}

/// A shortcut button after defaults, limits, and the symbol allowlist have been applied.
struct ResolvedIslandShortcut: Equatable, Sendable {
    var title: String
    var symbolName: String
    var prompt: String
    /// False when a custom slot has no prompt yet. Built-ins are always ready.
    var isReady: Bool
}

/// What the island could see of the frontmost window when a quick action fired.
struct PageSnapshot: Equatable, Sendable {
    var appName: String?
    var windowTitle: String?
    var pageURL: String?
    var screenshot: PromptImage?
    /// Why the screenshot or URL is missing, shown to the user.
    var captureNote: String?

    var hasContent: Bool { screenshot != nil || pageURL != nil }

    var contextDescription: String? {
        var lines: [String] = []
        let title = [appName, windowTitle]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
        if !title.isEmpty { lines.append("当前页面：\(title)") }
        if let pageURL, !pageURL.isEmpty {
            lines.append("网址：\(pageURL)（需要登录的页面以截图为准）")
        }
        if screenshot == nil {
            lines.append("注意：没有截到页面图片。")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
