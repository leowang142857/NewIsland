import AppKit
import SwiftUI

/// Borderless always-on-top panel, pinned to the top center of the preferred screen.
///
/// TODO(frontend): Replace this functional host with the Dynamic Island chrome,
/// hover/expand animations, notch-aware metrics, and glass treatment.
final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    convenience init(contentRect: NSRect) {
        self.init(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .none
        isMovableByWindowBackground = false
    }
}

enum ScreenAnchor {
    static func preferredScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        if let hit = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            return hit
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    /// Notch: pin to `frame.maxY`. No notch: sit just under the menu bar (`visibleFrame.maxY`).
    static func topCenterFrame(size: CGSize, on screen: NSScreen) -> NSRect {
        let x = screen.frame.midX - size.width / 2
        let top = screen.safeAreaInsets.top > 0 ? screen.frame.maxY : screen.visibleFrame.maxY
        return NSRect(origin: NSPoint(x: x, y: top - size.height), size: size)
    }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class IslandPanelController {
    private let engine: IslandEngine
    private let panel: IslandPanel
    private var screenObserver: NSObjectProtocol?

    /// TODO(frontend): Drive this size from island compact/expanded states.
    static let shellSize = CGSize(width: 520, height: 620)

    init(engine: IslandEngine) {
        self.engine = engine
        let frame = ScreenAnchor.topCenterFrame(size: Self.shellSize, on: ScreenAnchor.preferredScreen())
        panel = IslandPanel(contentRect: frame)
        let host = FirstMouseHostingView(rootView: ShellView(engine: engine))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = host

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reposition()
            }
        }
    }

    func show() {
        reposition()
        panel.makeKeyAndOrderFront(nil)
    }

    func reposition() {
        let next = ScreenAnchor.topCenterFrame(size: Self.shellSize, on: ScreenAnchor.preferredScreen())
        panel.setFrame(next, display: true)
    }
}
