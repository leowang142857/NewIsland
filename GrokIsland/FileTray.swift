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

    static let privacyBlocked = "macOS 没放行：系统设置 → 隐私与安全性 → 文件与文件夹，给 NewIsland 打开"
    /// The file sits in another app's private container and that app gave no readable copy;
    /// no privacy setting for Desktop or Downloads changes that.
    static let sourceAppRefused = "来源 App 没交出可读文件（微信等）。请先存到桌面/文件夹，再拖进暂存"

    /// Like `describe(_:)`, for an error about `source`: a refusal inside another app's
    /// container is that app's doing, not the user's privacy settings.
    static func describe(_ error: Error, source: URL) -> String {
        if isPermission(error), TrayInbound.isOtherAppData(source) { return sourceAppRefused }
        return describe(error)
    }

    /// The system said no (sandbox, privacy protection or file permissions), as opposed to
    /// missing, full or broken.
    static func isPermission(_ error: Error) -> Bool {
        if let cocoa = error as? CocoaError {
            return cocoa.code == .fileReadNoPermission || cocoa.code == .fileWriteNoPermission
        }
        if let posix = error as? POSIXError { return posix.code == .EPERM || posix.code == .EACCES }
        return false
    }

    /// File-system errors in words a person would use.
    static func describe(_ error: Error) -> String {
        if let tray = error as? TrayError { return tray.localizedDescription }
        if let cocoa = error as? CocoaError {
            switch cocoa.code {
            case .fileWriteNoPermission, .fileReadNoPermission:
                return permissionReason(posix: posixCode(under: cocoa), reading: cocoa.code == .fileReadNoPermission)
            case .fileWriteOutOfSpace: return "磁盘空间不够"
            case .fileNoSuchFile, .fileReadNoSuchFile: return "找不到了"
            case .fileWriteFileExists: return "同名的已经存在"
            case .fileWriteVolumeReadOnly: return "那个磁盘是只读的"
            default: break
            }
        }
        if let posix = error as? POSIXError, [.EPERM, .EACCES].contains(posix.code) {
            return permissionReason(posix: posix.code, reading: false)
        }
        return error.localizedDescription
    }

    /// Gone, as opposed to there but off limits.
    static func isNoSuchFile(_ error: Error) -> Bool {
        if let cocoa = error as? CocoaError {
            return cocoa.code == .fileNoSuchFile || cocoa.code == .fileReadNoSuchFile
        }
        if let posix = error as? POSIXError { return posix.code == .ENOENT || posix.code == .ENOTDIR }
        return false
    }

    /// macOS wraps the system's answer. EPERM ("Operation not permitted") is the sandbox or privacy
    /// protection refusing, typically Desktop, Documents or Downloads touched without the access a
    /// drop grants or the app's own consent. EACCES is the file's own permissions.
    private static func permissionReason(posix: POSIXErrorCode?, reading: Bool) -> String {
        switch posix {
        case .EPERM?: privacyBlocked
        case .EACCES?: reading ? "没有读取它的权限" : "没有写入那里的权限"
        default: "没有权限"
        }
    }

    private static func posixCode(under error: CocoaError) -> POSIXErrorCode? {
        guard let underlying = error.underlying else { return nil }
        if let posix = underlying as? POSIXError { return posix.code }
        let ns = underlying as NSError
        guard ns.domain == NSPOSIXErrorDomain, let code = Int32(exactly: ns.code) else { return nil }
        return POSIXErrorCode(rawValue: code)
    }
}

/// Access to the files a drop handed over, held until the tray is done with them.
///
/// URLs read from a drag pasteboard can carry the access macOS grants for that one drop, as a
/// security-scoped resource. It has to be started while the drop is still being handled and kept
/// until the move or copy is done. Ending it early, or working from a URL rebuilt from a path or
/// from bytes, can fail with "Operation not permitted" for protected folders like Desktop and
/// Downloads, also with the app sandbox off.
///
/// So `urls` is the one list for both: access is started on exactly these values, and these same
/// values are what the tray moves or copies. Nothing may remap them in between (no
/// `standardizedFileURL`, `filePathURL` or path round trip before the file operation).
final class TrayDropAccess: @unchecked Sendable {
    /// The files to bring in, in drop order: real file paths, each the same value access was started
    /// on. A URL whose access did not start (a plain drop with nothing to start) is kept all the same.
    let urls: [URL]
    /// How many URLs access actually started for, for the log when a drop fails.
    let startedCount: Int
    private let lock = NSLock()
    private var held: [URL]
    /// The pasteboard's own URL objects, kept alive with the access they may carry.
    private var dropped: [URL]
    private let stop: @Sendable (URL) -> Void

