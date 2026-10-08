import Foundation
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif

/// The staging tray (暂存) keeps real files and folders under
/// `Application Support/GrokIsland/tray/`. The folder on disk is the only source of truth:
/// nothing is cataloged on the side, so whatever is in that folder after a relaunch is the tray.
///
/// Paths in this file are relative to the tray root and `/`-separated; `""` is the root.

/// One file or folder sitting in the tray.
struct TrayEntry: Identifiable, Hashable, Sendable {
    let path: String
    let name: String
    let isFolder: Bool
    /// Files only.
    let byteSize: Int64?
    /// Folders only: visible items directly inside.
    let childCount: Int?
    /// When it landed in its folder, where the file system knows; newest files list first.
    let addedAt: Date?

    var id: String { path }

    /// Folders first by name, then files newest first, then by name.
    static func displayOrder(_ a: TrayEntry, _ b: TrayEntry) -> Bool {
        if a.isFolder != b.isFolder { return a.isFolder }
        if !a.isFolder {
            let left = a.addedAt ?? .distantPast
            let right = b.addedAt ?? .distantPast
            if left != right { return left > right }
        }
        return TrayNaming.ascending(a.name, b.name)
    }
}

enum TrayPath {
    static let rootTitle = "暂存"

    static func join(_ folder: String, _ name: String) -> String {
        folder.isEmpty ? name : folder + "/" + name
    }

    static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    static func name(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    static func title(of folder: String) -> String {
        folder.isEmpty ? rootTitle : name(of: folder)
    }

    /// `path` is `folder` itself or somewhere inside it. Everything is within the root.
    static func isWithin(_ path: String, _ folder: String) -> Bool {
        folder.isEmpty || path == folder || path.hasPrefix(folder + "/")
    }

    /// Root first, then each folder down to `folder`: `"a/b"` → `["", "a", "a/b"]`.
    static func trail(to folder: String) -> [String] {
        var trail = [""]
        var current = ""
        for part in folder.split(separator: "/") {
            current = join(current, String(part))
            trail.append(current)
        }
        return trail
    }

    /// At least one of `paths` would actually go somewhere if dropped on `folder`.
    static func canMove(_ paths: [String], into folder: String) -> Bool {
        paths.contains { path in
            !path.isEmpty && parent(of: path) != folder && !isWithin(folder, path)
        }
    }
}

enum TrayNaming {
    static let newFolderName = "新建文件夹"
    static let maxNameBytes = 255

    /// A name typed by the user: trimmed, and safe to use as one path component.
    static func validate(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw TrayError.nameEmpty }
        guard isPathComponent(name), !name.contains(":") else { throw TrayError.nameInvalid }
        guard name.utf8.count <= maxNameBytes else { throw TrayError.nameTooLong }
        return name
    }

    /// Anything already on disk that the tray will show and address. Hidden names are skipped.
    static func isPathComponent(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\0")
    }

    /// Finder-style: `报告.pdf` → `报告 2.pdf` → `报告 3.pdf`. Folders keep dots in the base name.
    static func uniqueName(_ name: String, isFolder: Bool, isTaken: (String) -> Bool) -> String {
        guard isTaken(name) else { return name }
        let (base, ext) = isFolder ? (name, "") : split(name)
        func candidate(_ suffix: String) -> String {
            ext.isEmpty ? "\(base) \(suffix)" : "\(base) \(suffix).\(ext)"
        }
        for number in 2...9_999 where !isTaken(candidate(String(number))) {
            return candidate(String(number))
        }
        return candidate(String(UUID().uuidString.prefix(8)))
    }

    static func split(_ name: String) -> (base: String, ext: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        let ext = String(name[name.index(after: dot)...])
        guard !ext.isEmpty, !ext.contains(" ") else { return (name, "") }
        return (String(name[..<dot]), ext)
    }

    static func ascending(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.caseInsensitive, .numeric]) == .orderedAscending
    }
}

