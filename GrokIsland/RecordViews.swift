import AppKit
import SwiftUI

/// Run journal on the island: filter, one-click clear, multi-select or per-row delete.
struct RunJournalList: View {
    @ObservedObject var engine: IslandEngine
    let onOpen: (UUID) -> Void

    private enum Filter: String, CaseIterable, Identifiable {
        case all
        case grok

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "全部"
            case .grok: "回答"
            }
        }
    }

    @State private var filter: Filter = .all
    @State private var selecting = false
    @State private var selection: Set<UUID> = []
    @State private var note: String?
    @Namespace private var filterThumb

    private var visibleRuns: [RunRecord] {
        switch filter {
        case .all: engine.runs
        case .grok: engine.runs.filter(\.isGrokAnswer)
        }
    }

    private var finishedCount: Int {
        engine.runs.filter { $0.phase.isTerminal }.count
    }

    private var allVisibleSelected: Bool {
        !visibleRuns.isEmpty && visibleRuns.allSatisfy { selection.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            toolbar
            if let note {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .transition(.opacity)
            }
            if visibleRuns.isEmpty {
                Text(filter == .grok ? "还没有 Grok 的回答。" : "还没有记录。跑过的任务都会留在这里。")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visibleRuns) { run in
                            RunRow(
                                run: run,
                                selecting: selecting,
                                selected: selection.contains(run.id),
                                onTap: { tap(run) },
                                onDelete: { delete([run.id]) }
                            )
                        }
                    }
                }
            }
        }
        .onChange(of: engine.runs.map(\.id)) {
            selection.formIntersection(Set(engine.runs.map(\.id)))
        }
    }

    /// The filter makes way for the selection actions, so either set fits one row on the narrowest island.
    private var toolbar: some View {
        HStack(spacing: 6) {
            if selecting {
                Button(allVisibleSelected ? "全不选" : "全选", action: toggleAll)
                    .buttonStyle(.islandPill(.quiet, compact: true))
                Spacer(minLength: 0)
                Button("删除 \(selection.count)", action: deleteSelection)
                    .buttonStyle(.islandPill(.destructive, compact: true))
                    .disabled(selection.isEmpty)
                Button("完成") {
                    selecting = false
                    selection = []
                }
                .buttonStyle(.islandPill(compact: true))
            } else {
                HStack(spacing: 0) {
                    ForEach(Filter.allCases) { option in
                        IslandSegment(
                            title: option.title,
                            selected: filter == option,
                            namespace: filterThumb
                        ) {
                            withAnimation(IslandChrome.selectSpring) { filter = option }
                        }
                    }
                }
                .frame(width: 104)
                .islandSegmentTrack()

                Spacer(minLength: 0)

                Button("清掉已完成", action: clearFinished)
                    .buttonStyle(.islandPill(.quiet, compact: true))
                    .disabled(finishedCount == 0)
                    .help("删掉做完、失败和取消的记录（\(finishedCount) 条）")
                Button("选择") { selecting = true }
                    .buttonStyle(.islandPill(.quiet, compact: true))
                    .disabled(engine.runs.isEmpty)
                    .help("选几条一起删")
            }
        }
        .frame(height: 28)
    }

    private func tap(_ run: RunRecord) {
        if selecting {
            if selection.contains(run.id) {
                selection.remove(run.id)
            } else {
                selection.insert(run.id)
            }
        } else {
            onOpen(run.id)
        }
    }

    private func toggleAll() {
        if allVisibleSelected {
            selection.subtract(visibleRuns.map(\.id))
        } else {
            selection.formUnion(visibleRuns.map(\.id))
        }
    }

    private func deleteSelection() {
        delete(selection)
        selection = []
        selecting = false
    }

    private func delete(_ ids: Set<UUID>) {
        let removed = engine.deleteRuns(ids: ids)
        show(removed > 0 ? "删掉了 \(removed) 条" : "没有能删的")
    }

    private func clearFinished() {
        let removed = engine.clearFinishedRuns()
        show("清掉了 \(removed) 条")
    }

    private func show(_ message: String) {
        withAnimation { note = message }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            if note == message {
                withAnimation { note = nil }
            }
        }
    }
}

private struct RunRow: View {
    let run: RunRecord
    let selecting: Bool
    let selected: Bool
    let onTap: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    private var tag: String {
        switch run.origin {
        case .quickAsk: "问答"
        case .quickAction: "快捷"
        case .splitTask: "拆分"
        case .splitSubtask: "子任务"
        case .module: run.executor == .local ? "本机" : "模块"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if selecting {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? IslandChrome.accent : Color.secondary)
            } else {
                TaskLightDot(state: TaskLightBoard.state(for: run.phase), size: 6)
                    .padding(.top, 3)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(run.moduleName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(tag)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 4)
                    Text(RunDetailView.stamp(run.createdAt))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if let question = run.question {
                    Text(question)
                        .font(.system(size: 11))
                        .lineLimit(1)
                }
                Text(run.message)
                    .font(.system(size: 11))
                    .foregroundStyle(run.phase == .failed ? IslandChrome.danger : Color.secondary)
                    .lineLimit(2)
                if run.phase == .running {
                    ProgressView(value: run.progress)
                        .controlSize(.mini)
                }
            }

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 10))
            }
            .buttonStyle(IslandIconButtonStyle(size: 20))
            .opacity(selecting ? 0 : (hovering ? 1 : 0))
            .disabled(selecting)
            .help(run.isActive ? "取消并删掉这条记录" : "删掉这条记录")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: IslandChrome.fieldRadius, style: .continuous)
                .fill(selected ? IslandChrome.accent.opacity(0.16) : (hovering ? IslandChrome.surface : Color.clear))
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hovering = $0 }
        .animation(IslandChrome.hoverFade, value: hovering)
        .help(selecting ? "点一下选中或取消" : "点开看详情")
        .contextMenu {
            Button("打开", action: onTap)
            if let answer = run.resultSummary {
                Button("拷贝回答") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(answer, forType: .string)
                }
            }
            Divider()
            Button("删掉", role: .destructive, action: onDelete)
        }
    }
}
