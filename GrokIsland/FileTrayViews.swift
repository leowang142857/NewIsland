import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The 暂存 tab: files parked in Application Support, sorted into folders, dragged back out.
///
/// Rows are SwiftUI for looks. Pointer input on a row (click, double-click, drag out, right-click,
/// drops onto the row) goes through `TrayRowSurfaceView`, an AppKit view, because only an
/// `NSDraggingSource` can offer Finder a move and hear back when the drag ends.
struct FileTrayLayer: View {
    @ObservedObject var tray: FileTray
    /// Something is being dragged over the tray, so the shell keeps this tab instead of jumping to modules.
    @Binding var dragActive: Bool

    @State private var backgroundTargeted = false
    @State private var fileRowTargeted = false
    @State private var folderTarget: String?
    @State private var crumbTarget: String?
    @State private var pendingDelete: [String]?
    @State private var renameDraft = ""
    @State private var folderOptions: [TrayFolderOption] = []

    private var listTargeted: Bool { backgroundTargeted || fileRowTargeted }
    private var isReceiving: Bool { listTargeted || folderTarget != nil || crumbTarget != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            toolbar
            statusLine
            list
            if !isReceiving, !tray.isDraggingOut, !tray.entries.isEmpty {
                Text("拖出岛外就拿回去 · 拖到文件夹上归类 · ⌘ / ⇧ 多选")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .onDrop(of: TrayDrop.types, delegate: TrayDropTarget(
            targeted: $backgroundTargeted,
            operation: { TrayDrop.proposal(into: tray.folder, tray: tray) },
            perform: { TrayDrop.accept($0, into: tray.folder, tray: tray) }
        ))
        .onChange(of: isReceiving) { dragActive = isReceiving }
        .onChange(of: tray.renamingPath) { prepareRename() }
        .onChange(of: tray.entries) { folderOptions = tray.fileSystem.folderTree() }
        .onChange(of: tray.selection.isEmpty) { folderOptions = tray.fileSystem.folderTree() }
        .onAppear {
            tray.refresh()
            folderOptions = tray.fileSystem.folderTree()
            prepareRename()
        }
        .onDisappear { dragActive = false }
        .task { await keepFresh() }
        .task(id: tray.notice?.id) { await dismissNoticeLater() }
        .animation(.easeInOut(duration: 0.15), value: tray.notice)
        .animation(.easeInOut(duration: 0.15), value: isReceiving)
        .animation(.easeInOut(duration: 0.15), value: pendingDelete)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 6) {
            breadcrumb
            Spacer(minLength: 6)
            if tray.isImporting {
                ProgressView().controlSize(.mini)
                    .help("正在拷贝")
            }
            if tray.selection.isEmpty {
                idleActions
            } else {
                selectionActions
            }
        }
        .font(.system(size: 11))
        .frame(height: 20)
    }

