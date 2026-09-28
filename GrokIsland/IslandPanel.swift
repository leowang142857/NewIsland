import AppKit
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

/// Borderless always-on-top panel, pinned to the top center of the preferred screen.
///
/// Chrome (dark glass, neon edge, code rain) lives in the SwiftUI root.
/// Proximity show / auto-retract is wired here.
final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    convenience init(contentRect: NSRect) {
        self.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
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

    static func topY(on screen: NSScreen) -> CGFloat {
        screen.safeAreaInsets.top > 0 ? screen.frame.maxY : screen.visibleFrame.maxY
    }

    /// Notch: pin to `frame.maxY`. No notch: sit just under the menu bar (`visibleFrame.maxY`).
    static func topCenterFrame(size: CGSize, on screen: NSScreen) -> NSRect {
        let x = screen.frame.midX - size.width / 2
        let top = topY(on: screen)
        return NSRect(origin: NSPoint(x: x, y: top - size.height), size: size)
    }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// UI chrome only. Not persisted. Polls `NSEvent.mouseLocation` — no Accessibility permission.
@MainActor
final class IslandPresence: ObservableObject {
    @Published var isRevealed = false
    @Published var isPinned = false
    @Published var isDropTargeted = false
    @Published var isHoveringPanel = false

    func shouldHold(engine: IslandEngine) -> Bool {
        isPinned || isDropTargeted || isHoveringPanel || engine.pendingLocal != nil
    }
}

@MainActor
final class IslandPanelController {
    static let peekSize = CGSize(width: 196, height: 22)
    /// Wide enough for Grok answers and the quick-action row.
    static let shellSize = CGSize(width: 300, height: 400)
    static let retractDelay: TimeInterval = 0.55
    static let pollInterval: TimeInterval = 0.08

    private let engine: IslandEngine
    let presence = IslandPresence()
    private let panel: IslandPanel
    private var screenObserver: NSObjectProtocol?
    private var pollTimer: Timer?
    private var retractWork: DispatchWorkItem?
    private var revealedOnScreen: NSScreen?

    init(engine: IslandEngine, monitor: CloudActivityMonitor, settings: IslandSettings) {
        self.engine = engine
        let frame = ScreenAnchor.topCenterFrame(size: Self.peekSize, on: ScreenAnchor.preferredScreen())
        panel = IslandPanel(contentRect: frame)
        let root = IslandRootView(engine: engine, presence: presence, monitor: monitor, settings: settings)
        let host = FirstMouseHostingView(rootView: root)
        host.wantsLayer = true
        host.appearance = NSAppearance(named: .darkAqua)
        host.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = host

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.applyFrame(animated: false)
            }
        }
    }

    func show() {
        applyFrame(animated: false)
        panel.orderFrontRegardless()
        startPolling()
        tick()
    }

    func reposition() {
        applyFrame(animated: false)
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        if let pollTimer {
            RunLoop.main.add(pollTimer, forMode: .common)
        }
    }

    private func tick() {
        if mouseInHotZone() || presence.shouldHold(engine: engine) {
            cancelRetract()
            setRevealed(true)
        } else if presence.isRevealed {
            scheduleRetract()
        } else {
            applyFrame(animated: false)
        }
    }

    private func setRevealed(_ revealed: Bool) {
        if revealed, !presence.isRevealed {
            revealedOnScreen = ScreenAnchor.preferredScreen()
            presence.isRevealed = true
            applyFrame(animated: true)
            panel.makeKeyAndOrderFront(nil)
        } else if !revealed, presence.isRevealed {
            presence.isRevealed = false
            presence.isHoveringPanel = false
            revealedOnScreen = nil
            applyFrame(animated: true)
        }
    }

    private func scheduleRetract() {
        guard retractWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.retractWork = nil
            if !self.mouseInHotZone(), !self.presence.shouldHold(engine: self.engine) {
                self.setRevealed(false)
            }
        }
        retractWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retractDelay, execute: work)
    }

    private func cancelRetract() {
        retractWork?.cancel()
        retractWork = nil
    }

    private func applyFrame(animated: Bool) {
        let screen: NSScreen
        if presence.isRevealed, let pinned = revealedOnScreen {
            screen = pinned
        } else {
            screen = ScreenAnchor.preferredScreen()
        }
        let size = presence.isRevealed ? Self.shellSize : Self.peekSize
        let next = ScreenAnchor.topCenterFrame(size: size, on: screen)
        guard panel.frame != next else { return }
        if animated {
            // Soft settle, matched to `IslandChrome.expandSpring` on the SwiftUI scale.
            // Control points stay inside 0...1 so the top-pinned frame does not overshoot offscreen.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.42
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.22, 1.0)
                context.allowsImplicitAnimation = true
                panel.animator().setFrame(next, display: true)
            }
        } else {
            panel.setFrame(next, display: true)
        }
    }

    /// Uses `NSEvent.mouseLocation` (no Accessibility / Input Monitoring).
    private func mouseInHotZone() -> Bool {
        let mouse = NSEvent.mouseLocation
        let screen = presence.isRevealed
            ? (revealedOnScreen ?? ScreenAnchor.preferredScreen())
            : ScreenAnchor.preferredScreen()
        return Self.hotZone(
            revealed: presence.isRevealed,
            panelFrame: panel.frame,
            screen: screen
        ).contains(mouse)
    }

    /// Retracted: only the peek strip itself. Revealed: the panel, with a tiny
    /// edge so moving onto a button at the border does not instantly hide it.
    static func hotZone(revealed: Bool, panelFrame: NSRect, screen: NSScreen) -> NSRect {
        if revealed {
            return panelFrame.insetBy(dx: -4, dy: -4)
        }
        return panelFrame
    }
}

