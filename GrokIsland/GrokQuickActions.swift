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