    @ViewBuilder
    private var breadcrumb: some View {
        if tray.folder.isEmpty {
            Text(tray.entries.isEmpty ? "还没放东西" : "\(tray.entries.count) 项")
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        } else {
            let trail = TrayPath.trail(to: tray.folder)
            let collapsed = trail.count > 3
            let shown = collapsed ? [trail[0]] + Array(trail.suffix(2)) : trail
            HStack(spacing: 2) {
                Button {
                    tray.goUp()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 16, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("回到上一层")

                ForEach(Array(shown.enumerated()), id: \.element) { index, path in
                    if index > 0 {
                        Text(collapsed && index == 1 ? "… /" : "/")
                            .foregroundStyle(.tertiary)
                    }
                    TrayCrumb(
                        title: TrayPath.title(of: path),
                        isCurrent: path == tray.folder,
                        targeted: crumbTarget == path,
                        action: { if path != tray.folder { tray.open(path) } }
                    )
                    .onDrop(of: TrayDrop.types, delegate: TrayDropTarget(
                        targeted: crumbBinding(path),
                        operation: { TrayDrop.proposal(into: path, tray: tray) },
                        perform: { TrayDrop.accept($0, into: path, tray: tray) }
                    ))
                }
            }
        }
    }

    private var idleActions: some View {
        HStack(spacing: 2) {
            Button {
                commitRename()
                tray.createFolder()
            } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 22, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("新建文件夹")

            Menu {
                Picker("拖进来时", selection: $tray.dropMode) {
                    ForEach(TrayDropMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                Divider()
                if !tray.entries.isEmpty {
                    Button("全选") { tray.selection.selectAll(tray.orderedPaths) }
                }
                Button("在 Finder 中显示") { revealCurrentFolder() }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 22, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .help("拖进来的方式 · 在 Finder 中显示")
        }
    }

    private var selectionActions: some View {
        let selected = tray.selectedPaths
        return HStack(spacing: 10) {
            Text("已选 \(selected.count)")
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Menu("移到…") {
                Button("归入新文件夹") { tray.groupIntoNewFolder(selected) }
                Divider()
                ForEach(folderOptions, id: \.path) { option in
                    Button(String(repeating: "    ", count: option.depth) + option.name) {
                        tray.move(selected, into: option.path)
                    }
                    .disabled(!TrayPath.canMove(selected, into: option.path))
                }
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .fixedSize()
            Button("删除") { pendingDelete = selected }
                .foregroundStyle(IslandChrome.danger)
                .help("移到废纸篓，可以放回")
            Button {
                tray.selection.clear()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 14, height: 18)
                    .contentShape(Rectangle())
            }
            .help("取消选择")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    // MARK: - Status line

    @ViewBuilder
    private var statusLine: some View {
        if let pendingDelete {
            deleteConfirm(pendingDelete)
                .transition(.opacity)
        } else if isReceiving || tray.isDraggingOut {
            dropBanner
                .transition(.opacity)
        } else if let notice = tray.notice {
            Text(notice.text)
                .font(.system(size: 11))
                .foregroundStyle(notice.isProblem ? IslandChrome.danger : Color.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 2)
                .transition(.opacity)
        }
    }

    private var dropBanner: some View {
        let target = folderTarget ?? crumbTarget
        let internalDrag = tray.isDraggingOut
        return HStack(spacing: 6) {
            if internalDrag && target == nil {
                Text("拖到文件夹上归类，拖出岛外就拿回去")
                    .foregroundStyle(.secondary)
            } else {
                Text("松手放进「\(TrayPath.title(of: target ?? tray.folder))」")
                    .foregroundStyle(IslandChrome.accent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !internalDrag {
                    Text(tray.dropMode == .move ? "从原处移过来 · 按住 ⌥ 拷贝" : "拷贝一份 · 按住 ⌥ 改为移动")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: IslandChrome.innerRadius, style: .continuous)
                .fill(IslandChrome.surface)
        }
    }

    private func deleteConfirm(_ paths: [String]) -> some View {
        HStack(spacing: 10) {
            Text(paths.count == 1 ? "把「\(TrayPath.name(of: paths[0]))」移到废纸篓？" : "把 \(paths.count) 项移到废纸篓？")
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Button("取消") { pendingDelete = nil }
                .foregroundStyle(.secondary)
            Button("移到废纸篓") {
                tray.delete(paths)
                pendingDelete = nil
            }
            .foregroundStyle(IslandChrome.danger)
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: IslandChrome.innerRadius, style: .continuous)
                .fill(IslandChrome.danger.opacity(0.10))
        }
    }

    // MARK: - List

    private var list: some View {
        let shape = RoundedRectangle(cornerRadius: IslandChrome.innerRadius, style: .continuous)
        return Group {
            if tray.entries.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(tray.entries) { entry in
                                TrayRowView(
                                    entry: entry,
                                    url: tray.url(for: entry.path),
                                    selected: tray.selection.contains(entry.path),
                                    targeted: folderTarget == entry.path,
                                    renaming: tray.renamingPath == entry.path,
                                    draft: $renameDraft,
                                    handlers: handlers(for: entry),
                                    onCommitRename: commitRename,
                                    onCancelRename: { tray.renamingPath = nil }
                                )
                            }
                            // Room below the last row to click away the selection or drop.
                            Color.clear
                                .frame(height: 28)
                                .contentShape(Rectangle())
                                .onTapGesture(perform: clearSelection)
                        }
                        .padding(.vertical, 2)
                    }
                    .onChange(of: tray.renamingPath) {
                        guard let path = tray.renamingPath else { return }
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(path) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            shape
                .fill(listTargeted ? IslandChrome.accent.opacity(0.07) : Color.clear)
                .contentShape(shape)
                .onTapGesture(perform: clearSelection)
        }
        .overlay {
            shape
                .strokeBorder(listTargeted ? IslandChrome.accent.opacity(0.55) : Color.clear, lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private func clearSelection() {
        commitRename()
        pendingDelete = nil
        tray.selection.clear()
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tray.folder.isEmpty ? "暂存区是空的" : "这个文件夹是空的")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text(tray.folder.isEmpty
                 ? "把桌面或 Finder 里的文件拖进来先放着，在这里分好文件夹；要用的时候拖回桌面就拿回去了。"
                 : "从 Finder 拖进来，或者回上一层把文件拖到这个文件夹上。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Row behavior

    private func handlers(for entry: TrayEntry) -> TrayRowHandlers {
        let destination = entry.isFolder ? entry.path : tray.folder
        return TrayRowHandlers(
            click: { modifiers in click(entry, modifiers: modifiers) },
            open: { open(entry) },
            dragPaths: {
                commitRename()
                if !tray.selection.contains(entry.path) {
                    tray.selection.click(entry.path, in: tray.orderedPaths)
                }
                return tray.selection.dragged(from: entry.path, in: tray.orderedPaths)
            },
            url: { tray.url(for: $0) },
            dragBegan: { tray.beginDragOut($0) },
            dragEnded: { outside, operation in
                Task {
                    await tray.finishDragOut(
                        droppedOutside: outside,
                        operationWasCopy: operation == .copy,
                        cancelled: operation.isEmpty
                    )
                }
            },
            menu: { contextMenu(for: entry) },
            dropTargetChanged: { targeted in
                if entry.isFolder {
                    let next = targeted ? entry.path : (folderTarget == entry.path ? nil : folderTarget)
                    if folderTarget != next { folderTarget = next }
                } else if fileRowTargeted != targeted {
                    fileRowTargeted = targeted
                }
            },
            dropOperation: { urls, option in
                TrayDrop.operation(for: urls, into: destination, tray: tray, option: option)
            },
            drop: { urls, option, allowsMove in
                TrayDrop.accept(urls, into: destination, tray: tray, option: option, allowsMove: allowsMove)
            }
        )
    }

    private func click(_ entry: TrayEntry, modifiers: NSEvent.ModifierFlags) {
        if tray.renamingPath != entry.path { commitRename() }
        pendingDelete = nil
        tray.selection.click(
            entry.path,
            in: tray.orderedPaths,
            extend: modifiers.contains(.shift),
            toggle: modifiers.contains(.command)
        )
    }

    private func open(_ entry: TrayEntry) {
        commitRename()
        if entry.isFolder {
            tray.open(entry.path)
        } else if let url = tray.url(for: entry.path) {
            NSWorkspace.shared.open(url)
        }
    }

    private func contextMenu(for entry: TrayEntry) -> NSMenu {
        commitRename()
        if !tray.selection.contains(entry.path) {
            tray.selection.click(entry.path, in: tray.orderedPaths)
        }
        let paths = tray.selectedPaths.isEmpty ? [entry.path] : tray.selectedPaths
        let single = paths.count == 1
        let urls = paths.compactMap { tray.url(for: $0) }

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(TrayMenuItem(single && entry.isFolder ? "打开文件夹" : "打开") {
            if single, entry.isFolder {
                tray.open(entry.path)
            } else {
                urls.forEach { NSWorkspace.shared.open($0) }
            }
        })
        menu.addItem(TrayMenuItem("在 Finder 中显示") {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        })
        menu.addItem(.separator())
        menu.addItem(TrayMenuItem("重命名", enabled: single) {
            tray.renamingPath = paths[0]
        })

        let moveMenu = NSMenu()
        moveMenu.autoenablesItems = false
        moveMenu.addItem(TrayMenuItem("归入新文件夹") { tray.groupIntoNewFolder(paths) })
        moveMenu.addItem(.separator())
        for option in tray.fileSystem.folderTree() {
            let item = TrayMenuItem(option.name, enabled: TrayPath.canMove(paths, into: option.path)) {
                tray.move(paths, into: option.path)
            }
            item.indentationLevel = min(option.depth, 15)
            moveMenu.addItem(item)
        }
        let moveItem = NSMenuItem(title: "移到", action: nil, keyEquivalent: "")
        moveItem.submenu = moveMenu
        menu.addItem(moveItem)

        menu.addItem(.separator())
        menu.addItem(TrayMenuItem(single ? "移到废纸篓" : "把 \(paths.count) 项移到废纸篓") {
            pendingDelete = paths
        })
        return menu
    }

    // MARK: - Rename

    private func prepareRename() {
        guard let path = tray.renamingPath else { return }
        renameDraft = TrayPath.name(of: path)
        // Typing needs the island to be the key window; a click on a row does not make it key.
        NSApp.windows.first { $0 is IslandPanel }?.makeKey()
    }

    private func commitRename() {
        guard let path = tray.renamingPath else { return }
        let draft = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if draft.isEmpty || draft == TrayPath.name(of: path) {
            tray.renamingPath = nil
        } else {
            tray.rename(path, to: draft)
        }
    }

    // MARK: - Housekeeping

    private func crumbBinding(_ path: String) -> Binding<Bool> {
        Binding(
            get: { crumbTarget == path },
            set: { targeted in
                if targeted {
                    crumbTarget = path
                } else if crumbTarget == path {
                    crumbTarget = nil
                }
            }
        )
    }

    private func revealCurrentFolder() {
        guard let url = tray.url(for: tray.folder) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Picks up changes made in Finder while the tab is open.
    private func keepFresh() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !tray.isDraggingOut { tray.refresh() }
        }
    }

    private func dismissNoticeLater() async {
        guard let id = tray.notice?.id else { return }
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        tray.dismissNotice(id)
    }
}

/// One file or folder. Looks only; `TrayRowSurfaceView` on top takes the pointer.
private struct TrayRowView: View {
    let entry: TrayEntry
    let url: URL?
    let selected: Bool
    let targeted: Bool
    let renaming: Bool
    @Binding var draft: String
    let handlers: TrayRowHandlers
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void

    @State private var hovering = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        HStack(spacing: 8) {
            TrayItemIcon(entry: entry, url: url, highlighted: targeted)
                .frame(width: 16, height: 16)
            if renaming {
                TextField("", text: $draft)
                    .focused($fieldFocused)
                    .onSubmit(onCommitRename)
                    .onExitCommand(perform: onCancelRename)
                    .islandField(highlighted: true)
                    // One turn of the run loop, so the panel is key before the field asks for focus.
                    .onAppear { DispatchQueue.main.async { fieldFocused = true } }
                    .onChange(of: fieldFocused) {
                        if !fieldFocused { onCommitRename() }
                    }
            } else {
                Text(entry.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(meta)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                if entry.isFolder {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 26)
        .background(shape.fill(fill))
        .overlay {
            shape
                .strokeBorder(targeted ? IslandChrome.accent : Color.clear, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .overlay {
            if !renaming {
                TrayRowSurface(handlers: handlers, toolTip: toolTip) { inside in
                    if hovering != inside { hovering = inside }
                }
            }
        }
        .animation(.easeOut(duration: 0.12), value: targeted)
    }

    private var fill: Color {
        if targeted || selected { return IslandChrome.accent.opacity(0.14) }
        return hovering ? Color.white.opacity(0.05) : Color.clear
    }

    private var meta: String {
        if entry.isFolder {
            guard let count = entry.childCount else { return "" }
            return count == 0 ? "空" : "\(count) 项"
        }
        guard let size = entry.byteSize else { return "" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private var toolTip: String {
        var lines = [entry.name]
        if let added = entry.addedAt {
            lines.append("放进来：\(added.formatted(date: .abbreviated, time: .shortened))")
        }
        lines.append(entry.isFolder ? "双击打开 · 拖出岛外拿回去" : "双击用默认应用打开 · 拖出岛外拿回去")
        return lines.joined(separator: "\n")
    }
}

private struct TrayItemIcon: View {
    let entry: TrayEntry
    let url: URL?
    let highlighted: Bool

    var body: some View {
        if entry.isFolder {
            Image(systemName: "folder.fill")
                .font(.system(size: 12))
                .foregroundStyle(highlighted ? IslandChrome.accent : Color.white.opacity(0.55))
        } else if let url {
            Image(nsImage: TrayIconCache.icon(for: url))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "doc")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}

private struct TrayCrumb: View {
    let title: String
    let isCurrent: Bool
    let targeted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title.count > 8 ? String(title.prefix(7)) + "…" : title)
                .font(.system(size: 11, weight: isCurrent ? .semibold : .regular))
                .foregroundStyle(targeted ? IslandChrome.accent : (isCurrent ? Color.primary : Color.secondary))
                .lineLimit(1)
                .padding(.horizontal, 4)
                .frame(height: 18)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(targeted ? IslandChrome.accent.opacity(0.14) : Color.clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isCurrent ? title : "回到「\(title)」· 也可以把文件拖到这里")
    }
}

/// While files are dragged over the modules, a quiet slot under the grid parks them in the tray.
struct TrayDropSlot: View {
    @ObservedObject var tray: FileTray
    @Binding var targeted: Bool
    let onDropped: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: IslandChrome.innerRadius, style: .continuous)
        HStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 12))
            Text(targeted ? "松手放进暂存区" : "或者先放进暂存区")
                .font(.system(size: 11, weight: .medium))
            Spacer(minLength: 0)
            Text(tray.dropMode == .move ? "从原处移过来 · ⌥ 拷贝" : "拷贝一份 · ⌥ 移动")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .foregroundStyle(targeted ? IslandChrome.accent : Color.secondary)
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(shape.fill(targeted ? IslandChrome.accent.opacity(0.14) : IslandChrome.surface))
        .overlay {
            shape
                .strokeBorder(targeted ? IslandChrome.accent : Color.clear, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .contentShape(shape)
        .onDrop(of: TrayDrop.types, delegate: TrayDropTarget(
            targeted: $targeted,
            operation: { TrayDrop.proposal(into: "", tray: tray) },
            perform: { providers in
                onDropped()
                return TrayDrop.accept(providers, into: "", tray: tray)
            }
        ))
        .animation(.easeOut(duration: 0.12), value: targeted)
        .help("拖进 Application Support 里的暂存区，以后再拖回桌面")
    }
}

/// Shared drop rules for the tray's AppKit rows and SwiftUI targets.
@MainActor
enum TrayDrop {
    nonisolated static let types: [UTType] = [.fileURL]

    /// Finder sometimes hands over file reference URLs (`/.file/id=…`); the tray needs real paths.
    static func normalized(_ urls: [URL]) -> [URL] {
        urls.filter(\.isFileURL).map { ($0 as NSURL).filePathURL ?? $0 }
    }

    static func mode(for tray: FileTray, option: Bool) -> TrayDropMode {
        option ? tray.dropMode.flipped : tray.dropMode
    }

    /// Cursor for a SwiftUI target, which cannot read the dragged URLs until the drop. During a
    /// drag out of the tray the paths are known; anything else follows the drop mode and ⌥.
    static func proposal(into folder: String, tray: FileTray) -> DropOperation? {
        if tray.isDraggingOut {
            return TrayPath.canMove(tray.draggedPaths, into: folder) ? .move : nil
        }
        return mode(for: tray, option: NSEvent.modifierFlags.contains(.option)) == .move ? .move : .copy
    }

    /// Tray items onto a folder they are not already in move; files from outside follow the drop mode.
    static func operation(for urls: [URL], into folder: String, tray: FileTray, option: Bool) -> NSDragOperation {
        let inside = urls.compactMap { tray.fileSystem.relativePath(of: $0) }
        if !urls.isEmpty, inside.count == urls.count {
            return TrayPath.canMove(inside, into: folder) ? .move : []
        }
        return mode(for: tray, option: option) == .move ? .move : .copy
    }

    @discardableResult
    static func accept(_ urls: [URL], into folder: String, tray: FileTray, option: Bool, allowsMove: Bool = true) -> Bool {
        let inside = urls.compactMap { tray.fileSystem.relativePath(of: $0) }
        if !urls.isEmpty, inside.count == urls.count, !TrayPath.canMove(inside, into: folder) {
            return false
        }
        let chosen = allowsMove ? mode(for: tray, option: option) : .copy
        Task { await tray.receive(urls, into: folder, mode: chosen) }
        return true
    }

    /// SwiftUI drops resolve their URLs later, so ⌥ is read now, while the drop is happening.
    @discardableResult
    static func accept(_ providers: [NSItemProvider], into folder: String, tray: FileTray) -> Bool {
        let option = NSEvent.modifierFlags.contains(.option)
        Task { @MainActor in
            let urls = normalized(await ResourceIntake.loadFileURLs(from: providers))
            accept(urls, into: folder, tray: tray, option: option)
        }
        return true
    }
}

/// SwiftUI drop target with a move or copy cursor. `operation` returns nil to turn a drag
/// away, e.g. tray items already in that folder.
struct TrayDropTarget: DropDelegate {
    @Binding var targeted: Bool
    let operation: () -> DropOperation?
    let perform: ([NSItemProvider]) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: TrayDrop.types)
    }

    func dropEntered(info: DropInfo) {
        targeted = operation() != nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let next = operation()
        if targeted != (next != nil) { targeted = next != nil }
        return DropProposal(operation: next ?? .cancel)
    }

    func dropExited(info: DropInfo) {
        targeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        guard operation() != nil else { return false }
        return perform(info.itemProviders(for: TrayDrop.types))
    }
}

@MainActor
enum TrayIconCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 400
        return cache
    }()

    static func icon(for url: URL) -> NSImage {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 32, height: 32)
        cache.setObject(image, forKey: key)
        return image
    }
}

// MARK: - AppKit row surface

struct TrayRowHandlers {
    var click: (NSEvent.ModifierFlags) -> Void = { _ in }
    var open: () -> Void = {}
    /// Tray paths a drag starting on this row carries.
    var dragPaths: () -> [String] = { [] }
    var url: (String) -> URL? = { _ in nil }
    var dragBegan: ([String]) -> Void = { _ in }
    /// `outside` is false when the drop landed back on the island.
    var dragEnded: (_ outside: Bool, _ operation: NSDragOperation) -> Void = { _, _ in }
    var menu: () -> NSMenu? = { nil }
    var dropTargetChanged: (Bool) -> Void = { _ in }
    var dropOperation: (_ urls: [URL], _ option: Bool) -> NSDragOperation = { _, _ in [] }
    /// `allowsMove` is false when the app the files come from only lets them be copied.
    var drop: (_ urls: [URL], _ option: Bool, _ allowsMove: Bool) -> Bool = { _, _, _ in false }
}

private struct TrayRowSurface: NSViewRepresentable {
    let handlers: TrayRowHandlers
    let toolTip: String
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> TrayRowSurfaceView {
        let view = TrayRowSurfaceView()
        view.registerForDraggedTypes([.fileURL])
        view.handlers = handlers
        view.onHover = onHover
        view.toolTip = toolTip
        return view
    }

    func updateNSView(_ view: TrayRowSurfaceView, context: Context) {
        view.handlers = handlers
        view.onHover = onHover
        if view.toolTip != toolTip { view.toolTip = toolTip }
    }
}

final class TrayRowSurfaceView: NSView, NSDraggingSource {
    var handlers = TrayRowHandlers()
    var onHover: (Bool) -> Void = { _ in }

    /// The row can be torn down while its drag is still in flight; keep the source alive until it ends.
    private static var activeSource: TrayRowSurfaceView?

    private var mouseDown: NSEvent?
    private var dragging = false
    private var hoverArea: NSTrackingArea?
    private weak var dragWindow: NSWindow?
    private var pasteboardURLs: (sequence: Int, urls: [URL])?

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }

    override func mouseExited(with event: NSEvent) { onHover(false) }

    // MARK: Click, double-click, menu

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            showMenu(for: event)
            return
        }
        mouseDown = event
        dragging = false
        if event.clickCount == 2 {
            handlers.open()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let mouseDown, mouseDown.clickCount == 1 else { return }
        let dx = event.locationInWindow.x - mouseDown.locationInWindow.x
        let dy = event.locationInWindow.y - mouseDown.locationInWindow.y
        guard dx * dx + dy * dy > 16 else { return }
        dragging = true
        beginDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDown = nil }
        guard !dragging, let mouseDown, mouseDown.clickCount == 1 else { return }
        handlers.click(mouseDown.modifierFlags)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        handlers.menu()
    }

    private func showMenu(for event: NSEvent) {
        guard let menu = handlers.menu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    // MARK: Drag out

    private func beginDrag(with event: NSEvent) {
        let pairs = handlers.dragPaths().compactMap { path in handlers.url(path).map { (path, $0) } }
        guard !pairs.isEmpty else {
            dragging = false
            return
        }
        let origin = convert(event.locationInWindow, from: nil)
        let side: CGFloat = 32
        let items = pairs.enumerated().map { index, pair -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: pair.1 as NSURL)
            let offset = CGFloat(min(index, 4)) * 4
            let frame = NSRect(x: origin.x - side / 2 + offset, y: origin.y - side / 2 - offset, width: side, height: side)
            item.setDraggingFrame(frame, contents: NSWorkspace.shared.icon(forFile: pair.1.path))
            return item
        }
        dragWindow = window
        Self.activeSource = self
        handlers.dragBegan(pairs.map(\.0))
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = items.count > 1 ? .pile : .none
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Offering .move lets Finder take the file back out of the tray (copy with ⌥, as usual).
        // No .delete: deleting goes through the tray's own Trash button, which says what it did.
        [.move, .copy, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let onIsland = dragWindow?.frame.contains(screenPoint) ?? false
        let handlers = handlers
        dragging = false
        mouseDown = nil
        dragWindow = nil
        Self.activeSource = nil
        handlers.dragEnded(!onIsland, operation)
    }

    // MARK: Drops onto the row

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        evaluate(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        evaluate(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        handlers.dropTargetChanged(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        pasteboardURLs = nil
        handlers.dropTargetChanged(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        handlers.dropTargetChanged(false)
        let urls = fileURLs(in: sender)
        guard !urls.isEmpty else { return false }
        let allowsMove = sender.draggingSourceOperationMask.contains(.move)
        return handlers.drop(urls, NSEvent.modifierFlags.contains(.option), allowsMove)
    }

    private func evaluate(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = fileURLs(in: sender)
        let wanted = urls.isEmpty ? [] : handlers.dropOperation(urls, NSEvent.modifierFlags.contains(.option))
        let allowed = sender.draggingSourceOperationMask
        var operation: NSDragOperation = []
        if !wanted.isEmpty {
            if allowed.contains(wanted) {
                operation = wanted
            } else if allowed.contains(.copy) {
                operation = .copy
            } else if allowed.contains(.generic) {
                operation = .generic
            }
        }
        handlers.dropTargetChanged(!operation.isEmpty)
        return operation
    }

    /// Read once per drag; `draggingUpdated` fires on every mouse move.
    private func fileURLs(in sender: NSDraggingInfo) -> [URL] {
        if let pasteboardURLs, pasteboardURLs.sequence == sender.draggingSequenceNumber {
            return pasteboardURLs.urls
        }
        let objects = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        let urls = TrayDrop.normalized(objects)
        pasteboardURLs = (sender.draggingSequenceNumber, urls)
        return urls
    }
}

/// NSMenu item that runs a closure.
private final class TrayMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        isEnabled = enabled
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc private func fire() {
        handler()
    }
}