enum TrayError: LocalizedError, Equatable {
    case nameEmpty
    case nameInvalid
    case nameTooLong
    case nameTaken(String)
    case notFound(String)
    case intoItself(String)
    case containsTray
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .nameEmpty: "名字不能为空"
        case .nameInvalid: "名字里不能有 / 或 :，也不能以 . 开头"
        case .nameTooLong: "名字太长了"
        case .nameTaken(let name): "这里已经有「\(name)」了"
        case .notFound(let name): "找不到「\(name)」，可能已经被移走了"
        case .intoItself(let name): "不能把「\(name)」放进它自己里面"
        case .containsTray: "它里面装着暂存区本身，不能放进来"
        case .failed(let reason): reason
        }
    }

    /// File-system errors in words a person would use.
    static func describe(_ error: Error) -> String {
        if let tray = error as? TrayError { return tray.localizedDescription }
        if let cocoa = error as? CocoaError {
            switch cocoa.code {
            case .fileWriteNoPermission, .fileReadNoPermission: return "没有权限"
            case .fileWriteOutOfSpace: return "磁盘空间不够"
            case .fileNoSuchFile, .fileReadNoSuchFile: return "找不到了"
            case .fileWriteFileExists: return "同名的已经存在"
            case .fileWriteVolumeReadOnly: return "那个磁盘是只读的"
            default: break
            }
        }
        return error.localizedDescription
    }
}

/// What dropping files from elsewhere does to the originals.
enum TrayDropMode: String, CaseIterable, Identifiable, Sendable {
    /// Like dragging within Finder: the file leaves its old place. From another disk it is copied.
    case move
    /// The original stays where it was.
    case copy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .move: "移进来，原处不留"
        case .copy: "拷贝一份，原文件不动"
        }
    }

    var flipped: TrayDropMode { self == .move ? .copy : .move }
}

/// What a drop onto a tray folder would do, decided while the drag hovers. The UI turns it into
/// the cursor badge and then performs the same thing on drop.
enum TrayDropIntent: Equatable, Sendable {
    /// Nothing would change, e.g. tray items dropped on the folder they are already in.
    case refuse
    case move
    case copy

    /// Items already in the tray only ever move between its folders.
    static func forTrayItems(_ paths: [String], into folder: String) -> TrayDropIntent {
        TrayPath.canMove(paths, into: folder) ? .move : .refuse
    }

    /// Files from elsewhere follow the drop mode, flipped while ⌥ is held. An app that only lets
    /// its files be copied gets a copy whatever the mode.
    static func forOutsideFiles(mode: TrayDropMode, option: Bool, sourceAllowsMove: Bool = true) -> TrayDropIntent {
        guard sourceAllowsMove else { return .copy }
        return (option ? mode.flipped : mode) == .move ? .move : .copy
    }

    /// The mode to hand `FileTray.receive`, or nil when the drop should be turned away.
    var mode: TrayDropMode? {
        switch self {
        case .refuse: nil
        case .move: .move
        case .copy: .copy
        }
    }
}

struct TrayFailure: Equatable, Sendable {
    var name: String
    var reason: String
}

/// Outcome of a drop or a move inside the tray.
struct TrayTransferReport: Equatable, Sendable {
    /// Paths that arrived by moving: from Finder on the same disk, or from another tray folder.
    var moved: [String] = []
    /// Paths that are copies; the originals are still where they were.
    var copied: [String] = []
    /// Copies made although moving was asked for (another disk, or the original could not be moved).
    var keptOriginals = 0
    /// Already in the destination folder.
    var unchanged = 0
    var failures: [TrayFailure] = []

    var arrived: [String] { moved + copied }

    mutating func merge(_ other: TrayTransferReport) {
        moved += other.moved
        copied += other.copied
        keptOriginals += other.keptOriginals
        unchanged += other.unchanged
        failures += other.failures
    }

