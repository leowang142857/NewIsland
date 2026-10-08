import AppKit
import ScreenCaptureKit

/// Captures the frontmost window (never the island) plus the browser URL when there is one.
enum PageCapture {
    static let maxPixelDimension: CGFloat = 2048
    static let pngLimitBytes = 4 * 1024 * 1024

    private static let safariLike: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview"
    ]
    private static let chromiumLike: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera"
    ]

    static var hasScreenRecordingAccess: Bool { CGPreflightScreenCaptureAccess() }

    static let screenRecordingSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    )!

    @MainActor
    static func snapshot() async -> PageSnapshot {
        let frontApp = NSWorkspace.shared.frontmostApplication
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let targetPID = frontApp?.processIdentifier == ownPID ? nil : frontApp?.processIdentifier

        var page = PageSnapshot()
        guard let window = frontWindow(ownerPID: targetPID, excludingPID: ownPID) else {
            page.captureNote = "没找到可以截图的窗口。先点一下要处理的页面，再点岛上的按钮。"
            return page
        }
        page.appName = window.ownerName
        page.windowTitle = window.title

        if let bundleID = NSRunningApplication(processIdentifier: window.ownerPID)?.bundleIdentifier {
            page.pageURL = browserURL(bundleID: bundleID)
        }

        if !hasScreenRecordingAccess {
            _ = CGRequestScreenCaptureAccess()
        }
        guard hasScreenRecordingAccess else {
            page.captureNote = "需要屏幕录制权限：系统设置 → 隐私与安全性 → 屏幕录制，勾选 NewIsland 后重开 app。"
            return page
        }

        do {
            page.screenshot = try await capture(windowID: window.id, frame: window.frame)
        } catch {
            page.captureNote = "截图失败：\(error.localizedDescription)"
        }
        return page
    }

    private struct WindowInfo {
        var id: CGWindowID
        var ownerPID: pid_t
        var ownerName: String?
        var title: String?
        var frame: CGRect
    }

    /// `CGWindowListCopyWindowInfo` is front-to-back, so the first normal window wins.
    private static func frontWindow(ownerPID: pid_t?, excludingPID: pid_t) -> WindowInfo? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for entry in list {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != excludingPID,
                  let number = entry[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= 120, bounds.height >= 120
            else { continue }
            if let ownerPID, pid != ownerPID { continue }
            if let alpha = entry[kCGWindowAlpha as String] as? Double, alpha <= 0.01 { continue }
            return WindowInfo(
                id: number,
                ownerPID: pid,
                ownerName: entry[kCGWindowOwnerName as String] as? String,
                title: entry[kCGWindowName as String] as? String,
                frame: bounds
            )
        }
        return nil
    }

    private static func capture(windowID: CGWindowID, frame: CGRect) async throws -> PromptImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw IslandError.pageCaptureFailed("窗口已经关闭或被移走。")
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let backingScale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        let scale = min(backingScale, maxPixelDimension / max(frame.width, frame.height, 1))
        config.width = max(1, Int(frame.width * scale))
        config.height = max(1, Int(frame.height * scale))
        config.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let rep = NSBitmapImageRep(cgImage: image)
        if let png = rep.representation(using: .png, properties: [:]), png.count <= pngLimitBytes {
            return PromptImage(data: png, mimeType: "image/png")
        }
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            throw IslandError.pageCaptureFailed("截图编码失败。")
        }
        return PromptImage(data: jpeg, mimeType: "image/jpeg")
    }

    /// Needs Automation permission for that browser the first time (macOS asks once).
    @MainActor
    private static func browserURL(bundleID: String) -> String? {
        let source: String
        if safariLike.contains(bundleID) {
            source = "tell application id \"\(bundleID)\" to return URL of front document"
        } else if chromiumLike.contains(bundleID) {
            source = "tell application id \"\(bundleID)\" to return URL of active tab of front window"
        } else {
            return nil
        }
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard error == nil, let url = result?.stringValue, !url.isEmpty else { return nil }
        return url
    }
}