struct IslandRootView: View {
    @ObservedObject var engine: IslandEngine
    @ObservedObject var presence: IslandPresence
    @ObservedObject var monitor: CloudActivityMonitor
    @ObservedObject var settings: IslandSettings

    var body: some View {
        ZStack {
            if presence.isRevealed {
                ShellView(engine: engine, presence: presence, monitor: monitor, settings: settings)
                    .transition(IslandChrome.revealTransition)
            } else {
                PeekStripView(engine: engine, presence: presence, monitor: monitor)
                    .transition(IslandChrome.revealTransition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(IslandChrome.expandSpring, value: presence.isRevealed)
        .preferredColorScheme(.dark)
        .tint(IslandChrome.neonCyan)
        .onChange(of: engine.activeRunCount) { monitor.flash() }
    }
}

/// Thin top-center tab while the shell is retracted.
struct PeekStripView: View {
    @ObservedObject var engine: IslandEngine
    @ObservedObject var presence: IslandPresence
    @ObservedObject var monitor: CloudActivityMonitor

    var body: some View {
        let snapshot = monitor.snapshot
        HStack(spacing: 7) {
            ActivityLight(
                busy: snapshot.isBusy || engine.activeRunCount > 0,
                warning: snapshot.hasFailingChecks,
                size: 6
            )
            Text("grok岛")
                .font(.caption.weight(.semibold))
            if engine.activeRunCount > 0 {
                Label("\(engine.activeRunCount)", systemImage: "sparkles")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if !snapshot.agents.isEmpty {
                Text("☁︎\(snapshot.agents.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if !snapshot.pullRequests.isEmpty {
                Text("PR\(snapshot.pullRequests.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .islandChrome(Capsule(), rainVeil: 0.22, emphasized: presence.isDropTargeted)
        .islandFlash(Capsule(), trigger: monitor.flashCount)
        .onHover { hovering in
            presence.isHoveringPanel = hovering
        }
        // Dragging over the strip only reveals the shell; resources are dropped onto a module tile.
        .onDrop(of: [UTType.fileURL, UTType.url, UTType.plainText], isTargeted: dropBinding) { _ in
            false
        }
    }

    private var dropBinding: Binding<Bool> {
        Binding(
            get: { presence.isDropTargeted },
            set: { presence.isDropTargeted = $0 }
        )
    }
}
