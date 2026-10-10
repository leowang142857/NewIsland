import AppKit
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

/// Borderless always-on-top panel, pinned to the top center of the preferred screen.
///
/// Chrome (ink glass, hairline edge) lives in the SwiftUI root.
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
        hasShadow = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        isMovableByWindowBackground = false
    }
}

/// Both the strip and the expanded island hang below the menu bar, centered under the notch,
/// so the menu bar and its status items stay visible and clickable.
enum ScreenAnchor {
    static func preferredScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        if let hit = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            return hit
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    static func menuBarHeight(on screen: NSScreen) -> CGFloat {
        IslandPlacement.menuBarHeight(
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            notchHeight: screen.safeAreaInsets.top,
            barThickness: NSStatusBar.system.thickness
        )
    }

    /// The camera housing's width, read from the menu-bar areas either side of it.
    static func notchWidth(on screen: NSScreen) -> CGFloat? {
        guard screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return nil }
        return screen.frame.width - left.width - right.width
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
    /// The island's screen has a notch, so the collapsed strip sits right under the camera.
    @Published var onNotchedScreen = false

    /// A drag out of the tray keeps the island up: its source row must outlive the drag.
    func shouldHold(engine: IslandEngine, tray: FileTray) -> Bool {
        isPinned || isDropTargeted || isHoveringPanel || engine.pendingLocal != nil
            || tray.isDraggingOut || Self.systemPickerIsOpen
    }

    /// The file picker and color panel float outside the island. Retracting under them would
    /// tear down the settings screen that opened them.
    static var systemPickerIsOpen: Bool {
        NSApp.modalWindow != nil || (NSColorPanel.sharedColorPanelExists && NSColorPanel.shared.isVisible)
    }
}

@MainActor
final class IslandPanelController {
    /// Lock + per-task lights on the left, the name, and the next DDL on the right.
    static let defaultPeekSize = CGSize(width: PeekStrip.defaultWidth, height: PeekStrip.height)
    static let retractDelay: TimeInterval = 0.55
    static let pollInterval: TimeInterval = 0.08

    private let engine: IslandEngine
    private let settings: IslandSettings
    private let tray: FileTray
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
        deadlines: DeadlineStore,
        tray: FileTray
    ) {
        self.engine = engine
        self.settings = settings
        self.tray = tray
        let screen = ScreenAnchor.preferredScreen()
        let frame = Self.frame(revealed: false, on: screen)
        panel = IslandPanel(contentRect: frame)
        let root = IslandRootView(
            engine: engine,
            presence: presence,
            monitor: monitor,
            settings: settings,
            deadlines: deadlines,
            tray: tray
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
        // A drag that ends off the island (say, back on the desktop) never reaches a drop target
        // to clear this, and the island would stay held open. A released button means it is over.
        if presence.isDropTargeted, NSEvent.pressedMouseButtons & 1 == 0 {
            presence.isDropTargeted = false
        }
        if presence.isRevealed {
            if mouseInHotZone() || presence.shouldHold(engine: engine, tray: tray) {
                cancelRetract()
            } else {
                scheduleRetract()
            }
        } else if collapsedStripWantsReveal() {
            cancelRetract()
            setRevealed(true)
        } else {
            applyFrame(animated: false)
        }
    }

    /// The peek strip's own hover flag is ignored here: the lock slice must not count as hover.
    private func collapsedStripWantsReveal() -> Bool {
        let mouse = NSEvent.mouseLocation
        let strip = Self.frame(revealed: false, on: ScreenAnchor.preferredScreen())
        return PeekStrip.shouldReveal(
            locked: settings.isPeekLocked,
            mouseInStrip: strip.contains(mouse),
            mouseOnLock: PeekStrip.isOnLock(mouseX: mouse.x, stripMinX: strip.minX),
            dropTargeted: presence.isDropTargeted,
            pinned: presence.isPinned,
            awaitingConfirmation: engine.pendingLocal != nil
        )
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
            if !self.mouseInHotZone(), !self.presence.shouldHold(engine: self.engine, tray: self.tray) {
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
        let next = Self.frame(revealed: presence.isRevealed, on: screen)
        let notched = ScreenAnchor.notchWidth(on: screen) != nil
        if presence.onNotchedScreen != notched { presence.onNotchedScreen = notched }
        // The strip is part of the notch and casts nothing; the expanded island floats over the desktop.
        if presence.isRevealed { panel.hasShadow = true }
        guard panel.frame != next else { return }
        if animated {
            // Soft settle, matched to `IslandChrome.expandSpring` on the SwiftUI scale.
            // Control points stay inside 0...1 so the top-pinned frame does not overshoot offscreen.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.42
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.22, 1.0)
                context.allowsImplicitAnimation = true
                panel.animator().setFrame(next, display: true)
            } completionHandler: { [weak self] in
                Task { @MainActor in self?.settleShadow() }
            }
        } else {
            panel.setFrame(next, display: true)
            settleShadow()
        }
    }

    /// The shadow follows the content's alpha, so recompute it once the frame and content settle.
    private func settleShadow() {
        panel.hasShadow = presence.isRevealed
        panel.invalidateShadow()
    }

    /// Strip or island, hanging below the menu bar and centered under the notch.
    static func frame(revealed: Bool, on screen: NSScreen) -> NSRect {
        let bar = ScreenAnchor.menuBarHeight(on: screen)
        if revealed {
            return IslandPlacement.shellFrame(size: shellSize(on: screen, menuBarHeight: bar), screen: screen.frame, menuBarHeight: bar)
        }
        return IslandPlacement.stripFrame(size: peekSize(on: screen), screen: screen.frame, menuBarHeight: bar)
    }

    /// A wide, short panel, as much of `IslandShell`'s 3 : 1 as the screen allows.
    static func shellSize(on screen: NSScreen, menuBarHeight: CGFloat) -> CGSize {
        let top = IslandPlacement.shellTop(screen: screen.frame, menuBarHeight: menuBarHeight)
        return IslandShell.size(screenWidth: screen.frame.width, room: top - screen.visibleFrame.minY)
    }

    /// As wide as the notch, so the strip stays in the camera's shadow.
    static func peekSize(on screen: NSScreen) -> CGSize {
        CGSize(width: PeekStrip.width(notchWidth: ScreenAnchor.notchWidth(on: screen)), height: PeekStrip.height)
    }

    /// Uses `NSEvent.mouseLocation` (no Accessibility / Input Monitoring).
    private func mouseInHotZone() -> Bool {
        let screen = presence.isRevealed
            ? (revealedOnScreen ?? ScreenAnchor.preferredScreen())
            : ScreenAnchor.preferredScreen()
        return Self.hotZone(revealed: presence.isRevealed, on: screen).contains(NSEvent.mouseLocation)
    }

    /// Measured from where the panel is headed, not where an animation has it right now.
    static func hotZone(revealed: Bool, on screen: NSScreen) -> NSRect {
        IslandPlacement.hotZone(
            revealed: revealed,
            frame: frame(revealed: revealed, on: screen),
            screen: screen.frame,
            menuBarHeight: ScreenAnchor.menuBarHeight(on: screen)
        )
    }
}

