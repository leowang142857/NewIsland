import AppKit
import SwiftUI

/// Status dot: grey when idle, breathing green while agents / PRs / Grok runs are in flight.
struct ActivityLight: View {
    var busy: Bool
    var warning: Bool = false
    var size: CGFloat = 7

    private var color: Color {
        if warning { return .orange }
        return busy ? IslandChrome.electricGreen : Color.secondary.opacity(0.7)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !busy)) { context in
            let wave = busy ? (sin(context.date.timeIntervalSinceReferenceDate * .pi / 0.8) + 1) / 2 : 1
            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .scaleEffect(busy ? 0.8 + 0.35 * wave : 1)
                .opacity(busy ? 0.55 + 0.45 * wave : 1)
                .shadow(color: color.opacity(busy ? 0.9 * wave : 0), radius: 4)
        }
        .frame(width: size * 1.4, height: size * 1.4)
        .accessibilityLabel(busy ? "有任务在运行" : "空闲")
    }
}

extension TaskLightState {
    var color: Color {
        switch self {
        case .running, .succeeded: IslandChrome.electricGreen
        case .queued, .idle: IslandChrome.neonCyan
        case .waiting: IslandChrome.amber
        case .failed: IslandChrome.alertRed
        case .cancelled: Color.secondary
        }
    }
}

/// One task's lamp: breathes while queued / running, solid once it has a result.
struct TaskLightDot: View {
    var state: TaskLightState
    var size: CGFloat = 7

    var body: some View {
        let color = state.color
        let animated = state.isAnimated
        let period = state == .running ? 0.8 : 1.4
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animated)) { context in
            let wave = animated ? (sin(context.date.timeIntervalSinceReferenceDate * .pi / period) + 1) / 2 : 1
            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .scaleEffect(animated ? 0.8 + 0.35 * wave : 1)
                .opacity(animated ? 0.55 + 0.45 * wave : 1)
                .shadow(color: color.opacity(animated ? 0.9 * wave : 0.55), radius: animated ? 4 : 2)
        }
        .frame(width: size * 1.4, height: size * 1.4)
        .accessibilityLabel(state.label)
    }
}

/// Row of per-task dots for the collapsed peek strip (grey dot when idle).
struct TaskLightStrip: View {
    let lights: [TaskLight]
    var limit = 5
    var size: CGFloat = 6

    var body: some View {
        HStack(spacing: 2) {
            if lights.isEmpty {
                ActivityLight(busy: false, size: size)
            } else {
                ForEach(lights.prefix(limit)) { light in
                    TaskLightDot(state: light.state, size: size)
                }
                if lights.count > limit {
                    Text("+\(lights.count - limit)")
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .help(lights.isEmpty ? "空闲" : lights.map { "\($0.kind.label) · \($0.state.label) · \($0.title)" }.joined(separator: "\n"))
    }
}

/// Expanded status layer: one chip per run / Cloud Agent / PR. Tap to open it.
struct TaskLightRail: View {
    let lights: [TaskLight]
    let onSelect: (TaskLight) -> Void

    var body: some View {
        if lights.isEmpty {
            HStack(spacing: 5) {
                ActivityLight(busy: false, size: 6)
                Text("空闲 · 没有在跑的任务")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .frame(height: 22)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(lights) { light in
                        TaskLightChip(light: light) { onSelect(light) }
                    }
                }
                .padding(.vertical, 1)
            }
            .frame(height: 24)
        }
    }
}

private struct TaskLightChip: View {
    let light: TaskLight
    let action: () -> Void

    var body: some View {
        let tint = light.state.color
        Button(action: action) {
            HStack(spacing: 4) {
                TaskLightDot(state: light.state, size: 6)
                Text(light.kind.label)
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(tint)
                Text(light.title)
                    .font(.caption2)
                    .lineLimit(1)
                    .frame(maxWidth: 96, alignment: .leading)
                if let progress = light.progress {
                    Text("\(Int(progress * 100))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background {
                Capsule().fill(tint.opacity(0.12))
            }
            .overlay {
                Capsule().strokeBorder(tint.opacity(0.5), lineWidth: 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("\(light.kind.label) · \(light.state.label) · \(light.title)")
    }
}

/// Two quick neon blinks on the island edge whenever `trigger` changes.
private struct IslandFlash<S: InsettableShape>: ViewModifier {
    let shape: S
    let trigger: Int

    @State private var glow: Double = 0

    func body(content: Content) -> some View {
        content
            .overlay {
                shape
                    .strokeBorder(IslandChrome.electricGreen, lineWidth: 2)
                    .shadow(color: IslandChrome.electricGreen.opacity(0.9), radius: 8)
                    .opacity(glow)
                    .allowsHitTesting(false)
            }
            .onChange(of: trigger) {
                Task { @MainActor in
                    for value in [1.0, 0.2, 1.0, 0.0] {
                        withAnimation(.easeInOut(duration: 0.18)) { glow = value }
                        try? await Task.sleep(for: .milliseconds(220))
                    }
                }
            }
    }
}

extension View {
    func islandFlash<S: InsettableShape>(_ shape: S, trigger: Int) -> some View {
        modifier(IslandFlash(shape: shape, trigger: trigger))
    }
}

/// Running Cloud Agents and open PRs, each row opens its page.
struct ActivityListView: View {
    @ObservedObject var monitor: CloudActivityMonitor
    let openSettings: () -> Void

    var body: some View {
        let snapshot = monitor.snapshot
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let updated = snapshot.updatedAt {
                    Text("更新于 \(updated.formatted(date: .omitted, time: .standard))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await monitor.refresh() }
                } label: {
                    if monitor.isRefreshing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .help("立即刷新")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    section(title: "Cloud Agent 运行中", count: snapshot.agents.count) {
                        if snapshot.agents.isEmpty {
                            placeholder(snapshot.agentNote ?? "没有在跑的 Agent")
                        }
                        ForEach(snapshot.agents) { agent in
                            row(link: agent.url) {
                                ActivityLight(busy: true, size: 6)
                                Text(agent.displayName)
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                        }
                        if snapshot.agentNote != nil, !snapshot.agents.isEmpty {
                            placeholder(snapshot.agentNote ?? "")
                        }
                        if snapshot.agentNote == "未设置 Cursor API key" {
                            Button("去设置", action: openSettings)
                                .buttonStyle(.borderless)
                                .font(.caption)
                        }
                    }

                    section(title: "PR", count: snapshot.pullRequests.count) {
                        if snapshot.pullRequests.isEmpty {
                            placeholder(snapshot.prNote ?? "没有待合并的 PR")
                        }
                        ForEach(snapshot.pullRequests) { pr in
                            row(link: pr.url) {
                                checkBadge(pr.checks)
                                Text("#\(pr.number) \(pr.title)")
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                        }
                        if !snapshot.stalePullRequests.isEmpty {
                            placeholder("另有 \(snapshot.stalePullRequests.count) 个 PR 已并入 main、还没关闭，不计入。")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { monitor.refreshSoon() }
    }

    private func section<Content: View>(
        title: String,
        count: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(count > 0 ? "\(title) · \(count)" : title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func row<Label: View>(link: String?, @ViewBuilder label: () -> Label) -> some View {
        Button {
            if let link, let url = URL(string: link) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 6) {
                label()
                Spacer(minLength: 0)
                if link != nil {
                    Image(systemName: "arrow.up.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(link == nil)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func checkBadge(_ state: CheckState) -> some View {
        switch state {
        case .running:
            ActivityLight(busy: true, size: 6)
        case .passed:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(IslandChrome.electricGreen)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .none:
            Image(systemName: "circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