    init(
        _ dropped: [URL],
        start: (URL) -> Bool = TrayDropAccess.startScoped,
        stop: @escaping @Sendable (URL) -> Void = TrayDropAccess.stopScoped
    ) {
        let files = dropped.filter(\.isFileURL)
        let urls = files.map(TrayInbound.filePath)
        // A file reference URL can carry access its path URL lacks, so start both.
        let replaced = zip(files, urls).compactMap { original, path in original == path ? nil : original }
        self.urls = urls
        held = (urls + replaced).filter(start)
        startedCount = held.count
        self.dropped = dropped
        self.stop = stop
    }

    /// Releases the access. Safe to call more than once; the last owner going away also ends it.
    func end() {
        lock.lock()
        let released = held
        held = []
        dropped = []
        lock.unlock()
        released.forEach(stop)
    }

    deinit { end() }

    static func startScoped(_ url: URL) -> Bool {
        #if os(macOS)
        return url.startAccessingSecurityScopedResource()
        #else
        return false
        #endif
    }

    @Sendable static func stopScoped(_ url: URL) {
        #if os(macOS)
        url.stopAccessingSecurityScopedResource()
        #endif
    }
}

/// File URLs handed over by a drop, in whatever shape the pasteboard used.
enum TrayInbound {
    /// Inside some app's private container (`~/Library/Containers/…`, `Group Containers`).
    /// Sandboxed apps such as WeChat drag files out from there, and other apps may not open them;
    /// the tray asks the source app for its own copy instead, and never moves such a file.
    static func isOtherAppData(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path.contains("/Library/Containers/") || path.contains("/Library/Group Containers/")
    }

    /// File URLs only, as real paths.
    static func fileURLs(_ urls: [URL]) -> [URL] {
        urls.filter(\.isFileURL).map(filePath)
    }

    /// The path URL for a file reference URL (`/.file/id=…`, which Finder can hand over). Any other
    /// URL comes back as the very same value, so access started on it still applies.
    static func filePath(_ url: URL) -> URL {
        #if canImport(Darwin)
        let reference = url as NSURL
        if reference.isFileReferenceURL(), let path = reference.filePathURL { return path }
        #endif
        return url
    }

    /// A `public.file-url` item as `NSItemProvider.loadItem` returns it: a URL, its data
    /// representation, or the URL or a plain path as text.
    static func fileURL(from item: Any?) -> URL? {
        let url: URL?
        switch item {
        case let value as URL:
            url = value
        case let data as Data:
            url = String(data: data, encoding: .utf8).flatMap(fileURL(fromText:))
                ?? URL(dataRepresentation: data, relativeTo: nil)
        case let text as String:
            url = fileURL(fromText: text)
        default:
            url = nil
        }
        guard let url, url.isFileURL else { return nil }
        return fileURLs([url]).first
    }

    private static func fileURL(fromText raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("/") { return URL(fileURLWithPath: text) }
        return URL(string: text)
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
    /// The dropped URL, for files from outside.
    var source: URL? = nil
    /// The system refused (`TrayError.isPermission`), so the source app may still hand it over.
    var isRefusal = false
}

/// A file from outside that has to be copied in: it is on another disk, the drop asked for a copy,
/// or moving it did not work.
struct TrayPendingCopy: Equatable, Sendable {
    var source: URL
    /// A move was asked for, so the report says the original stayed.
    var wantedMove: Bool
    /// The name to give it in the tray, when `source` is a stand-in such as a source app's temp copy.
    var name: String? = nil
}

/// What the app a drop came from handed over itself, already copied into the tray.
struct TraySourceResult: Sendable {
    var report = TrayTransferReport()
    /// Dropped URLs the source answered for; the rest are tried directly.
    var covered: Set<URL> = []
}

/// The app a drop came from, asked for its own copy of files the tray can't read through their
/// URLs: an item provider's file, a file promise, its bytes on the pasteboard. AppKit fills this
/// in during the drop; `fetch` runs afterwards and copies into the tray folder it is given.
struct TraySource: Sendable {
    /// The drop promised files with no URL to go with them; `fetch([], …)` brings those in.
    var promisesFilesOnly = false
    var fetch: @Sendable (_ urls: [URL], _ folder: String) async -> TraySourceResult
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
        var (report, copies) = moveIn(sources, into: folder, mode: mode)
        report.merge(copyIn(copies, into: folder))
        return report
    }