struct IslandRootView: View {
    @ObservedObject var engine: IslandEngine
    @ObservedObject var presence: IslandPresence
    @ObservedObject var monitor: CloudActivityMonitor
    @ObservedObject var settings: IslandSettings
    @ObservedObject var deadlines: DeadlineStore
    let tray: FileTray

    var body: some View {
        ZStack {
            if presence.isRevealed {
                ShellView(
                    engine: engine,
                    presence: presence,
                    monitor: monitor,
                    settings: settings,
                    deadlines: deadlines,
                    tray: tray
                )
                .transition(IslandChrome.revealTransition)
            } else {
                PeekStripView(engine: engine, presence: presence, monitor: monitor, settings: settings, deadlines: deadlines)
                    .transition(IslandChrome.revealTransition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(IslandChrome.expandSpring, value: presence.isRevealed)
        .preferredColorScheme(.dark)
        .tint(IslandChrome.accent)
        .onChange(of: engine.activeRunCount) { monitor.flash() }
    }
}

/// Small pill hanging from the bottom of the menu bar while the shell is retracted: the collapse
/// lock and one light per task on the left, the most pressing DDL on the right. On a notched Mac
/// it is exactly as wide as the notch and leaves the name out, so it reads as the camera's shadow.
/// Everything else waits for the expanded island.
struct PeekStripView: View {
    @ObservedObject var engine: IslandEngine
    @ObservedObject var presence: IslandPresence
    @ObservedObject var monitor: CloudActivityMonitor
    @ObservedObject var settings: IslandSettings
    @ObservedObject var deadlines: DeadlineStore

    private static let shape = NotchShape(flare: PeekStrip.flare)

    var body: some View {
        let emphasized = presence.isDropTargeted && !settings.isPeekLocked
        TimelineView(.periodic(from: .now, by: 5)) { context in
            content(now: context.date)
        }
        .padding(.horizontal, PeekStrip.flare)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Self.shape.fill(Color.black))
        .clipShape(Self.shape)
        .overlay {
            Self.shape
                .strokeBorder(emphasized ? IslandChrome.accent : Color.clear, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .islandFlash(Self.shape, trigger: monitor.flashCount)
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
        return HStack(spacing: 0) {
            HStack(spacing: 2) {
                lockButton
                TaskLightStrip(lights: lights, limit: PeekStrip.lightLimit(count: lights.count))
                Spacer(minLength: 0)
            }
            .frame(width: PeekStrip.slotWidth - PeekStrip.flare)

            if presence.onNotchedScreen {
                Spacer(minLength: 0)
            } else {
                Text(IslandChrome.name)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
            }

            HStack(spacing: 0) {
                Spacer(minLength: 0)
                if let next, next.urgency(now: now).isPressing {
                    DeadlineBadge(item: next, now: now)
                }
            }
            .padding(.trailing, PeekStrip.trailingInset)
            .frame(width: PeekStrip.slotWidth - PeekStrip.flare)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Leftmost control, the strip's full height. Its slice never triggers the hover reveal.
    private var lockButton: some View {
        let locked = settings.isPeekLocked
        return Button {
            settings.isPeekLocked.toggle()
        } label: {
            Image(systemName: locked ? "lock.fill" : "lock.open")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(locked ? IslandChrome.caution : Color.white.opacity(0.4))
                .frame(width: PeekStrip.lockZoneWidth - PeekStrip.flare)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(locked ? "锁住了，鼠标经过不会展开 · 点一下解锁" : "点一下锁住，鼠标经过就不再展开")
        .accessibilityLabel(locked ? "解锁岛" : "锁住岛")
    }

    private var dropBinding: Binding<Bool> {
        Binding(
            get: { presence.isDropTargeted },
            set: { presence.isDropTargeted = $0 }
        )
    }
}
