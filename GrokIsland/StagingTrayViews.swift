import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Cyan count for the collapsed peek strip. Hidden when the tray is empty.
struct StagingCountBadge: View {
    var count: Int

    var body: some View {
        if let label = PeekStrip.stagingBadgeLabel(count: count) {
            Text(label)
                .font(.system(size: 8, weight: .bold).monospacedDigit())
                .foregroundStyle(Color.black.opacity(0.88))
                .padding(.horizontal, 4)
                .padding(.vertical, 0.5)
                .background(Capsule().fill(IslandChrome.neonCyan))
                .shadow(color: IslandChrome.neonCyan.opacity(0.7), radius: 3)
                .help("暂存托盘 \(label) 个，展开后可以整理或拖回桌面")
                .accessibilityLabel("暂存 \(label) 个")
        }
    }
}

/// Dashed drop target. Accepts Finder files and folders, and a drag that started inside the tray.
struct StagingDropWell: View {
    @ObservedObject var store: StagingTrayStore
    var folderID: UUID?
    @Binding var isTargeted: Bool
    var compact = false

    var body: some View {
        let tint = isTargeted ? IslandChrome.electricGreen : IslandChrome.neonCyan
        HStack(spacing: 6) {
            Image(systemName: isTargeted ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                .font(.caption)
            Text(title)
                .font(.caption2.weight(.semibold))
                .lineLimit(2)
            Spacer(minLength: 0)
            Text(store.moveFromDesktop ? "桌面移入" : "复制")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, compact ? 5 : 8)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint.opacity(isTargeted ? 0.16 : 0.08))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tint.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        .onDrop(of: Self.dropTypes, isTargeted: $isTargeted) { providers in
            acceptStagingDrop(providers, into: folderID, store: store)
            return true
        }
    }

    private var title: String {
        if isTargeted {
            return store.moveFromDesktop
                ? "松手暂存。只有桌面上的文件会在复制成功后移走"
                : "松手复制进暂存托盘，原文件留在原地"
        }
        return compact ? "拖到这里暂存，不执行模块" : "把文件或文件夹拖进这个分类"
    }

    static let dropTypes: [UTType] = [.fileURL, .folder]
}

/// Organizer: folders, rename, move, confirmed delete, and drag-out.
struct StagingTrayPage: View {
    @ObservedObject var store: StagingTrayStore

    @State private var folderID: UUID?
    @State private var newFolderName = ""
    @State private var renamingID: UUID?
    @State private var renameDraft = ""
    @State private var pendingRemoval: StagingNode?
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("放入方式", selection: $store.moveFromDesktop) {
                Text("复制").tag(false)
                Text("桌面移入").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("默认复制，原文件留在原地。桌面移入只在复制成功之后删除桌面上的那一份；其他位置一律只复制。")

            Text(store.moveFromDesktop
                 ? "桌面移入：复制成功后才删桌面上的原文件。不在桌面的一律只复制。"
                 : "复制：原文件留在原地，托盘里是另一份。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("按住一行拖到桌面或访达，会再放一份出去。移出托盘前会先确认。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                TextField("新文件夹", text: $newFolderName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(createFolder)
                Button("新建文件夹", action: createFolder)
                    .controlSize(.small)
            }

            breadcrumb
            StagingDropWell(store: store, folderID: folderID, isTargeted: $dropTargeted)

            if let note = store.statusNote, !note.isEmpty {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(IslandChrome.electricGreen)
                    .lineLimit(2)
            }
            if let error = store.lastError, !error.isEmpty {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(IslandChrome.alertRed)
                    .lineLimit(2)
            }

            if rows.isEmpty {
                Text("这个文件夹还是空的。从访达或桌面把文件拖进来。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(rows) { node in
                            StagingRow(
                                node: node,
                                store: store,
                                renaming: renamingID == node.id,
                                renameDraft: $renameDraft,
                                onOpen: { folderID = node.id },
                                onBeginRename: {
                                    renamingID = node.id
                                    renameDraft = node.name
                                },
                                onCommitRename: { commitRename(node) },
                                onCancelRename: { renamingID = nil },
                                onRemove: { pendingRemoval = node }
                            )
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
        }
        .onChange(of: store.nodes) {
            if let folderID, store.node(id: folderID) == nil {
                self.folderID = nil
            }
            if let renamingID, store.node(id: renamingID) == nil {
                self.renamingID = nil
            }
        }
        .alert(
            "移出暂存托盘？",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            )
        ) {
            Button("删除副本", role: .destructive) {
                guard let pendingRemoval else { return }
                do {
                    try store.remove(id: pendingRemoval.id, confirmed: true)
                    store.statusNote = "已删除暂存副本。原来的文件如果还在，不会受影响。"
                } catch {
                    store.report(error)
                }
                self.pendingRemoval = nil
            }
            Button("取消", role: .cancel) {
                pendingRemoval = nil
            }
        } message: {
            Text("只删除灵动岛里的暂存副本。拖进来时如果选的是复制，桌面或访达里的原文件还在。")
        }
    }

    private var rows: [StagingNode] {
        store.children(of: folderID)
    }

    private var breadcrumb: some View {
        let crumbs = breadcrumbs
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                crumbButton("托盘", active: folderID == nil) { folderID = nil }
                ForEach(crumbs) { node in
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                    crumbButton(node.name, active: node.id == folderID) { folderID = node.id }
                }
            }
        }
    }

    private var breadcrumbs: [StagingNode] {
        var chain: [StagingNode] = []
        var current = folderID
        var guardCount = 0
        while let id = current, let node = store.node(id: id), guardCount < 32 {
            chain.append(node)
            current = node.parentID
            guardCount += 1
        }
        return chain.reversed()
    }

    private func crumbButton(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption2.weight(active ? .semibold : .regular))
                .foregroundStyle(active ? IslandChrome.neonCyan : Color.secondary)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            _ = try store.createFolder(name: name, in: folderID)
            newFolderName = ""
            store.statusNote = "已创建文件夹「\(name)」"
            store.lastError = nil
        } catch {
            store.report(error)
        }
    }

    private func commitRename(_ node: StagingNode) {
        do {
            _ = try store.rename(id: node.id, to: renameDraft)
            renamingID = nil
        } catch {
            store.report(error)
        }
    }
}

