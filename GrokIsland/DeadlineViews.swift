import AppKit
import SwiftUI

extension DeadlineUrgency {
    var color: Color {
        switch self {
        case .overdue: IslandChrome.danger
        case .critical: IslandChrome.ember
        case .soon: IslandChrome.caution
        case .relaxed: IslandChrome.positive
        case .done: Color.secondary
        }
    }

    /// Only overdue and critical deadlines get color; the rest stay grey.
    var needsAttention: Bool {
        switch self {
        case .overdue, .critical: true
        default: false
        }
    }

    var labelColor: Color { needsAttention ? color : Color.secondary }
}

/// Today 23:59, or tomorrow 23:59 in the last minute of the day.
private func defaultDeadlineDue(now: Date = Date()) -> Date {
    let calendar = Calendar.current
    let tonight = calendar.date(bySettingHour: 23, minute: 59, second: 0, of: now) ?? now
    if tonight > now { return tonight }
    return calendar.date(byAdding: .day, value: 1, to: tonight) ?? tonight
}

extension EnergyLoad {
    var color: Color {
        switch self {
        case .calm: IslandChrome.positive
        case .busy: IslandChrome.ember
        case .overloaded: IslandChrome.danger
        }
    }
}

/// One energy bar. Each pending task is a single cell, and every cell shares the
/// color for that count: green up to 3, orange for 4–6, red from 7.
struct TaskEnergyBar: View {
    let items: [DeadlineItem]
    let now: Date
    var highlightedID: UUID?

    private var load: EnergyLoad { EnergyLoad.level(for: items.count) }

    var body: some View {
        let gap: CGFloat = 2
        let color = load.color
        Group {
            if items.isEmpty {
                Capsule()
                    .fill(Color.white.opacity(0.08))
            } else {
                HStack(spacing: gap) {
                    ForEach(items) { item in
                        Capsule()
                            .fill(highlightedID == item.id ? Color.white.opacity(0.9) : color.opacity(0.85))
                            .frame(maxWidth: .infinity)
                            .help("\(item.title) · \(DeadlineFormat.countdown(item.remaining(now: now)))")
                    }
                }
            }
        }
        .accessibilityLabel(items.isEmpty ? "没有任务" : "\(items.count) 个任务，\(load.label)")
    }
}

/// Small `• 5小时` badge for the collapsed peek strip.
struct DeadlineBadge: View {
    let item: DeadlineItem
    let now: Date

    var body: some View {
        let urgency = item.urgency(now: now)
        HStack(spacing: 4) {
            Circle()
                .fill(urgency.color)
                .frame(width: 5, height: 5)
            Text(DeadlineFormat.short(item.remaining(now: now)))
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
        }
        .help("DDL：\(item.title) · \(DeadlineFormat.countdown(item.remaining(now: now)))")
    }
}

/// One DDL energy strip above the function strips. Each task is one cell in that bar.
/// Hovering (or typing into it) expands the list and the add / edit field.
///
/// The time control is the last row. A click or drag that slips a few points below
/// it used to leave this card's hover region, collapse the editor, and land on the
/// Ask Grok bar underneath. `DeadlineTimeHit` keeps that strip with the time control.
struct DeadlineEnergyBar: View {
    @ObservedObject var store: DeadlineStore
    var onError: (Error) -> Void = { _ in }

    @State private var cardHover = false
    @State private var pointerOwnsPanel = false
    @State private var timeTracking = false
    @State private var hitSession = DeadlineHitSession()
    @State private var draft = ""
    @State private var draftDue = defaultDeadlineDue()
    @State private var editingID: UUID?
    @State private var parsedHint: String?
    @FocusState private var fieldFocused: Bool

    private static let visibleRows = 4

