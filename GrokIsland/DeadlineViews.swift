import SwiftUI

extension DeadlineUrgency {
    var color: Color {
        switch self {
        case .overdue: IslandChrome.alertRed
        case .critical: IslandChrome.ember
        case .soon: IslandChrome.amber
        case .relaxed: IslandChrome.electricGreen
        case .done: Color.secondary
        }
    }
}

/// Today 23:59, or tomorrow 23:59 in the last minute of the day.
private func defaultDeadlineDue(now: Date = Date()) -> Date {
    let calendar = Calendar.current
    let tonight = calendar.date(bySettingHour: 23, minute: 59, second: 0, of: now) ?? now
    if tonight > now { return tonight }
    return calendar.date(byAdding: .day, value: 1, to: tonight) ?? tonight
}

/// Segmented neon gauge. `value` 1 = full energy, 0 = drained.
struct EnergyGauge: View {
    var value: Double
    var color: Color
    var segments: Int = 12

    var body: some View {
        GeometryReader { geo in
            let count = max(segments, 1)
            let gap: CGFloat = 2
            let width = max((geo.size.width - gap * CGFloat(count - 1)) / CGFloat(count), 1)
            let lit = Int((min(max(value, 0), 1) * Double(count)).rounded(.up))
            let track = value <= 0 ? color.opacity(0.28) : Color.white.opacity(0.1)
            HStack(spacing: gap) {
                ForEach(0..<count, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(index < lit ? color : track)
                        .frame(width: width)
                        .shadow(color: index < lit ? color.opacity(0.7) : Color.clear, radius: 2)
                }
            }
        }
        .accessibilityLabel("剩余能量 \(Int(value * 100))%")
    }
}

/// Small `⚡︎5小时` badge for the collapsed peek strip.
struct DeadlineBadge: View {
    let item: DeadlineItem
    let now: Date

    var body: some View {
        let urgency = item.urgency(now: now)
        HStack(spacing: 2) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 8, weight: .bold))
            Text(DeadlineFormat.short(item.remaining(now: now)))
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
        }
        .foregroundStyle(urgency.color)
        .help("DDL：\(item.title) · \(DeadlineFormat.countdown(item.remaining(now: now)))")
    }
}

/// DDL energy strip above the function strips. Collapsed it shows the next deadline
/// draining; hovering (or typing into it) expands the list and the add / edit field.
struct DeadlineEnergyBar: View {
    @ObservedObject var store: DeadlineStore
    var onError: (Error) -> Void = { _ in }

    @State private var hovering = false
    @State private var draft = ""
    @State private var draftDue = defaultDeadlineDue()
    @State private var editingID: UUID?
    @State private var parsedHint: String?
    @FocusState private var fieldFocused: Bool

    private static let visibleRows = 4

    private var expanded: Bool {
        hovering || fieldFocused || !draft.isEmpty || editingID != nil
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            card(now: context.date)
        }
        .onHover { inside in
            withAnimation(IslandChrome.expandSpring) { hovering = inside }
        }
        .onChange(of: draft) { applyParse() }
        .animation(IslandChrome.expandSpring, value: expanded)
    }

    private func card(now: Date) -> some View {
        let summary = store.summary(now: now)
        let accent = summary.next?.urgency(now: now).color ?? IslandChrome.neonCyan
        return VStack(alignment: .leading, spacing: 6) {
            summaryRow(summary, now: now)
            if expanded {
                expandedContent(now: now)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(expanded ? 0.32 : 0.2))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(accent.opacity(expanded ? 0.75 : 0.4), lineWidth: 1)
                .shadow(color: accent.opacity(expanded ? 0.5 : 0.2), radius: 3)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func summaryRow(_ summary: DeadlineSummary, now: Date) -> some View {
        let urgency = summary.next?.urgency(now: now) ?? .relaxed
        return HStack(spacing: 6) {
            Image(systemName: summary.next == nil ? "bolt" : "bolt.fill")
                .font(.caption)
                .foregroundStyle(summary.next == nil ? Color.secondary : urgency.color)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text("DDL")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(IslandChrome.neonCyan)
                    if let next = summary.next {
                        Text(next.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(DeadlineFormat.countdown(next.remaining(now: now)))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(urgency.color)
                            .lineLimit(1)
                    } else {
                        Text("能量满格 · 悬停添加日程")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                }
                EnergyGauge(
                    value: summary.next?.energy(now: now) ?? 1,
                    color: summary.next == nil ? IslandChrome.neonCyan.opacity(0.5) : urgency.color
                )
                .frame(height: 5)
            }
            if summary.pendingCount > 1 {
                Text("\(summary.pendingCount)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                    .help("共 \(summary.pendingCount) 条未完成 · 7 天内 \(summary.withinWeekCount) 条 · 超时 \(summary.overdueCount) 条")
            }
        }
    }

    @ViewBuilder
    private func expandedContent(now: Date) -> some View {
        let pending = store.pending
        VStack(alignment: .leading, spacing: 3) {
            if pending.isEmpty {
                Text("还没有 DDL。输入「周五 18:00 交实验报告」试试。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
                    Text("另有 \(pending.count - Self.visibleRows) 条稍后的 DDL")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            composer
            if store.items.contains(where: \.isDone) {
                Button("清除已完成的 DDL") { _ = store.clearDone() }
                    .buttonStyle(.borderless)
                    .font(.caption2)
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                TextField(editingID == nil ? "添加日程：周五 18:00 交实验报告" : "修改内容", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .focused($fieldFocused)
                    .onSubmit(commit)
                Button(editingID == nil ? "添加" : "保存", action: commit)
                    .controlSize(.small)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack(spacing: 4) {
                DatePicker("", selection: $draftDue, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .datePickerStyle(.field)
                    .controlSize(.small)
                if let parsedHint {
                    Text("识别：\(parsedHint)")
                        .font(.caption2)
                        .foregroundStyle(IslandChrome.neonCyan)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if editingID != nil || !draft.isEmpty {
                    Button("取消", action: resetDraft)
                        .buttonStyle(.borderless)
                        .font(.caption2)
                }
            }
        }
        .padding(.top, 2)
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

    var body: some View {
        let urgency = item.urgency(now: now)
        HStack(spacing: 5) {
            Button(action: onDone) {
                Image(systemName: "circle")
                    .font(.caption)
                    .foregroundStyle(urgency.color)
            }
            .buttonStyle(.borderless)
            .help("标记完成")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(item.title)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(DeadlineFormat.dueLabel(item.due, now: now))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(urgency == .overdue ? urgency.color : Color.secondary)
                }
                EnergyGauge(value: item.energy(now: now), color: urgency.color, segments: 16)
                    .frame(height: 3)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onEdit)
            .help("\(DeadlineFormat.countdown(item.remaining(now: now))) · 点击修改")

            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .help("删除这条 DDL")
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isEditing ? IslandChrome.neonCyan.opacity(0.14) : Color.white.opacity(0.03))
        }
    }
}