    /// One line for the tray, e.g. `已移进「论文」3 项`.
    func summary(destination: String) -> String {
        var line: String
        switch (moved.count, copied.count) {
        case (0, 0):
            line = unchanged > 0 && failures.isEmpty ? "已经在「\(destination)」里了" : ""
        case (let m, 0):
            line = "已移进「\(destination)」\(m) 项"
        case (0, let c):
            line = "已拷贝 \(c) 项到「\(destination)」"
        case (let m, let c):
            line = "已移进「\(destination)」\(m) 项，另拷贝 \(c) 项"
        }
        if keptOriginals > 0 {
            line += "（\(keptOriginals) 项在别的磁盘或移不动，原件留着）"
        }
        if let first = failures.first {
            let failed = failures.count == 1 ? "「\(first.name)」" : "\(failures.count) 项"
            let reason = "\(failed)没放进来：\(first.reason)"
            line = line.isEmpty ? reason : line + "；" + reason
        }
        return line
    }
}

struct TrayDeleteReport: Equatable, Sendable {
    /// Moved to the system Trash, so they can be put back.
    var trashed = 0
    /// Removed outright (platforms without a Trash).
    var removed = 0
    var failures: [TrayFailure] = []

    var summary: String {
        var parts: [String] = []
        if trashed > 0 { parts.append("已移到废纸篓 \(trashed) 项，可以从废纸篓放回") }
        if removed > 0 { parts.append("已删除 \(removed) 项") }
        if let first = failures.first {
            parts.append("「\(first.name)」删不掉：\(first.reason)")
        }
        return parts.joined(separator: "；")
    }
}

/// A destination for "移到…", indented by depth.
struct TrayFolderOption: Hashable, Sendable {
    let path: String
    let name: String
    let depth: Int
}

/// File operations on the tray folder. Holds no state besides the root, so it is safe to use
/// off the main thread for long copies.
struct TrayFileSystem: Sendable {
    let root: URL

    init(root: URL? = nil) {
        self.root = (root ?? Self.defaultRoot).standardizedFileURL
    }

    static var defaultRoot: URL {
        IslandSettingsStorage.defaultFolder.appendingPathComponent("tray", isDirectory: true)
    }

    func ensureRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// The URL for a tray path, or nil if the path could point outside the tray.
    func url(for path: String) -> URL? {
        guard !path.isEmpty else { return root }
        var url = root
        for part in path.split(separator: "/", omittingEmptySubsequences: false) {
            let component = String(part)
            guard TrayNaming.isPathComponent(component) else { return nil }
            url.appendPathComponent(component)
        }
        return url
    }

    /// Tray path of a file URL, or nil when it lives outside the tray.
    func relativePath(of url: URL) -> String? {
        guard url.isFileURL else { return nil }
        let roots = Set([root.path, root.resolvingSymlinksInPath().path])
        for candidate in [url.standardizedFileURL.path, url.resolvingSymlinksInPath().path] {
            for base in roots {
                if candidate == base { return "" }
                let prefix = base.hasSuffix("/") ? base : base + "/"
                if candidate.hasPrefix(prefix) {
                    return String(candidate.dropFirst(prefix.count))
                }
            }
        }
        return nil
    }

    func itemExists(_ path: String) -> Bool {
        guard let url = url(for: path) else { return false }
        return Self.itemExists(at: url)
    }

    func folderExists(_ path: String) -> Bool {
        guard let url = url(for: path) else { return false }
        return Self.isFolder(at: url)
    }

