import AppKit
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

/// Borderless always-on-top panel, pinned to the top center of the preferred screen.
///
/// Chrome (aurora glass, aurora edge) lives in the SwiftUI root.
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
    /// Extra gap under the camera housing so expanded chrome is not flush against the notch.
    static let expandedNotchGap: CGFloat = 6

    static func preferredScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        if let hit = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            return hit
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    /// Peek strip: nest into the notch / menu-bar band (Dynamic Island style).
    static func topY(on screen: NSScreen) -> CGFloat {
        screen.safeAreaInsets.top > 0 ? screen.frame.maxY : screen.visibleFrame.maxY
    }

    /// Expanded shell: sit fully below the camera housing so the header middle is not clipped.
    static func expandedTopY(on screen: NSScreen) -> CGFloat {
        if screen.safeAreaInsets.top > 0 {
            return screen.frame.maxY - screen.safeAreaInsets.top - expandedNotchGap
        }
        return screen.visibleFrame.maxY
    }

    /// Notch peek pins to `frame.maxY`. Expanded clears the notch. No notch: under the menu bar.
    static func topCenterFrame(size: CGSize, on screen: NSScreen, clearsNotch: Bool = false) -> NSRect {
        let x = screen.frame.midX - size.width / 2
        let top = clearsNotch ? expandedTopY(on: screen) : topY(on: screen)
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
    /// Room for a row of per-task lights on the left and the next DDL on the right.
    static let defaultPeekSize = CGSize(width: 240, height: 22)
    /// On notched screens each side of the camera housing gets this much visible strip.
    static let peekWingWidth: CGFloat = 90
    /// Status lights, DDL bar, function strips, and the module grid stacked in layers.
    static let shellSize = CGSize(width: 340, height: 520)
    static let retractDelay: TimeInterval = 0.55
    static let pollInterval: TimeInterval = 0.08

    private let engine: IslandEngine
    let presence = IslandPresence()
    private let panel: IslandPanel
    private var screenObserver: NSObjectProtocol?
    private var pollTimer: Timer?
    private var retractWork: DispatchWorkItem?
    private var revealedOnScreen: NSScreen?

    init(
        engine: IslandEngine,
        monitor: CloudActivityMonitor,
        settings: IslandSettings,
        deadlines: DeadlineStore
    ) {
        self.engine = engine
        let screen = ScreenAnchor.preferredScreen()
        let frame = ScreenAnchor.topCenterFrame(size: Self.peekSize(on: screen), on: screen)
        panel = IslandPanel(contentRect: frame)
        let root = IslandRootView(
            engine: engine,
            presence: presence,
            monitor: monitor,
            settings: settings,
            deadlines: deadlines
        )
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
        let size = presence.isRevealed ? Self.shellSize : Self.peekSize(on: screen)
        // Expanded: drop below the webcam/notch so the top-row middle stays readable.
        let next = ScreenAnchor.topCenterFrame(size: size, on: screen, clearsNotch: presence.isRevealed)
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

    /// Straddles the notch so the lights and DDL badge sit either side of the camera.
    static func peekSize(on screen: NSScreen) -> CGSize {
        guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else {
            return defaultPeekSize
        }
        let notch = screen.frame.width - left.width - right.width
        guard notch > 0 else { return defaultPeekSize }
        return CGSize(width: max(defaultPeekSize.width, notch + 2 * peekWingWidth), height: defaultPeekSize.height)
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
    @ObservedObject var deadlines: DeadlineStore

    var body: some View {
        ZStack {
            if presence.isRevealed {
                ShellView(
                    engine: engine,
                    presence: presence,
                    monitor: monitor,
                    settings: settings,
                    deadlines: deadlines
                )
                .transition(IslandChrome.revealTransition)
            } else {
                PeekStripView(engine: engine, presence: presence, monitor: monitor, deadlines: deadlines)
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

/// Thin top-center tab while the shell is retracted: one light per task on the left,
/// the most pressing DDL on the right. Everything else waits for the expanded island.
struct PeekStripView: View {
    @ObservedObject var engine: IslandEngine
    @ObservedObject var presence: IslandPresence
    @ObservedObject var monitor: CloudActivityMonitor
    @ObservedObject var deadlines: DeadlineStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            content(now: context.date)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .islandChrome(Capsule(), glow: 0.8, emphasized: presence.isDropTargeted)
        .islandFlash(Capsule(), trigger: monitor.flashCount)
        .onHover { hovering in
            presence.isHoveringPanel = hovering
        }
        // Dragging over the strip only reveals the shell; resources are dropped onto a module tile.
        .onDrop(of: ShellView.dropTypes, isTargeted: dropBinding) { _ in
            false
        }
    }

    private func content(now: Date) -> some View {
        let lights = TaskLightBoard.lights(runs: engine.runs, snapshot: monitor.snapshot, now: now)
        let next = deadlines.summary(now: now).next
        return HStack(spacing: 6) {
            TaskLightStrip(lights: lights)
            Spacer(minLength: 6)
            Text("grok岛")
                .font(.caption.weight(.semibold))
            if let next, next.urgency(now: now).isPressing {
                DeadlineBadge(item: next, now: now)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var dropBinding: Binding<Bool> {
        Binding(
            get: { presence.isDropTargeted },
            set: { presence.isDropTargeted = $0 }
        )
    }
}
