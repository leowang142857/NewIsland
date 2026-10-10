import AppKit
import SwiftUI

/// Status dot: grey when idle, slowly breathing green while agents / PRs / Grok runs are in flight.
struct ActivityLight: View {
    var busy: Bool
    var warning: Bool = false
    var size: CGFloat = 7

    private var color: Color {
        if warning { return IslandChrome.ember }
        return busy ? IslandChrome.positive : Color.white.opacity(0.28)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !busy)) { context in
            let wave = busy ? (sin(context.date.timeIntervalSinceReferenceDate * .pi / 1.2) + 1) / 2 : 1
            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .opacity(busy ? 0.45 + 0.55 * wave : 1)
        }
        .frame(width: size * 1.4, height: size * 1.4)
        .accessibilityLabel(busy ? "有任务在运行" : "空闲")
    }
}

extension TaskLightState {
    var color: Color {
        switch self {
        case .running, .succeeded: IslandChrome.positive
        case .queued, .idle: Color.white.opacity(0.45)
        case .waiting: IslandChrome.caution
        case .failed: IslandChrome.danger
        case .cancelled: Color.white.opacity(0.25)
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
        let period = state == .running ? 1.2 : 2.0
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animated)) { context in
            let wave = animated ? (sin(context.date.timeIntervalSinceReferenceDate * .pi / period) + 1) / 2 : 1
            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .opacity(animated ? 0.45 + 0.55 * wave : 1)
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

/// The header's status lights: one capsule per run / Cloud Agent / PR, like a row of Live
/// Activities. Tap to open it. Idle, a quiet line of text; the name beside it already has the dot.
struct TaskLightRail: View {
    let lights: [TaskLight]
    let onSelect: (TaskLight) -> Void

    private static let height: CGFloat = 24

    var body: some View {
        if lights.isEmpty {
            Text("现在没有任务在跑")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: Self.height, alignment: .leading)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(lights) { light in
                        TaskLightChip(light: light, height: Self.height) { onSelect(light) }
                    }
                }
            }
            .frame(height: Self.height)
        }
    }
}