    func entries(in folder: String) throws -> [TrayEntry] {
        if folder.isEmpty { try ensureRoot() }
        guard let directory = url(for: folder), Self.isFolder(at: directory) else {
            throw TrayError.notFound(TrayPath.title(of: folder))
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        return names
            .filter(TrayNaming.isPathComponent)
            .map { name in entry(at: directory.appendingPathComponent(name), path: TrayPath.join(folder, name)) }
            .sorted(by: TrayEntry.displayOrder)
    }

    /// Every folder in the tray, depth-first with the root first, for "移到…".
    func folderTree(maxDepth: Int = 8, limit: Int = 300) -> [TrayFolderOption] {
        var result = [TrayFolderOption(path: "", name: TrayPath.rootTitle, depth: 0)]
        func walk(_ folder: String, depth: Int) {
            guard depth < maxDepth, let directory = url(for: folder),
                  let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
            else { return }
            let folders = names
                .filter { TrayNaming.isPathComponent($0) && Self.isFolder(at: directory.appendingPathComponent($0)) }
                .sorted(by: TrayNaming.ascending)
            for name in folders {
                guard result.count < limit else { return }
                let path = TrayPath.join(folder, name)
                result.append(TrayFolderOption(path: path, name: name, depth: depth + 1))
                walk(path, depth: depth + 1)
            }
        }
        walk("", depth: 0)
        return result
    }

    // MARK: - Changes

    /// Brings files from outside into `folder`. URLs already inside the tray are moved between
    /// tray folders instead. Name clashes get a Finder-style number, never an overwrite.
    func importItems(_ sources: [URL], into folder: String, mode: TrayDropMode) -> TrayTransferReport {
        var report = TrayTransferReport()
        if folder.isEmpty { try? ensureRoot() }
        guard let target = url(for: folder), Self.isFolder(at: target) else {
            let reason = TrayError.notFound(TrayPath.title(of: folder)).localizedDescription
            report.failures = sources.map { TrayFailure(name: $0.lastPathComponent, reason: reason) }
            return report
        }

        let fm = FileManager.default
        var seen = Set<String>()
        var inside: [String] = []
        for source in sources where source.isFileURL {
            let original = source.standardizedFileURL
            guard seen.insert(original.path).inserted else { continue }
            if let path = relativePath(of: original) {
                inside.append(path)
                continue
            }
            let name = original.lastPathComponent
            guard Self.itemExists(at: original) else {
                report.failures.append(TrayFailure(name: name, reason: "原文件找不到了"))
                continue
            }
            guard !swallowsTray(original) else {
                report.failures.append(TrayFailure(name: name, reason: TrayError.containsTray.localizedDescription))
                continue
            }

            let finalName = TrayNaming.uniqueName(name, isFolder: Self.isFolder(at: original)) {
                Self.itemExists(at: target.appendingPathComponent($0))
            }
            let destination = target.appendingPathComponent(finalName)
            let path = TrayPath.join(folder, finalName)

            if mode == .move, Self.sameVolume(original, target) {
                do {
                    try fm.moveItem(at: original, to: destination)
                    report.moved.append(path)
                    continue
                } catch {
                    // A locked or read-only original can still be copied; fall through.
                    guard !Self.itemExists(at: destination) else {
                        report.failures.append(TrayFailure(name: name, reason: TrayError.describe(error)))
                        continue
                    }
                }
            }
            do {
                try fm.copyItem(at: original, to: destination)
                report.copied.append(path)
                if mode == .move { report.keptOriginals += 1 }
            } catch {
                try? fm.removeItem(at: destination)
                report.failures.append(TrayFailure(name: name, reason: TrayError.describe(error)))
            }
        }
        if !inside.isEmpty {
            report.merge(move(inside, into: folder))
        }
        return report
    }

    /// Moves tray items into another tray folder.
    func move(_ paths: [String], into folder: String) -> TrayTransferReport {
        var report = TrayTransferReport()
        guard let target = url(for: folder), Self.isFolder(at: target) else {
            let reason = TrayError.notFound(TrayPath.title(of: folder)).localizedDescription
            report.failures = paths.map { TrayFailure(name: TrayPath.name(of: $0), reason: reason) }
            return report
        }
        var seen = Set<String>()
        for path in paths where seen.insert(path).inserted {
            guard !path.isEmpty else {
                let reason = TrayError.intoItself(TrayPath.rootTitle).localizedDescription
                report.failures.append(TrayFailure(name: TrayPath.rootTitle, reason: reason))
                continue
            }
            let name = TrayPath.name(of: path)
            guard let source = url(for: path), Self.itemExists(at: source) else {
                report.failures.append(TrayFailure(name: name, reason: TrayError.notFound(name).localizedDescription))
                continue
            }
            if TrayPath.parent(of: path) == folder {
                report.unchanged += 1
                continue
            }
            if TrayPath.isWithin(folder, path) {
                report.failures.append(TrayFailure(name: name, reason: TrayError.intoItself(name).localizedDescription))
                continue
            }
            let finalName = TrayNaming.uniqueName(name, isFolder: Self.isFolder(at: source)) {
                Self.itemExists(at: target.appendingPathComponent($0))
            }
            do {
                try FileManager.default.moveItem(at: source, to: target.appendingPathComponent(finalName))
                report.moved.append(TrayPath.join(folder, finalName))
            } catch {
                report.failures.append(TrayFailure(name: name, reason: TrayError.describe(error)))
            }
        }
        return report
    }

    /// A new folder in `folder`. Without a name it is `新建文件夹`, numbered if that is taken.
    @discardableResult
    func createFolder(named raw: String? = nil, in folder: String) throws -> String {
        if folder.isEmpty { try ensureRoot() }
        guard let parent = url(for: folder), Self.isFolder(at: parent) else {
            throw TrayError.notFound(TrayPath.title(of: folder))
        }
        let name: String
        if let raw {
            name = try TrayNaming.validate(raw)
            guard !Self.itemExists(at: parent.appendingPathComponent(name)) else { throw TrayError.nameTaken(name) }
        } else {
            name = TrayNaming.uniqueName(TrayNaming.newFolderName, isFolder: true) {
                Self.itemExists(at: parent.appendingPathComponent($0))
            }
        }
        do {
            try FileManager.default.createDirectory(at: parent.appendingPathComponent(name), withIntermediateDirectories: false)
        } catch {
            throw TrayError.failed(TrayError.describe(error))
        }
        return TrayPath.join(folder, name)
    }

    /// Renames in place and returns the new path. Never replaces another item.
    @discardableResult
    func rename(_ path: String, to raw: String) throws -> String {
        let current = TrayPath.name(of: path)
        guard !path.isEmpty, let source = url(for: path), Self.itemExists(at: source) else {
            throw TrayError.notFound(current)
        }
        let name = try TrayNaming.validate(raw)
        guard name != current else { return path }
        let parent = source.deletingLastPathComponent()
        let destination = parent.appendingPathComponent(name)
        let newPath = TrayPath.join(TrayPath.parent(of: path), name)
        let fm = FileManager.default

        if name.lowercased() == current.lowercased() {
            // Case-only change: on a case-insensitive disk the target "exists" and is the item itself.
            let temporary = parent.appendingPathComponent(".rename-\(UUID().uuidString)")
            do {
                try fm.moveItem(at: source, to: temporary)
            } catch {
                throw TrayError.failed(TrayError.describe(error))
            }
            do {
                try fm.moveItem(at: temporary, to: destination)
            } catch {
                try? fm.moveItem(at: temporary, to: source)
                throw TrayError.nameTaken(name)
            }
            return newPath
        }

        guard !Self.itemExists(at: destination) else { throw TrayError.nameTaken(name) }
        do {
            try fm.moveItem(at: source, to: destination)
        } catch {
            throw TrayError.failed(TrayError.describe(error))
        }
        return newPath
    }

    /// On macOS items go to the Trash so they can be put back; elsewhere they are removed.
    func delete(_ paths: [String]) -> TrayDeleteReport {
        var report = TrayDeleteReport()
        var seen = Set<String>()
        for path in paths where !path.isEmpty && seen.insert(path).inserted {
            guard let url = url(for: path), Self.itemExists(at: url) else { continue }
            do {
                #if os(macOS)
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                report.trashed += 1
                #else
                try FileManager.default.removeItem(at: url)
                report.removed += 1
                #endif
            } catch {
                report.failures.append(TrayFailure(name: TrayPath.name(of: path), reason: TrayError.describe(error)))
            }
        }
        return report
    }

    // MARK: - Helpers

    private func entry(at url: URL, path: String) -> TrayEntry {
        let isFolder = Self.isFolder(at: url)
        var keys: Set<URLResourceKey> = [.fileSizeKey, .creationDateKey, .contentModificationDateKey]
        #if os(macOS)
        keys.insert(.addedToDirectoryDateKey)
        #endif
        let values = try? url.resourceValues(forKeys: keys)
        #if os(macOS)
        let added = values?.addedToDirectoryDate ?? values?.creationDate ?? values?.contentModificationDate
        #else
        let added = values?.creationDate ?? values?.contentModificationDate
        #endif
        var childCount: Int?
        if isFolder {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            childCount = names.filter(TrayNaming.isPathComponent).count
        }
        return TrayEntry(
            path: path,
            name: TrayPath.name(of: path),
            isFolder: isFolder,
            byteSize: isFolder ? nil : values?.fileSize.map { Int64($0) },
            childCount: childCount,
            addedAt: added
        )
    }

    /// Dropping `~/Library` (or anything above the tray) would try to move the tray into itself.
    private func swallowsTray(_ source: URL) -> Bool {
        let roots = [root.path, root.resolvingSymlinksInPath().path]
        for candidate in [source.standardizedFileURL.path, source.resolvingSymlinksInPath().path] {
            let prefix = candidate.hasSuffix("/") ? candidate : candidate + "/"
            if roots.contains(where: { $0 == candidate || $0.hasPrefix(prefix) }) { return true }
        }
        return false
    }

    /// Exists, without following a symlink at the end (a broken link still counts).
    static func itemExists(at url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    /// A real folder you can open in the tray: not a symlink, and not an app or other package.
    static func isFolder(at url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeDirectory
        else { return false }
        #if os(macOS)
        if (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true { return false }
        #endif
        return true
    }

    /// Same device, so a move is a rename. Unknown counts as same and lets `moveItem` decide.
    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        func device(_ url: URL) -> UInt64? {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
            if let number = attributes[.systemNumber] as? NSNumber { return number.uint64Value }
            if let value = attributes[.systemNumber] as? Int { return UInt64(value) }
            return nil
        }
        guard let left = device(a), let right = device(b) else { return true }
        return left == right
    }
}

/// Finder-like selection: click selects one, ⌘ toggles, ⇧ extends from the last plain click.
struct TraySelection: Equatable, Sendable {
    private(set) var paths: Set<String> = []
    private(set) var anchor: String?

    var isEmpty: Bool { paths.isEmpty }
    var count: Int { paths.count }

    func contains(_ path: String) -> Bool { paths.contains(path) }

    mutating func click(_ path: String, in order: [String], extend: Bool = false, toggle: Bool = false) {
        if extend, let anchor, let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: path) {
            let range = Set(order[min(from, to)...max(from, to)])
            paths = toggle ? paths.union(range) : range
            return
        }
        if toggle {
            if paths.contains(path) {
                paths.remove(path)
            } else {
                paths.insert(path)
            }
            anchor = path
            return
        }
        paths = [path]
        anchor = path
    }

    mutating func selectAll(_ order: [String]) {
        paths = Set(order)
        anchor = order.first
    }

    mutating func replace(with selected: [String]) {
        paths = Set(selected)
        anchor = selected.first
    }

    mutating func clear() {
        paths = []
        anchor = nil
    }

    /// Drops anything no longer listed.
    mutating func prune(to order: [String]) {
        let listed = Set(order)
        paths.formIntersection(listed)
        if let anchor, !listed.contains(anchor) { self.anchor = nil }
    }

    func ordered(in order: [String]) -> [String] {
        order.filter(paths.contains)
    }

    /// A drag that starts on a selected row carries the whole selection; otherwise just that row.
    func dragged(from path: String, in order: [String]) -> [String] {
        paths.contains(path) ? ordered(in: order) : [path]
    }
}

/// A short line under the tray toolbar after something happened.
struct TrayNotice: Equatable, Identifiable, Sendable {
    let id = UUID()
    let text: String
    let isProblem: Bool
}

/// Observable tray for the island: the folder being looked at, its entries, the selection,
/// and every change, each followed by a fresh listing from disk.
@MainActor
final class FileTray: ObservableObject {
    static let dropModeKey = "trayDropMode"