private struct StagingRow: View {
    let node: StagingNode
    @ObservedObject var store: StagingTrayStore
    var renaming: Bool
    @Binding var renameDraft: String
    var onOpen: () -> Void
    var onBeginRename: () -> Void
    var onCommitRename: () -> Void
    var onCancelRename: () -> Void
    var onRemove: () -> Void

    @State private var targeted = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(node.isCategory ? IslandChrome.amber : IslandChrome.neonCyan)
                .frame(width: 16)

            if renaming {
                TextField("名称", text: $renameDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(onCommitRename)
                Button("好", action: onCommitRename)
                    .controlSize(.small)
                Button("取消", action: onCancelRename)
                    .controlSize(.small)
            } else {
                Button(action: { if node.isCategory { onOpen() } }) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(node.name)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(node.isCategory ? "打开这个文件夹" : "拖到桌面或访达会再拷出一份，托盘里的还在")

                Menu {
                    Button("重命名", action: onBeginRename)
                    Menu("移到") {
                        if node.parentID != nil {
                            Button("托盘根目录") { move(into: nil) }
                        }
                        if moveTargets.isEmpty, node.parentID == nil {
                            Button("没有其他文件夹") {}
                                .disabled(true)
                        }
                        ForEach(moveTargets) { folder in
                            Button(folder.name) { move(into: folder.id) }
                        }
                    }
                    Button("移出托盘", role: .destructive, action: onRemove)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.caption)
                        .frame(width: 22, height: 18)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("重命名、移动或移出")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(targeted ? IslandChrome.neonCyan.opacity(0.16) : Color.white.opacity(0.05))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(targeted ? IslandChrome.neonCyan : IslandChrome.neonCyan.opacity(0.28), lineWidth: 1)
        }
        .onDrag { dragProvider }
        .onDrop(of: StagingDropWell.dropTypes, isTargeted: $targeted) { providers in
            guard node.isCategory else { return false }
            acceptStagingDrop(providers, into: node.id, store: store)
            return true
        }
    }

    private var icon: String {
        switch node.kind {
        case .category: "folder.fill"
        case .directory: "folder"
        case .file: "doc"
        }
    }

    private var subtitle: String {
        switch node.kind {
        case .category:
            let count = store.children(of: node.id).count
            return count == 0 ? "空文件夹" : "\(count) 项"
        case .directory:
            return node.importedAs == .move ? "文件夹 · 已从桌面移入" : "文件夹 · 副本"
        case .file:
            return node.importedAs == .move ? "已从桌面移入" : "副本"
        }
    }

    private var moveTargets: [StagingNode] {
        store.categories(excluding: node.id).filter { $0.id != node.parentID }
    }

    private var dragProvider: NSItemProvider {
        guard let url = try? store.exportURL(for: node.id) else { return NSItemProvider() }
        let provider = NSItemProvider()
        provider.suggestedName = node.name
        provider.registerObject(url as NSURL, visibility: .all)
        return provider
    }

    private func move(into parentID: UUID?) {
        do {
            try store.move(id: node.id, into: parentID)
        } catch {
            store.report(error)
        }
    }
}

@MainActor
func acceptStagingDrop(_ providers: [NSItemProvider], into folderID: UUID?, store: StagingTrayStore) {
    Task { @MainActor in
        let items = await ResourceIntake.loadItems(from: providers)
        let urls = items.compactMap { item -> URL? in
            guard item.kind == .file || item.kind == .folder else { return nil }
            return item.url
        }
        do {
            _ = try store.stage(urls: urls, into: folderID)
        } catch {
            store.report(error)
        }
    }
}