    private var expanded: Bool {
        DeadlineTimeHit.staysOpen(
            cardHover: cardHover,
            pointerOwnsPanel: pointerOwnsPanel,
            tracking: timeTracking,
            fieldFocused: fieldFocused,
            hasDraft: !draft.isEmpty,
            isEditing: editingID != nil
        )
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            card(now: context.date)
        }
        .background(DeadlinePanelProbe(session: hitSession).allowsHitTesting(false))
        .onHover { inside in
            let interaction = hitSession.evaluate(phase: .hover, point: NSEvent.mouseLocation)
            hitSession.tracking = interaction.tracking
            hitSession.pointerOwnsPanel = interaction.pointerOwnsPanel
            withAnimation(IslandChrome.expandSpring) {
                cardHover = inside
                pointerOwnsPanel = interaction.pointerOwnsPanel
                timeTracking = interaction.tracking
            }
        }
        .onChange(of: draft) { applyParse() }
        .animation(IslandChrome.expandSpring, value: expanded)
    }

    private func card(now: Date) -> some View {
        let summary = store.summary(now: now)
        let shape = RoundedRectangle(cornerRadius: IslandChrome.platterRadius, style: .continuous)
        return VStack(alignment: .leading, spacing: 8) {
            summaryRow(summary, now: now)
            if expanded {
                expandedContent(now: now)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background {
            shape.fill(expanded ? IslandChrome.surfaceRaised : IslandChrome.surface)
        }
        .overlay {
            shape
                .strokeBorder(IslandChrome.hairline, lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .contentShape(shape)
    }

    private func summaryRow(_ summary: DeadlineSummary, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("DDL")
                    .islandSectionLabel()
                if let next = summary.next {
                    Text(next.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(DeadlineFormat.countdown(next.remaining(now: now)))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(next.urgency(now: now).labelColor)
                        .lineLimit(1)
                    if summary.pendingCount > 1 {
                        Text("共 \(summary.pendingCount)")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .help("还有 \(summary.pendingCount) 条没做完 · 7 天内 \(summary.withinWeekCount) 条 · 已经过了 \(summary.overdueCount) 条")
                    }
                } else {
                    Text("还没有 DDL · 移过来加一条")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
            }
            TaskEnergyBar(items: store.pending, now: now, highlightedID: editingID)
                .frame(height: 3)
        }
    }

    @ViewBuilder
    private func expandedContent(now: Date) -> some View {
        let pending = store.pending
        VStack(alignment: .leading, spacing: 2) {
            if pending.isEmpty {
                Text("像「周五 18:00 交实验报告」这样写就行，时间会自动填好。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(pending.prefix(Self.visibleRows)) { item in
                    DeadlineRow(
                        item: item,
                        now: now,
                        isEditing: editingID == item.id,
                        onEdit: { beginEdit(item) },
                        onDone: { store.toggleDone(id: item.id) },
                        onDelete: { delete(item) }
                    )
                }
                if pending.count > Self.visibleRows {
                    Text("还有 \(pending.count - Self.visibleRows) 条在后面")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 4)
                }
            }
            composer
            if store.items.contains(where: \.isDone) {
                HStack {
                    Spacer(minLength: 0)
                    Button("清掉已完成") { _ = store.clearDone() }
                        .buttonStyle(.islandPill(.quiet, compact: true))
                }
                .padding(.top, 2)
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField(editingID == nil ? "周五 18:00 交实验报告" : "改成什么", text: $draft)
                    .focused($fieldFocused)
                    .onSubmit(commit)
                    .islandField()
                Button(editingID == nil ? "添加" : "保存", action: commit)
                    .buttonStyle(.islandPill(.prominent, compact: true))
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack(spacing: 4) {
                DatePicker("", selection: $draftDue, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .datePickerStyle(.field)
                    .controlSize(.small)
                    .background(
                        DeadlineTimeAnchor(
                            session: hitSession,
                            pointerOwnsPanel: $pointerOwnsPanel,
                            timeTracking: $timeTracking
                        )
                        .allowsHitTesting(false)
                    )
                if let parsedHint {
                    Text(parsedHint)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help("从你写的字里认出来的时间")
                }
                Spacer(minLength: 0)
                if editingID != nil || !draft.isEmpty {
                    Button("取消", action: resetDraft)
                        .buttonStyle(.islandPill(.quiet, compact: true))
                }
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Actions

    private func applyParse() {
        let now = Date()
        let parsed = DeadlineParser.parse(draft, now: now)
        if let due = parsed.due {
            draftDue = due
            parsedHint = DeadlineFormat.dueLabel(due, now: now)
        } else {
            parsedHint = nil
        }
    }

    private func commit() {
        let raw = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        let parsed = DeadlineParser.parse(raw, now: Date())
        let title = parsed.title.isEmpty ? raw : parsed.title
        do {
            if let editingID {
                try store.update(id: editingID, title: title, due: draftDue)
            } else {
                try store.add(title: title, due: draftDue)
            }
            resetDraft()
        } catch {
            onError(error)
        }
    }

    private func beginEdit(_ item: DeadlineItem) {
        editingID = item.id
        draft = item.title
        draftDue = item.due
        fieldFocused = true
    }

    private func delete(_ item: DeadlineItem) {
        store.delete(id: item.id)
        if editingID == item.id { resetDraft() }
    }

    private func resetDraft() {
        draft = ""
        editingID = nil
        parsedHint = nil
        draftDue = defaultDeadlineDue()
        fieldFocused = false
    }
}

private struct DeadlineRow: View {
    let item: DeadlineItem
    let now: Date
    let isEditing: Bool
    let onEdit: () -> Void
    let onDone: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        let urgency = item.urgency(now: now)
        HStack(spacing: 6) {
            Button(action: onDone) {
                Circle()
                    .strokeBorder(urgency.needsAttention ? urgency.color : Color.white.opacity(0.35), lineWidth: 1.2)
                    .frame(width: 12, height: 12)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.islandPress)
            .help("做完了就点一下")

            HStack(spacing: 4) {
                Text(item.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(DeadlineFormat.dueLabel(item.due, now: now))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(urgency.labelColor)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onEdit)
            .help("\(DeadlineFormat.countdown(item.remaining(now: now))) · 点一下修改")

            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(IslandIconButtonStyle(size: 18))
            .opacity(hovering || isEditing ? 1 : 0)
            .help("删掉这条 DDL")
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 3)
        .background {
            RoundedRectangle(cornerRadius: IslandChrome.fieldRadius, style: .continuous)
                .fill(isEditing ? IslandChrome.surfaceRaised : (hovering ? IslandChrome.surface : Color.clear))
        }
        .animation(IslandChrome.hoverFade, value: hovering)
        .onHover { hovering = $0 }
    }
}

/// Screen rects for the DDL card and its time field, plus the mouse monitor that
/// keeps a downward slip from dismissing the editor or hitting Ask Grok.
final class DeadlineHitSession {
    var tracking = false
    var pointerOwnsPanel = false
    var panelScreenRect: CGRect = .zero
    var timeScreenRect: CGRect = .zero
    weak var panelView: NSView?
    weak var anchor: DeadlineTimeAnchorView?
    var onInteraction: ((DeadlineTimeInteraction) -> Void)?

    private var monitor: Any?
    private var timer: Timer?
    private var delivering = false
    private weak var datePicker: NSDatePicker?

    func evaluate(phase: DeadlinePointerPhase, point: CGPoint) -> DeadlineTimeInteraction {
        refreshFrames()
        return DeadlineTimeHit.decide(
            phase: phase,
            point: point,
            panel: panelScreenRect,
            timeField: timeScreenRect,
            tracking: tracking,
            attachedPopup: hasAttachedPopup()
        )
    }

    func apply(_ interaction: DeadlineTimeInteraction) {
        let changed = tracking != interaction.tracking || pointerOwnsPanel != interaction.pointerOwnsPanel
        tracking = interaction.tracking
        pointerOwnsPanel = interaction.pointerOwnsPanel
        if changed { onInteraction?(interaction) }
    }

    func start(anchor: DeadlineTimeAnchorView) {
        self.anchor = anchor
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            self?.handle(event) ?? event
        }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func anchorWentAway(_ anchor: DeadlineTimeAnchorView) {
        guard self.anchor === anchor else { return }
        self.anchor = nil
        timeScreenRect = .zero
        datePicker = nil
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard !delivering else { return }
        var interaction = evaluate(phase: .hover, point: NSEvent.mouseLocation)
        // A missed mouse-up (released outside the app) must not pin the editor open.
        if interaction.tracking, NSEvent.pressedMouseButtons & 1 == 0 {
            interaction.tracking = false
        }
        apply(interaction)
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard !delivering else { return event }
        let phase: DeadlinePointerPhase
        switch event.type {
        case .leftMouseDown: phase = .mouseDown
        case .leftMouseDragged: phase = .mouseDragged
        case .leftMouseUp: phase = .mouseUp
        default: return event
        }
        let inOurWindow = event.window != nil && event.window === panelView?.window
        let popup = hasAttachedPopup()
        guard inOurWindow || popup else { return event }

        var interaction = evaluate(phase: phase, point: screenPoint(of: event))
        if !inOurWindow || popup {
            interaction.absorbPointer = false
            if popup { interaction.pointerOwnsPanel = true }
        }
        apply(interaction)
        guard interaction.absorbPointer else { return event }

        delivering = true
        retargetMouseDown(event)
        delivering = false
        if NSEvent.pressedMouseButtons & 1 == 0 {
            apply(evaluate(phase: .mouseUp, point: NSEvent.mouseLocation))
        }
        return nil
    }

    /// The calendar editor is a child window. Crossing into it is not leaving the DDL card.
    private func hasAttachedPopup() -> Bool {
        guard let window = panelView?.window else { return false }
        return window.childWindows?.contains(where: \.isVisible) == true
    }

    private func refreshFrames() {
        if let panelView, let rect = Self.screenRect(of: panelView) {
            panelScreenRect = rect
        }
        let source = resolveDatePicker() ?? anchor
        if let source, let rect = Self.screenRect(of: source) {
            timeScreenRect = rect
        }
    }

    private func resolveDatePicker() -> NSDatePicker? {
        if let datePicker, datePicker.window != nil { return datePicker }
        guard let anchor else { return nil }
        let picker = anchor.findDatePicker()
        datePicker = picker
        return picker
    }

    /// Move a slop click onto the time field so the picker, not the bar below, receives it.
    private func retargetMouseDown(_ event: NSEvent) {
        guard let picker = resolveDatePicker(), let window = picker.window else { return }
        let local = picker.convert(event.locationInWindow, from: nil)
        let x = min(max(local.x, picker.bounds.minX + 2), picker.bounds.maxX - 2)
        let inside = picker.convert(NSPoint(x: x, y: picker.bounds.midY), to: nil)
        guard let retargeted = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: inside,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: event.eventNumber,
            clickCount: event.clickCount,
            pressure: event.pressure
        ) else { return }
        picker.mouseDown(with: retargeted)
    }

    private func screenPoint(of event: NSEvent) -> CGPoint {
        if let window = event.window {
            return window.convertToScreen(NSRect(origin: event.locationInWindow, size: .zero)).origin
        }
        return NSEvent.mouseLocation
    }

    fileprivate static func screenRect(of view: NSView) -> CGRect? {
        guard let window = view.window, view.bounds.width > 1, view.bounds.height > 1 else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

private struct DeadlinePanelProbe: NSViewRepresentable {
    var session: DeadlineHitSession

    func makeNSView(context: Context) -> DeadlinePanelProbeView {
        let view = DeadlinePanelProbeView()
        view.session = session
        return view
    }

    func updateNSView(_ view: DeadlinePanelProbeView, context: Context) {
        view.session = session
        view.publish()
    }
}

private final class DeadlinePanelProbeView: NSView {
    var session: DeadlineHitSession?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        publish()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            if session?.panelView === self { session?.panelView = nil }
        } else {
            session?.panelView = self
            publish()
        }
    }

    func publish() {
        guard let session, let rect = DeadlineHitSession.screenRect(of: self) else { return }
        session.panelView = self
        session.panelScreenRect = rect
    }
}

private struct DeadlineTimeAnchor: NSViewRepresentable {
    var session: DeadlineHitSession
    @Binding var pointerOwnsPanel: Bool
    @Binding var timeTracking: Bool

    func makeNSView(context: Context) -> DeadlineTimeAnchorView {
        let view = DeadlineTimeAnchorView()
        view.session = session
        return view
    }

    func updateNSView(_ view: DeadlineTimeAnchorView, context: Context) {
        view.session = session
        let owns = $pointerOwnsPanel
        let tracking = $timeTracking
        session.onInteraction = { interaction in
            if owns.wrappedValue != interaction.pointerOwnsPanel {
                owns.wrappedValue = interaction.pointerOwnsPanel
            }
            if tracking.wrappedValue != interaction.tracking {
                tracking.wrappedValue = interaction.tracking
            }
        }
        session.start(anchor: view)
        session.anchor = view
    }

    static func dismantleNSView(_ nsView: DeadlineTimeAnchorView, coordinator: ()) {
        nsView.session?.anchorWentAway(nsView)
    }
}

final class DeadlineTimeAnchorView: NSView {
    var session: DeadlineHitSession?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        guard let session, let rect = DeadlineHitSession.screenRect(of: findDatePicker() ?? self) else { return }
        session.timeScreenRect = rect
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let session, window != nil {
            session.start(anchor: self)
        } else if let session {
            session.anchorWentAway(self)
        }
    }

    func findDatePicker() -> NSDatePicker? {
        guard let root = window?.contentView else { return nil }
        return Self.firstDatePicker(in: root, depth: 40)
    }

    private static func firstDatePicker(in view: NSView, depth: Int) -> NSDatePicker? {
        if let picker = view as? NSDatePicker { return picker }
        guard depth > 0 else { return nil }
        for subview in view.subviews {
            if let picker = firstDatePicker(in: subview, depth: depth - 1) { return picker }
        }
        return nil
    }
}