    let fileSystem: TrayFileSystem
    private let defaults: UserDefaults

    @Published private(set) var folder = ""
    @Published private(set) var entries: [TrayEntry] = []
    /// Items at the root, for the tab badge.
    @Published private(set) var rootCount = 0
    @Published var selection = TraySelection()
    /// Row whose name is being edited inline.
    @Published var renamingPath: String?
    @Published private(set) var notice: TrayNotice?
    @Published private(set) var importsInFlight = 0
    /// A drag out of the tray is in flight; the island stays open until it ends.
    @Published var isDraggingOut = false
    /// Paths being dragged out, so drop targets can tell an internal move from a new drop.
    @Published private(set) var draggedPaths: [String] = []
    @Published var dropMode: TrayDropMode {
        didSet { defaults.set(dropMode.rawValue, forKey: Self.dropModeKey) }
    }

    init(fileSystem: TrayFileSystem = TrayFileSystem(), defaults: UserDefaults = .standard) {
        self.fileSystem = fileSystem
        self.defaults = defaults
        dropMode = defaults.string(forKey: Self.dropModeKey).flatMap(TrayDropMode.init(rawValue:)) ?? .move
        refresh()
    }

    var isImporting: Bool { importsInFlight > 0 }
    var title: String { TrayPath.title(of: folder) }
    var orderedPaths: [String] { entries.map(\.path) }
    var selectedPaths: [String] { selection.ordered(in: orderedPaths) }