    /// The quick half of `importItems`: moves between tray folders and same-disk moves from
    /// outside, which are renames. Whatever has to be copied comes back for `copyIn`.
    func moveIn(_ sources: [URL], into folder: String, mode: TrayDropMode) -> (report: TrayTransferReport, copies: [TrayPendingCopy]) {
        var report = TrayTransferReport()
        if folder.isEmpty { try? ensureRoot() }
        guard let target = existingFolder(folder) else {
            report.failures = sources.map { TrayFailure(name: $0.lastPathComponent, reason: Self.missingFolder(folder)) }
            return (report, [])
        }

        var seen = Set<String>()
        var inside: [String] = []
        var copies: [TrayPendingCopy] = []
        for source in sources where source.isFileURL {
            // `source` itself goes to the file operations: it is the value a drop's access was
            // started on (see `TrayDropAccess`). The standardized copy is only for comparing.
            let key = source.standardizedFileURL
            guard seen.insert(key.path).inserted else { continue }
            if let path = relativePath(of: key) {
                inside.append(path)
                continue
            }
            let name = key.lastPathComponent
            guard !Self.isMissing(source) else {
                report.failures.append(TrayFailure(name: name, reason: "原文件找不到了"))
                continue
            }
            guard !swallowsTray(source) else {
                report.failures.append(TrayFailure(name: name, reason: TrayError.containsTray.localizedDescription))
                continue
            }
            // Never take a file out of another app's container: it is that app's working copy.
            let appData = TrayInbound.isOtherAppData(source)
            guard mode == .move, !appData, Self.sameVolume(source, target) else {
                copies.append(TrayPendingCopy(source: source, wantedMove: mode == .move && !appData))
                continue
            }

            let (destination, path) = landing(for: source, named: name, in: target, folder: folder)
            do {
                try FileManager.default.moveItem(at: source, to: destination)
                report.moved.append(path)
            } catch {
                Self.log("move \(source.path)", error)
                if Self.itemExists(at: destination) {
                    report.failures.append(Self.failure(name, source, error))
                } else {
                    // A locked original, or one macOS won't let go of, may still be copied.
                    copies.append(TrayPendingCopy(source: source, wantedMove: true))
                }
            }
        }
        if !inside.isEmpty {
            report.merge(move(inside, into: folder))
        }
        return (report, copies)
    }

    /// The slow half of `importItems`: copies, which take a while for big files.
    func copyIn(_ copies: [TrayPendingCopy], into folder: String) -> TrayTransferReport {
        var report = TrayTransferReport()
        guard !copies.isEmpty else { return report }
        guard let target = existingFolder(folder) else {
            report.failures = copies.map { TrayFailure(name: $0.source.lastPathComponent, reason: Self.missingFolder(folder)) }
            return report
        }
        let fm = FileManager.default
        for copy in copies {
            let name = copy.name ?? copy.source.standardizedFileURL.lastPathComponent
            let (destination, path) = landing(for: copy.source, named: name, in: target, folder: folder)
            do {
                try fm.copyItem(at: copy.source, to: destination)
                report.copied.append(path)
                if copy.wantedMove { report.keptOriginals += 1 }
            } catch {
                Self.log("copy \(copy.source.path)", error)
                try? fm.removeItem(at: destination)
                report.failures.append(Self.failure(name, copy.source, error))
            }
        }
        return report
    }

    /// A file the source app handed over in place of a dropped URL (an item provider's copy, a
    /// promised file), copied into `folder` as `name`. Call it while `provided` still exists: an
    /// item provider deletes its copy once the completion handler returns.
    func adopt(_ provided: URL, as name: String, into folder: String) -> TrayTransferReport {
        copyIn([TrayPendingCopy(source: provided, wantedMove: false, name: name)], into: folder)
    }

    private static func failure(_ name: String, _ source: URL, _ error: Error) -> TrayFailure {
        TrayFailure(
            name: name,
            reason: TrayError.describe(error, source: source),
            source: source,
            isRefusal: TrayError.isPermission(error)
        )
    }

    /// macOS's own error goes to the system log (Console: `GrokIsland FileTray`), so a refusal
    /// can be told apart from a missing grant after the fact.
    static func log(_ action: String, _ error: Error) {
        #if os(macOS)
        NSLog("GrokIsland FileTray: %@", "\(action) failed: \(error)")
        #endif
    }

    private func existingFolder(_ folder: String) -> URL? {
        guard let target = url(for: folder), Self.isFolder(at: target) else { return nil }
        return target
    }