private struct TaskLightChip: View {
    let light: TaskLight
    let height: CGFloat
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        let shape = Capsule(style: .continuous)
        Button(action: action) {
            HStack(spacing: 5) {
                TaskLightDot(state: light.state, size: 6)
                Text(light.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .frame(maxWidth: 112, alignment: .leading)
                if let progress = light.progress {
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 10)
            .frame(height: height)
            .background { shape.fill(hovering ? IslandChrome.surfaceRaised : IslandChrome.surface) }
            .overlay {
                shape
                    .strokeBorder(IslandChrome.hairline, lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
            .contentShape(shape)
        }
        .buttonStyle(.islandPress)
        .onHover { hovering = $0 }
        .animation(IslandChrome.hoverFade, value: hovering)
        .help("\(light.kind.label) · \(light.state.label) · \(light.title)")
    }
}

/// One soft pulse on the island edge whenever `trigger` changes.
private struct IslandFlash<S: InsettableShape>: ViewModifier {
    let shape: S
    let trigger: Int

    @State private var glow: Double = 0

    func body(content: Content) -> some View {
        content
            .overlay {
                shape
                    .strokeBorder(Color.white.opacity(0.55), lineWidth: 1)
                    .opacity(glow)
                    .allowsHitTesting(false)
            }
            .onChange(of: trigger) {
                Task { @MainActor in
                    withAnimation(.easeOut(duration: 0.15)) { glow = 1 }
                    try? await Task.sleep(for: .milliseconds(260))
                    withAnimation(.easeIn(duration: 0.6)) { glow = 0 }
                }
            }
    }
}

extension View {
    func islandFlash<S: InsettableShape>(_ shape: S, trigger: Int) -> some View {
        modifier(IslandFlash(shape: shape, trigger: trigger))
    }
}

/// Running Cloud Agents and open PRs as two grouped platters side by side, each scrolling on
/// its own; each row opens its page.
struct ActivityListView: View {
    @ObservedObject var monitor: CloudActivityMonitor
    let openSettings: () -> Void

    /// What `CloudActivityMonitor` reports when there is no Cursor key to ask with.
    private static let missingKeyNote = "未设置 Cursor API key"

    var body: some View {
        let snapshot = monitor.snapshot
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if let updated = snapshot.updatedAt {
                    Text("更新于 \(updated.formatted(date: .omitted, time: .standard))")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                Button {
                    Task { await monitor.refresh() }
                } label: {
                    if monitor.isRefreshing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.islandIcon())
                .help("现在刷新")
            }
            .padding(.leading, 4)

            HStack(alignment: .top, spacing: IslandChrome.columnGap) {
                ScrollView {
                    IslandGroup("在跑的 Cloud Agent") {
                        agentRows(snapshot)
                    } accessory: {
                        count(snapshot.agents.count)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                ScrollView {
                    IslandGroup("PR") {
                        pullRequestRows(snapshot)
                    } accessory: {
                        count(snapshot.pullRequests.count)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .onAppear { monitor.refreshSoon() }
    }

    @ViewBuilder
    private func agentRows(_ snapshot: CloudActivitySnapshot) -> some View {
        let missingKey = snapshot.agentNote == Self.missingKeyNote
        if snapshot.agents.isEmpty {
            placeholder(missingKey
                ? "还没填 Cursor 的 API key，填好就能看到在跑的 Agent。"
                : snapshot.agentNote ?? "现在没有在跑的 Agent")
        } else {
            ForEach(Array(snapshot.agents.enumerated()), id: \.element.id) { index, agent in
                if index > 0 { IslandHairline() }
                ActivityRow(link: agent.url) {
                    ActivityLight(busy: true, size: 6)
                    Text(agent.displayName)
                        .font(.system(size: 12))
                        .lineLimit(1)
                }
            }
            if let note = snapshot.agentNote {
                placeholder(note)
            }
        }
        if missingKey {
            Button("去设置", action: openSettings)
                .buttonStyle(.islandPill(compact: true))
        }
    }

    @ViewBuilder
    private func pullRequestRows(_ snapshot: CloudActivitySnapshot) -> some View {
        if snapshot.pullRequests.isEmpty {
            placeholder(snapshot.prNote ?? "没有等着合并的 PR")
        } else {
            ForEach(Array(snapshot.pullRequests.enumerated()), id: \.element.id) { index, pr in
                if index > 0 { IslandHairline() }
                ActivityRow(link: pr.url) {
                    checkBadge(pr.checks)
                    Text("#\(pr.number)")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(pr.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                }
            }
        }
        if !snapshot.stalePullRequests.isEmpty {
            placeholder("还有 \(snapshot.stalePullRequests.count) 个 PR 已经并进 main 但没关，没算在里面。")
        }
    }

    @ViewBuilder
    private func count(_ value: Int) -> some View {
        if value > 0 {
            Text("\(value)")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func checkBadge(_ state: CheckState) -> some View {
        switch state {
        case .running:
            ActivityLight(busy: true, size: 6)
                .help("CI 在跑")
        case .passed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(IslandChrome.positive)
                .help("CI 过了")
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(IslandChrome.ember)
                .help("CI 没过")
        case .none:
            Image(systemName: "circle")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .help("还没有 CI")
        }
    }
}

/// One line in an activity platter. The arrow brightens under the pointer.
private struct ActivityRow<Label: View>: View {
    let link: String?
    let label: Label

    @State private var hovering = false

    init(link: String?, @ViewBuilder label: () -> Label) {
        self.link = link
        self.label = label()
    }

    var body: some View {
        Button {
            if let link, let url = URL(string: link) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 6) {
                label
                Spacer(minLength: 4)
                if link != nil {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(hovering ? Color.secondary : Color.white.opacity(0.25))
                }
            }
            .frame(minHeight: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.islandPress)
        .onHover { hovering = $0 }
        .animation(IslandChrome.hoverFade, value: hovering)
        .disabled(link == nil)
        .help(link == nil ? "没有可以打开的页面" : "在浏览器里打开")
    }
}