    func entry(_ path: String) -> TrayEntry? {
        entries.first { $0.path == path }
    }

    func url(for path: String) -> URL? {
        fileSystem.url(for: path)
    }

    /// Re-reads the folder. If it vanished (moved away in Finder), falls back to the root.
    func refresh() {
        if !folder.isEmpty, !fileSystem.folderExists(folder) {
            folder = ""
        }
        let next = (try? fileSystem.entries(in: folder)) ?? []
        if next != entries { entries = next }
        let roots = folder.isEmpty ? next.count : ((try? fileSystem.entries(in: "").count) ?? 0)
        if roots != rootCount { rootCount = roots }

        var pruned = selection
        pruned.prune(to: next.map(\.path))
        if pruned != selection { selection = pruned }
        if let renamingPath, !next.contains(where: { $0.path == renamingPath }) {
            self.renamingPath = nil
        }
    }

    func open(_ target: String) {
        guard target.isEmpty || fileSystem.folderExists(target) else {
            post(TrayError.notFound(TrayPath.title(of: target)).localizedDescription, problem: true)
            refresh()
            return
        }
        if target != folder {
            folder = target
            selection.clear()
            renamingPath = nil
        }
        refresh()
    }

    func goUp() {
        guard !folder.isEmpty else { return }
        let previous = folder
        open(TrayPath.parent(of: folder))
        if entries.contains(where: { $0.path == previous }) {
            selection.replace(with: [previous])
        }
    }