    private static func missingFolder(_ folder: String) -> String {
        TrayError.notFound(TrayPath.title(of: folder)).localizedDescription
    }

    /// Where `original` lands in `target`, numbered Finder-style if the name is taken.
    private func landing(for original: URL, named name: String, in target: URL, folder: String) -> (url: URL, path: String) {
        let finalName = TrayNaming.uniqueName(name, isFolder: Self.isFolder(at: original)) {
            Self.itemExists(at: target.appendingPathComponent($0))
        }
        return (target.appendingPathComponent(finalName), TrayPath.join(folder, finalName))
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

    /// Really gone. A folder on the way that may not be read makes even looking the item up fail;
    /// that is left to the move or copy, which says why.
    static func isMissing(_ url: URL) -> Bool {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
            return false
        } catch {
            return TrayError.isNoSuchFile(error)
        }
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

    /// Files dropped on the tray, or tray items dropped on one of its folders.
    ///
    /// Call it from the drop callback itself. Renames (tray moves, same-disk moves from Finder)
    /// are done before it returns, while the access that came with the drop is certainly valid.
    /// Copies continue off the main thread, and the access is held until the last one is done.
    /// The files are `drop.urls` and nothing else, so they are the values access was started on.
    ///
    /// With a `source`, files in another app's container are asked of that app first, and anything
    /// the system refuses to copy is asked of it afterwards. What it can't hand over either keeps
    /// the direct attempt's reason.
    @discardableResult
    func take(_ drop: TrayDropAccess, into target: String? = nil, mode: TrayDropMode? = nil, source: TraySource? = nil) -> Task<TrayTransferReport, Never> {
        let destination = target ?? folder
        guard !drop.urls.isEmpty || source?.promisesFilesOnly == true else {
            drop.end()
            post("只收文件和文件夹，这次什么也没放进来", problem: true)
            return Task { TrayTransferReport() }
        }
        let chosen = mode ?? dropMode
        let askFirst = source == nil ? [] : drop.urls.filter {
            TrayInbound.isOtherAppData($0) && self.fileSystem.relativePath(of: $0.standardizedFileURL) == nil
        }
        let direct = drop.urls.filter { !askFirst.contains($0) }
        let (renamed, copies) = fileSystem.moveIn(direct, into: destination, mode: chosen)
        guard !copies.isEmpty || !askFirst.isEmpty || source?.promisesFilesOnly == true else {
            drop.end()
            finish(renamed, destination: destination, drop: drop)
            return Task { renamed }
        }
        if !renamed.arrived.isEmpty { refresh() }
        let fileSystem = fileSystem
        importsInFlight += 1
        return Task {
            defer { drop.end() }
            var report = renamed
            var pending = copies
            if let source, !askFirst.isEmpty || source.promisesFilesOnly {
                let handed = await source.fetch(askFirst, destination)
                report.merge(handed.report)
                if source.promisesFilesOnly, handed.report.arrived.isEmpty, handed.report.failures.isEmpty {
                    report.failures.append(TrayFailure(name: "拖来的文件", reason: TrayError.sourceAppRefused))
                }
                pending += askFirst.filter { !handed.covered.contains($0) }.map {
                    TrayPendingCopy(source: $0, wantedMove: false)
                }
            }
            var copied = await Task.detached(priority: .userInitiated) {
                fileSystem.copyIn(pending, into: destination)
            }.value
            let refused = copied.failures.compactMap { $0.isRefusal ? $0.source : nil }.filter { !askFirst.contains($0) }
            if let source, !refused.isEmpty {
                let handed = await source.fetch(refused, destination)
                copied.failures.removeAll { $0.source.map(handed.covered.contains) ?? false }
                copied.merge(handed.report)
            }
            report.merge(copied)
            importsInFlight -= 1
            finish(report, destination: destination, drop: drop)
            return report
        }
    }

    @discardableResult
    func receive(_ urls: [URL], into target: String? = nil, mode: TrayDropMode? = nil) async -> TrayTransferReport {
        await take(TrayDropAccess(urls), into: target, mode: mode).value
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

    private func finish(_ report: TrayTransferReport, destination: String, drop: TrayDropAccess? = nil) {
        if let drop, !report.failures.isEmpty {
            TrayFileSystem.log(
                "drop of \(drop.urls.count) (access started for \(drop.startedCount))",
                TrayError.failed(report.failures.map { "\($0.name): \($0.reason)" }.joined(separator: "; "))
            )
        }
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
