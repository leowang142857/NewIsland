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
            case .grok: "Grok 回答"
            }
        }
    }

    @State private var filter: Filter = .all
    @State private var selecting = false
    @State private var selection: Set<UUID> = []
    @State private var note: String?

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
        VStack(alignment: .leading, spacing: 5) {
            toolbar
            if let note {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            if visibleRuns.isEmpty {
                Text(filter == .grok ? "还没有 Grok 回答。" : "还没有运行记录。")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 4)
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

    private var toolbar: some View {
        HStack(spacing: 8) {
            Picker("", selection: $filter) {
                ForEach(Filter.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.mini)
            .frame(width: 124)

            Spacer(minLength: 0)

            if selecting {
                Button(allVisibleSelected ? "全不选" : "全选", action: toggleAll)
                Button("删除 \(selection.count)", action: deleteSelection)
                    .foregroundStyle(selection.isEmpty ? Color.secondary : IslandChrome.danger)
                    .disabled(selection.isEmpty)
                Button("完成") {
                    selecting = false
                    selection = []
                }
                .foregroundStyle(.primary)
            } else {
                Button("清理已完成", action: clearFinished)
                    .disabled(finishedCount == 0)
                    .help("删除所有已完成、失败、已取消的记录（\(finishedCount) 条）")
                Button("选择") { selecting = true }
                    .disabled(engine.runs.isEmpty)
                    .help("多选后批量删除")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .font(.system(size: 11))
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
        show(removed > 0 ? "已删除 \(removed) 条记录" : "没有可删除的记录")
    }

    private func clearFinished() {
        let removed = engine.clearFinishedRuns()
        show("已清理 \(removed) 条已完成记录")
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
        case .quickAction: "功能条"
        case .splitTask: "拆分"
        case .splitSubtask: "子任务"
        case .module: run.executor == .local ? "本地" : "模块"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if selecting {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
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
                    Text(run.createdAt.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
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
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(selecting ? 0 : (hovering ? 1 : 0))
            .disabled(selecting)
            .help(run.isActive ? "取消并删除这条记录" : "删除这条记录")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? IslandChrome.accent.opacity(0.14) : Color.white.opacity(hovering ? 0.05 : 0))
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hovering = $0 }
        .help(selecting ? "点选 / 取消选择" : "点开看完整结果")
        .contextMenu {
            Button("打开", action: onTap)
            if let answer = run.resultSummary {
                Button("拷贝结果") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(answer, forType: .string)
                }
            }
            Divider()
            Button("删除", role: .destructive, action: onDelete)
        }
    }
}