    /// Files dropped on the tray, or tray items dropped on one of its folders. Copies of big
    /// files run off the main thread.
    @discardableResult
    func receive(_ urls: [URL], into target: String? = nil, mode: TrayDropMode? = nil) async -> TrayTransferReport {
        let destination = target ?? folder
        guard !urls.isEmpty else {
            post("只收文件和文件夹，这次什么也没放进来", problem: true)
            return TrayTransferReport()
        }
        let fileSystem = fileSystem
        let chosen = mode ?? dropMode
        importsInFlight += 1
        let report = await Task.detached(priority: .userInitiated) {
            fileSystem.importItems(urls, into: destination, mode: chosen)
        }.value
        importsInFlight -= 1
        finish(report, destination: destination)
        return report
    }

    @discardableResult
    func move(_ paths: [String], into target: String) -> TrayTransferReport {
        let report = fileSystem.move(paths, into: target)
        finish(report, destination: target)
        return report
    }

    /// `新建文件夹` in the current folder, selected and ready to be named.
    @discardableResult
    func createFolder() -> String? {
        do {
            let path = try fileSystem.createFolder(in: folder)
            refresh()
            selection.replace(with: [path])
            renamingPath = path
            return path
        } catch {
            post(TrayError.describe(error), problem: true)
            return nil
        }
    }

