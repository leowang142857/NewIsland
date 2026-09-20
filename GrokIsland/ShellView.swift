import SwiftUI
import UniformTypeIdentifiers

/// Minimal functional shell so the backend can be exercised.
/// TODO(frontend): Replace this entire view with the island UI the user will co-design.
struct ShellView: View {
    @ObservedObject var engine: IslandEngine

    @State private var draftName = ""
    @State private var draftPrompt = ""
    @State private var draftExecutor: ExecutorKind = .grokBot
    @State private var editingID: UUID?
    @State private var selectedModuleID: UUID?
    @State private var quickAsk = ""
    @State private var confirmOpenFiles = true
    @State private var confirmCommand = ""
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            moduleEditor
            moduleList
            Divider()
            inboxSection
            runRow
            if engine.pendingLocal != nil {
                localConfirm
            }
            Divider()
            quickAskRow
            runsSection
            if let error = engine.lastError, !error.isEmpty {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: dropTargeted ? 2 : 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onDrop(of: [UTType.fileURL, UTType.url, UTType.plainText], isTargeted: $dropTargeted) { providers in
            engine.ingestDropProviders(providers)
            return true
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("grok岛")
                    .font(.headline)
                Text("Functional shell — backend first")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(context.date, style: .time)
                    .font(.caption.monospacedDigit())
            }
            Text("天气 —")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Demo") {
                engine.loadDemoModules(overwrite: engine.modules.isEmpty)
            }
        }
    }

    private var moduleEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(editingID == nil ? "New module" : "Edit module")
                .font(.subheadline.weight(.semibold))
            TextField("Name（翻译 / 整理笔记 / 跑脚本）", text: $draftName)
            TextField("Prompt / config", text: $draftPrompt, axis: .vertical)
                .lineLimit(2...4)
            Picker("Executor", selection: $draftExecutor) {
                ForEach(ExecutorKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            HStack {
                Button(editingID == nil ? "Create module" : "Save module") {
                    saveDraft()
                }
                .keyboardShortcut(.defaultAction)
                if editingID != nil {
                    Button("Cancel edit") { resetDraft() }
                }
            }
        }
    }

    private var moduleList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Function modules")
                .font(.subheadline.weight(.semibold))
            if engine.modules.isEmpty {
                Text("创建你的第一个功能模块")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            } else {
                List(engine.modules, selection: $selectedModuleID) { module in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(module.displayName)
                            Text(module.executor.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !module.prompt.isEmpty {
                                Text(module.prompt)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer()
                        Button("Edit") { beginEdit(module) }
                            .buttonStyle(.borderless)
                        Button("Delete", role: .destructive) {
                            try? engine.deleteModule(id: module.id)
                            if selectedModuleID == module.id { selectedModuleID = nil }
                            if editingID == module.id { resetDraft() }
                        }
                        .buttonStyle(.borderless)
                    }
                    .tag(Optional(module.id))
                }
                .frame(minHeight: 120, maxHeight: 160)
            }
        }
    }

    private var inboxSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Dropped resources")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if !engine.inboxItems.isEmpty {
                    Button("Clear") { engine.clearInbox() }
                }
            }
            if engine.inboxItems.isEmpty {
                Text(dropTargeted ? "Release to add…" : "Drop files, folders, or URLs here")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            } else {
                ForEach(engine.inboxItems) { item in
                    HStack {
                        Image(systemName: item.kind.symbolName)
                        Text(item.name)
                            .lineLimit(1)
                        Text(item.kind.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("×") { engine.removeInboxItem(id: item.id) }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private var runRow: some View {
        HStack {
            Button("Run selected module") {
                guard let id = selectedModuleID else {
                    engine.reportError(IslandError.moduleNotFound)
                    return
                }
                do {
                    _ = try engine.runModule(id: id)
                } catch {
                    engine.reportError(error)
                }
            }
            .disabled(selectedModuleID == nil)
            Text("Assigns inbox → selected module")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var localConfirm: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let pending = engine.pendingLocal {
                Text("Confirm local run: \(pending.module.displayName)")
                    .font(.subheadline.weight(.semibold))
                Text("The module prompt is not executed as a shell command unless you type one below and confirm.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Open attached files with default apps", isOn: $confirmOpenFiles)
                TextField("Optional confirmed zsh command (empty = do not run a command)", text: $confirmCommand)
                HStack {
                    Button("Cancel") {
                        engine.cancelPendingLocal()
                        confirmCommand = ""
                    }
                    Button("Confirm local run") {
                        do {
                            try engine.confirmPendingLocal(
                                openAttachedFiles: confirmOpenFiles,
                                shellCommand: confirmCommand
                            )
                            confirmCommand = ""
                        } catch {
                            engine.reportError(error)
                        }
                    }
                }
            }
        }
        .padding(8)
        .background(Color.yellow.opacity(0.12))
    }

    private var quickAskRow: some View {
        HStack {
            TextField("Quick ask Grok", text: $quickAsk)
            Button("Ask") {
                do {
                    _ = try engine.quickAskGrok(quickAsk)
                    quickAsk = ""
                } catch {
                    engine.reportError(error)
                }
            }
            .disabled(quickAsk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var runsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Runs / notifications")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if engine.activeRunCount > 0 {
                    Text("\(engine.activeRunCount) running")
                        .font(.caption)
                }
                Button("Clear finished") { engine.clearFinishedRuns() }
            }
            if engine.runs.isEmpty {
                Text("No runs yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(engine.runs.prefix(6)) { run in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(run.moduleName)
                            Text(run.phase.rawValue)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if run.isActive {
                                Button("Cancel") { engine.cancelRun(id: run.id) }
                                    .buttonStyle(.borderless)
                            }
                        }
                        if run.phase == .running {
                            ProgressView(value: run.progress)
                        }
                        Text(run.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    private func saveDraft() {
        do {
            if let editingID, var existing = engine.modules.first(where: { $0.id == editingID }) {
                existing.name = draftName
                existing.prompt = draftPrompt
                existing.executor = draftExecutor
                _ = try engine.updateModule(existing)
            } else {
                let created = try engine.createModule(
                    name: draftName,
                    prompt: draftPrompt,
                    executor: draftExecutor
                )
                selectedModuleID = created.id
            }
            resetDraft()
        } catch {
            engine.reportError(error)
        }
    }

    private func beginEdit(_ module: FunctionModule) {
        editingID = module.id
        selectedModuleID = module.id
        draftName = module.name
        draftPrompt = module.prompt
        draftExecutor = module.executor
    }

    private func resetDraft() {
        editingID = nil
        draftName = ""
        draftPrompt = ""
        draftExecutor = .grokBot
    }
}