    /// Finder's "New Folder with Selection": gather `paths` into a fresh folder and name it.
    @discardableResult
    func groupIntoNewFolder(_ paths: [String]) -> String? {
        guard !paths.isEmpty else { return createFolder() }
        do {
            let path = try fileSystem.createFolder(in: folder)
            let report = fileSystem.move(paths, into: path)
            refresh()
            selection.replace(with: [path])
            renamingPath = path
            if !report.failures.isEmpty {
                post(report.summary(destination: TrayPath.name(of: path)), problem: true)
            }
            return path
        } catch {
            post(TrayError.describe(error), problem: true)
            return nil
        }
    }

    @discardableResult
    func rename(_ path: String, to name: String) -> Bool {
        do {
            let newPath = try fileSystem.rename(path, to: name)
            renamingPath = nil
            refresh()
            selection.replace(with: [newPath])
            return true
        } catch {
            post(TrayError.describe(error), problem: true)
            return false
        }
    }

    @discardableResult
    func delete(_ paths: [String]) -> TrayDeleteReport {
        let report = fileSystem.delete(paths)
        refresh()
        if !report.summary.isEmpty {
            post(report.summary, problem: !report.failures.isEmpty)
        }
        return report
    }

    /// What dropping onto `folder` would do. Pass nil `urls` from targets that only learn them at
    /// the drop (SwiftUI); during a drag out of the tray its paths stand in for them.
    func dropIntent(for urls: [URL]?, into folder: String, option: Bool, sourceAllowsMove: Bool = true) -> TrayDropIntent {
        let insidePaths: [String]?
        if let urls {
            let paths = urls.compactMap { fileSystem.relativePath(of: $0) }
            insidePaths = !urls.isEmpty && paths.count == urls.count ? paths : nil
        } else {
            insidePaths = isDraggingOut ? draggedPaths : nil
        }
        if let insidePaths {
            return .forTrayItems(insidePaths, into: folder)
        }
        return .forOutsideFiles(mode: dropMode, option: option, sourceAllowsMove: sourceAllowsMove)
    }

    func beginDragOut(_ paths: [String]) {
        draggedPaths = paths
        isDraggingOut = true
    }

    /// A drag out ended. Finder may finish the move a moment later, so look twice before saying
    /// how many came back. Drops inside the island already reported their own move.
    func finishDragOut(droppedOutside: Bool, operationWasCopy: Bool, cancelled: Bool) async {
        let paths = draggedPaths
        draggedPaths = []
        isDraggingOut = false
        refresh()
        guard droppedOutside, !cancelled, !paths.isEmpty else { return }
        for delay in [0.35, 1.2] {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            refresh()
            let reclaimed = paths.filter { !fileSystem.itemExists($0) }.count
            if reclaimed > 0 {
                post(reclaimed == paths.count ? "已拿回 \(reclaimed) 项" : "已拿回 \(reclaimed) 项，还有 \(paths.count - reclaimed) 项留在暂存区", problem: false)
                return
            }
        }
        if operationWasCopy {
            post("拷贝出去了，暂存区里还留着一份", problem: false)
        }
    }

    func dismissNotice(_ id: UUID) {
        if notice?.id == id { notice = nil }
    }

    func post(_ text: String, problem: Bool) {
        guard !text.isEmpty else { return }
        notice = TrayNotice(text: text, isProblem: problem)
    }

    private func finish(_ report: TrayTransferReport, destination: String) {
        refresh()
        let landedHere = report.arrived.filter { TrayPath.parent(of: $0) == folder }
        if destination == folder, !landedHere.isEmpty {
            selection.replace(with: landedHere)
        }
        post(
            report.summary(destination: TrayPath.title(of: destination)),
            problem: report.arrived.isEmpty && !report.failures.isEmpty
        )
    }
}
