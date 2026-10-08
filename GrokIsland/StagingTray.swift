import Foundation
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif

/// How a drop enters the tray.
///
/// Copy is the default. A move happens only when the user asked for one and the
/// source is on the Desktop. Anything else stays a copy, so originals are never
/// removed silently.
enum StagingImportMode: String, Codable, Equatable, Sendable {
    case copy
    case move
}

enum StagingNodeKind: String, Codable, Equatable, Sendable {
    /// A folder created inside the tray to group items. It has no source file.
    case category
    case file
    case directory
}

struct StagingNode: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var kind: StagingNodeKind
    /// `nil` is the tray root.
    var parentID: UUID?
    /// Path under the tray root, using `/`. Nil for categories.
    var storageRelativePath: String?
    var sourceLocation: String?
    var importedAs: StagingImportMode?
    var byteCount: Int64?
    var createdAt: Date
    var updatedAt: Date

    var isCategory: Bool { kind == .category }
}

struct StagingImportResult: Equatable, Sendable {
    var node: StagingNode
    var mode: StagingImportMode
    /// The user asked to move, but the source was not on the Desktop.
    var keptOriginalBecauseNotOnDesktop: Bool
    /// A Desktop move copied, then deleting the original failed or was refused.
    /// The staged copy is kept and the original is still in place.
    var originalDeleteFailed: Bool
}

enum StagingError: Error, Equatable, LocalizedError {
    case nameEmpty
    case nodeNotFound
    case notACategory
    case cannotMoveIntoSelf
    case cycle
    case sourceMissing
    case confirmationRequired
    case notExportable
    case destinationNotADirectory
    case refusesDesktopFolder
    case alreadyInTray
    case nothingToStage
    case persistenceFailed(String)
    case fileOperationFailed(String)

    var errorDescription: String? {
        switch self {
        case .nameEmpty:
            return "名字不能是空的。"
        case .nodeNotFound:
            return "这条暂存已经不在了。"
        case .notACategory:
            return "只能放进文件夹。"
        case .cannotMoveIntoSelf:
            return "不能把文件夹放进它自己。"
        case .cycle:
            return "不能把文件夹放进它里面的子文件夹。"
        case .sourceMissing:
            return "原文件找不到了。"
        case .confirmationRequired:
            return "删除暂存副本前需要确认。"
        case .notExportable:
            return "这个暂存没有可以拖出去的文件。"
        case .destinationNotADirectory:
            return "只能放到文件夹里。"
        case .refusesDesktopFolder:
            return "不能把整个桌面放进暂存。"
        case .alreadyInTray:
            return "它已经在暂存托盘里了。"
        case .nothingToStage:
            return "没读到可以暂存的文件或文件夹。"
        case .persistenceFailed(let message):
            return "暂存目录没能保存：\(message)"
        case .fileOperationFailed(let message):
            return message
        }
    }
}

/// Pure rules for "is this the Desktop?" and "copy or move?".
enum StagingIntakePolicy {
    static func mode(sourceIsOnDesktop: Bool, moveRequested: Bool) -> StagingImportMode {
        sourceIsOnDesktop && moveRequested ? .move : .copy
    }

    /// True when `source` lives inside the desktop directory. The desktop folder
    /// itself is not a file sitting on the Desktop.
    static func isOnDesktop(source: URL, desktopDirectory: URL) -> Bool {
        let sourcePath = standardizedPath(source)
        let desktopPath = standardizedPath(desktopDirectory)
        guard sourcePath != desktopPath else { return false }
        return hasPrefix(sourcePath, directory: desktopPath)
    }

    /// A move may delete this path only when it is a real item inside the Desktop,
    /// never the Desktop folder, the home folder, or the filesystem root.
    static func isSafeRemovalTarget(_ url: URL, desktopDirectory: URL) -> Bool {
        let path = standardizedPath(url)
        if path == "/" { return false }
        let home = standardizedPath(URL(fileURLWithPath: NSHomeDirectory()))
        if path == home { return false }
        let desktop = standardizedPath(desktopDirectory)
        if path == desktop { return false }
        return isOnDesktop(source: url, desktopDirectory: desktopDirectory)
    }

    static func standardizedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// `items/<uuid>/…` and `export-cache/<uuid>/…` both belong to that node.
    static func nodeID(inTrayPath path: String, rootPath: String) -> UUID? {
        let root = rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath
        guard hasPrefix(path, directory: root) else { return nil }
        let rest = path.dropFirst(root.count + 1)
        let parts = rest.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        guard parts[0] == "items" || parts[0] == "export-cache" else { return nil }
        return UUID(uuidString: parts[1])
    }

    static func sanitizedName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        guard !name.contains("/"), !name.contains("\0") else { return nil }
        return name
    }

    /// `notes.txt` then `notes 2.txt`. Folders keep the whole name as the base.
    static func uniqueName(_ name: String, isDirectory: Bool, existing: Set<String>) -> String {
        if !existing.contains(name) { return name }
        let base: String
        let ext: String
        if isDirectory {
            base = name
            ext = ""
        } else if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            base = String(name[..<dot])
            ext = String(name[name.index(after: dot)...])
        } else {
            base = name
            ext = ""
        }
        var index = 2
        while index < 10_000 {
            let candidate = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            if !existing.contains(candidate) { return candidate }
            index += 1
        }
        return ext.isEmpty ? "\(base) \(UUID().uuidString)" : "\(base) \(UUID().uuidString).\(ext)"
    }

    static func hasPrefix(_ path: String, directory: String) -> Bool {
        let prefix = directory.hasSuffix("/") ? directory : directory + "/"
        #if os(macOS)
        return path.range(of: prefix, options: [.anchored, .caseInsensitive]) != nil
        #else
        return path.hasPrefix(prefix)
        #endif
    }
}

/// Compares a staged copy with its source before any original is removed.
enum StagingFileCheck {
    static func copyIsComplete(source: URL, destination: URL, fileManager: FileManager = .default) -> Bool {
        var sourceDir: ObjCBool = false
        var destDir: ObjCBool = false
        let sourceExists = fileManager.fileExists(atPath: source.path, isDirectory: &sourceDir)
        let destExists = fileManager.fileExists(atPath: destination.path, isDirectory: &destDir)
        guard sourceExists, destExists, sourceDir.boolValue == destDir.boolValue else { return false }
        if sourceDir.boolValue {
            return entryCount(destination, fileManager: fileManager) == entryCount(source, fileManager: fileManager)
        }
        guard let sourceSize = fileSize(at: source, fileManager: fileManager),
              let destSize = fileSize(at: destination, fileManager: fileManager) else {
            return false
        }
        return sourceSize == destSize
    }

    static func fileSize(at url: URL, fileManager: FileManager = .default) -> Int64? {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path) else { return nil }
        if let number = attrs[.size] as? NSNumber { return number.int64Value }
        if let int = attrs[.size] as? Int64 { return int }
        if let int = attrs[.size] as? Int { return Int64(int) }
        if let int = attrs[.size] as? UInt64 { return Int64(int) }
        return nil
    }

    static func entryCount(_ url: URL, fileManager: FileManager = .default) -> Int {
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: nil) else { return 0 }
        var count = 0
        for _ in enumerator { count += 1 }
        return count
    }
}

enum StagingStatus {
    static func note(imported: [StagingImportResult], movedExisting: Int, failures: Int) -> String {
        let moved = imported.filter { $0.mode == .move && !$0.originalDeleteFailed }.count
        let copied = imported.filter { $0.mode == .copy && !$0.keptOriginalBecauseNotOnDesktop }.count
        let kept = imported.filter(\.keptOriginalBecauseNotOnDesktop).count
        let deleteFailed = imported.filter(\.originalDeleteFailed).count
        var parts: [String] = []
        if copied > 0 { parts.append("复制 \(copied) 个，原文件还在") }
        if moved > 0 { parts.append("从桌面移入 \(moved) 个") }
        if kept > 0 { parts.append("\(kept) 个不在桌面，所以只复制") }
        if deleteFailed > 0 { parts.append("\(deleteFailed) 个移不走，原文件还在") }
        if movedExisting > 0 { parts.append("移动 \(movedExisting) 个到当前文件夹") }
        if failures > 0 { parts.append("\(failures) 个没放进来") }
        return parts.joined(separator: "，")
    }
}

/// Payload prefix for an in-island drag. File drags out to Finder use a real file URL.
enum StagingDrag {
    static let prefix = "grok-island-stage:"

    static func payload(for id: UUID) -> String {
        prefix + id.uuidString
    }

    static func nodeID(in string: String) -> UUID? {
        guard string.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(string.dropFirst(prefix.count)))
    }
}

private struct StagingCatalog: Codable, Equatable {
    var nodes: [StagingNode]
}

/// App-managed copies under Application Support. The catalog is JSON; bytes live in `items/<id>/`.
///
/// Removing a staged copy requires `confirmed: true`. Dragging out exports a separate copy
/// (or a hard link in the export cache) and leaves the tray item in place.
@MainActor
final class StagingTrayStore: ObservableObject {
    @Published private(set) var nodes: [StagingNode] = []
    /// When true, Desktop items are moved after a verified copy. Everything else is still copied.
    @Published var moveFromDesktop = false
    @Published var statusNote: String?
    @Published var lastError: String?

    let rootURL: URL
    private let catalogURL: URL
    private let desktopDirectory: URL
    private let fileManager: FileManager
    private let deleteOriginal: (URL) throws -> Void
    private let copyIsComplete: (URL, URL) -> Bool
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        rootURL: URL? = nil,
        desktopDirectory: URL? = nil,
        fileManager: FileManager = .default,
        deleteOriginal: ((URL) throws -> Void)? = nil,
        copyIsComplete: ((URL, URL) -> Bool)? = nil
    ) {
        let root = rootURL ?? Self.defaultRootURL
        self.rootURL = root
        self.catalogURL = root.appendingPathComponent("catalog.json")
        self.desktopDirectory = desktopDirectory ?? Self.defaultDesktopDirectory()
        self.fileManager = fileManager
        self.deleteOriginal = deleteOriginal ?? { try fileManager.removeItem(at: $0) }
        self.copyIsComplete = copyIsComplete ?? { StagingFileCheck.copyIsComplete(source: $0, destination: $1, fileManager: fileManager) }
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        nodes = loadFromDisk()
    }

    static var defaultRootURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return support
            .appendingPathComponent("GrokIsland", isDirectory: true)
            .appendingPathComponent("staging", isDirectory: true)
    }

    static func defaultDesktopDirectory() -> URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop", isDirectory: true)
    }

    /// Files and staged folders. Empty categories do not count.
    var stagedItemCount: Int {
        nodes.filter { !$0.isCategory }.count
    }

    func node(id: UUID) -> StagingNode? {
        nodes.first { $0.id == id }
    }

    func children(of parentID: UUID?) -> [StagingNode] {
        nodes.filter { $0.parentID == parentID }.sorted { lhs, rhs in
            if lhs.isCategory != rhs.isCategory { return lhs.isCategory }
            let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if order == .orderedSame { return lhs.createdAt < rhs.createdAt }
            return order == .orderedAscending
        }
    }

    func categories(excluding id: UUID? = nil) -> [StagingNode] {
        let blocked = id.map { descendantIDs(of: $0).union([$0]) } ?? []
        return nodes.filter { $0.isCategory && !blocked.contains($0.id) }.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func report(_ error: Error) {
        statusNote = nil
        lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    @discardableResult
    func createFolder(name: String, in parentID: UUID?) throws -> StagingNode {
        let cleaned = try validatedName(name)
        try ensureCategory(parentID)
        let now = Date()
        let node = StagingNode(
            id: UUID(),
            name: cleaned,
            kind: .category,
            parentID: parentID,
            storageRelativePath: nil,
            sourceLocation: nil,
            importedAs: nil,
            byteCount: nil,
            createdAt: now,
            updatedAt: now
        )
        nodes.append(node)
        do {
            try persist()
        } catch {
            nodes.removeAll { $0.id == node.id }
            throw error
        }
        lastError = nil
        return node
    }

    @discardableResult
    func rename(id: UUID, to name: String) throws -> StagingNode {
        let cleaned = try validatedName(name)
        guard let index = nodes.firstIndex(where: { $0.id == id }) else {
            throw StagingError.nodeNotFound
        }
        var next = nodes[index]
        let previous = next
        if next.kind != .category, let relative = next.storageRelativePath, let currentURL = url(forRelativePath: relative) {
            let folder = currentURL.deletingLastPathComponent()
            let renamed = folder.appendingPathComponent(cleaned)
            if renamed.path != currentURL.path {
                if fileManager.fileExists(atPath: renamed.path) {
                    throw StagingError.fileOperationFailed("这个文件夹里已经有同名文件。")
                }
                do {
                    try fileManager.moveItem(at: currentURL, to: renamed)
                } catch {
                    throw StagingError.fileOperationFailed(error.localizedDescription)
                }
                next.storageRelativePath = relativePath(for: renamed)
            }
        }
        next.name = cleaned
        next.updatedAt = Date()
        nodes[index] = next
        do {
            try persist()
        } catch {
            if let oldURL = previous.storageRelativePath.flatMap({ url(forRelativePath: $0) }),
               let newURL = next.storageRelativePath.flatMap({ url(forRelativePath: $0) }),
               oldURL.path != newURL.path,
               fileManager.fileExists(atPath: newURL.path) {
                try? fileManager.moveItem(at: newURL, to: oldURL)
            }
            nodes[index] = previous
            throw error
        }
        lastError = nil
        return next
    }

    func move(id: UUID, into parentID: UUID?) throws {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else {
            throw StagingError.nodeNotFound
        }
        if nodes[index].parentID == parentID { return }
        try ensureCategory(parentID)
        if let parentID {
            if parentID == id { throw StagingError.cannotMoveIntoSelf }
            if descendantIDs(of: id).contains(parentID) { throw StagingError.cycle }
        }
        var next = nodes[index]
        let previous = next
        next.parentID = parentID
        next.updatedAt = Date()
        nodes[index] = next
        do {
            try persist()
        } catch {
            nodes[index] = previous
            throw error
        }
        lastError = nil
    }

    /// Stage file and folder URLs into `parentID` (nil is the tray root).
    /// A URL that already belongs to this tray is moved, not copied again.
    @discardableResult
    func stage(urls: [URL], into parentID: UUID?) throws -> [StagingImportResult] {
        try ensureCategory(parentID)
        let fileURLs = urls.filter { $0.isFileURL }
        guard !fileURLs.isEmpty else { throw StagingError.nothingToStage }

        var imported: [StagingImportResult] = []
        var movedExisting = 0
        var failures: [Error] = []

        for url in fileURLs {
            do {
                if let existing = nodeID(forTrayURL: url) {
                    let alreadyThere = node(id: existing)?.parentID == parentID
                    try move(id: existing, into: parentID)
                    if !alreadyThere { movedExisting += 1 }
                    continue
                }
                imported.append(try importOne(url, into: parentID))
            } catch {
                failures.append(error)
            }
        }

        if imported.isEmpty, movedExisting == 0, let error = failures.first {
            report(error)
            throw error
        }

        lastError = failures.first.flatMap { ($0 as? LocalizedError)?.errorDescription ?? $0.localizedDescription }
        let note = StagingStatus.note(imported: imported, movedExisting: movedExisting, failures: failures.count)
        statusNote = note.isEmpty ? nil : note
        return imported
    }

    /// Deletes the staged copies. Does nothing to originals that were only copied.
    /// `confirmed` must be true; the UI asks first.
    func remove(id: UUID, confirmed: Bool) throws {
        guard confirmed else { throw StagingError.confirmationRequired }
        guard nodes.contains(where: { $0.id == id }) else { throw StagingError.nodeNotFound }
        let ids = descendantIDs(of: id).union([id])
        let previous = nodes
        let doomed = nodes.filter { ids.contains($0.id) }
        nodes.removeAll { ids.contains($0.id) }
        do {
            try persist()
        } catch {
            nodes = previous
            throw error
        }
        for node in doomed {
            if let folder = itemDirectory(for: node), fileManager.fileExists(atPath: folder.path) {
                try? fileManager.removeItem(at: folder)
            }
            let cache = rootURL
                .appendingPathComponent("export-cache", isDirectory: true)
                .appendingPathComponent(node.id.uuidString, isDirectory: true)
            if fileManager.fileExists(atPath: cache.path) {
                try? fileManager.removeItem(at: cache)
            }
        }
        lastError = nil
    }

    /// Canonical staged file or folder. Categories have none.
    func storedFileURL(for id: UUID) -> URL? {
        guard let node = node(id: id), let relative = node.storageRelativePath else { return nil }
        return url(forRelativePath: relative)
    }

    /// A disposable copy (files prefer a hard link) under `export-cache`.
    /// Finder can move or copy this URL; the catalogued bytes stay put.
    func exportURL(for id: UUID) throws -> URL {
        guard node(id: id) != nil else { throw StagingError.nodeNotFound }
        let cache = rootURL
            .appendingPathComponent("export-cache", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        if fileManager.fileExists(atPath: cache.path) {
            try? fileManager.removeItem(at: cache)
        }
        try fileManager.createDirectory(at: cache, withIntermediateDirectories: true)
        return try exportCopy(of: id, to: cache, preferLink: true)
    }

    /// Copies the item (or a category and its children) into `directory`. The tray is unchanged.
    @discardableResult
    func exportCopy(of id: UUID, to directory: URL) throws -> URL {
        try exportCopy(of: id, to: directory, preferLink: false)
    }

    func reload() {
        nodes = loadFromDisk()
    }

    // MARK: - Import

    private func importOne(_ url: URL, into parentID: UUID?) throws -> StagingImportResult {
        let source = url.standardizedFileURL
        guard fileManager.fileExists(atPath: source.path) else { throw StagingError.sourceMissing }
        let sourcePath = StagingIntakePolicy.standardizedPath(source)
        let rootPath = StagingIntakePolicy.standardizedPath(rootURL)
        if sourcePath == rootPath || StagingIntakePolicy.hasPrefix(sourcePath, directory: rootPath) {
            throw StagingError.alreadyInTray
        }
        let desktopPath = StagingIntakePolicy.standardizedPath(desktopDirectory)
        if sourcePath == desktopPath {
            throw StagingError.refusesDesktopFolder
        }

        guard let name = StagingIntakePolicy.sanitizedName(source.lastPathComponent) else {
            throw StagingError.nameEmpty
        }
        var isDirectory: ObjCBool = false
        fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory)
        let onDesktop = StagingIntakePolicy.isOnDesktop(source: source, desktopDirectory: desktopDirectory)
        let mode = StagingIntakePolicy.mode(sourceIsOnDesktop: onDesktop, moveRequested: moveFromDesktop)
        let keptBecauseNotDesktop = moveFromDesktop && !onDesktop

        let id = UUID()
        let itemFolder = rootURL
            .appendingPathComponent("items", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: itemFolder, withIntermediateDirectories: true)
        let destination = itemFolder.appendingPathComponent(name)
        do {
            try fileManager.copyItem(at: source, to: destination)
        } catch {
            try? fileManager.removeItem(at: itemFolder)
            throw StagingError.fileOperationFailed(error.localizedDescription)
        }

        let now = Date()
        let node = StagingNode(
            id: id,
            name: name,
            kind: isDirectory.boolValue ? .directory : .file,
            parentID: parentID,
            storageRelativePath: "items/\(id.uuidString)/\(name)",
            sourceLocation: source.path,
            importedAs: mode,
            byteCount: isDirectory.boolValue ? nil : StagingFileCheck.fileSize(at: destination, fileManager: fileManager),
            createdAt: now,
            updatedAt: now
        )
        nodes.append(node)
        do {
            try persist()
        } catch {
            nodes.removeAll { $0.id == id }
            try? fileManager.removeItem(at: itemFolder)
            throw error
        }

        var deleteFailed = false
        if mode == .move {
            let complete = copyIsComplete(source, destination)
            let safe = StagingIntakePolicy.isSafeRemovalTarget(source, desktopDirectory: desktopDirectory)
            if complete, safe {
                do {
                    try deleteOriginal(source)
                } catch {
                    deleteFailed = true
                }
            } else {
                deleteFailed = true
            }
        }

        return StagingImportResult(
            node: node,
            mode: mode,
            keptOriginalBecauseNotOnDesktop: keptBecauseNotDesktop,
            originalDeleteFailed: deleteFailed
        )
    }

    private func exportCopy(of id: UUID, to directory: URL, preferLink: Bool) throws -> URL {
        guard let node = node(id: id) else { throw StagingError.nodeNotFound }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw StagingError.destinationNotADirectory
        }
        switch node.kind {
        case .file, .directory:
            guard let source = storedFileURL(for: id), fileManager.fileExists(atPath: source.path) else {
                throw StagingError.notExportable
            }
            let dest = uniqueURL(in: directory, name: node.name, isDirectory: node.kind == .directory)
            if preferLink, node.kind == .file {
                do {
                    try fileManager.linkItem(at: source, to: dest)
                    return dest
                } catch {
                    try fileManager.copyItem(at: source, to: dest)
                    return dest
                }
            }
            try fileManager.copyItem(at: source, to: dest)
            return dest
        case .category:
            let dest = uniqueURL(in: directory, name: node.name, isDirectory: true)
            try fileManager.createDirectory(at: dest, withIntermediateDirectories: true)
            for child in children(of: node.id) {
                _ = try exportCopy(of: child.id, to: dest, preferLink: false)
            }
            return dest
        }
    }

    // MARK: - Paths and catalog

    private func uniqueURL(in directory: URL, name: String, isDirectory: Bool) -> URL {
        let existing = Set((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [])
        let final = StagingIntakePolicy.uniqueName(name, isDirectory: isDirectory, existing: existing)
        return directory.appendingPathComponent(final)
    }

    private func nodeID(forTrayURL url: URL) -> UUID? {
        StagingIntakePolicy.nodeID(
            inTrayPath: StagingIntakePolicy.standardizedPath(url),
            rootPath: StagingIntakePolicy.standardizedPath(rootURL)
        ).flatMap { id in nodes.contains(where: { $0.id == id }) ? id : nil }
    }

    /// `items/<uuid>` only. Never a parent of every staged file.
    private func itemDirectory(for node: StagingNode) -> URL? {
        guard let relative = node.storageRelativePath else { return nil }
        let parts = relative.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts[0] == "items", UUID(uuidString: parts[1]) != nil else { return nil }
        return rootURL.appendingPathComponent("items", isDirectory: true).appendingPathComponent(parts[1], isDirectory: true)
    }

    private func url(forRelativePath relative: String) -> URL? {
        let parts = relative.split(separator: "/").map(String.init)
        guard !relative.hasPrefix("/"), !parts.contains(".."), !parts.contains(".") else { return nil }
        return parts.reduce(rootURL) { $0.appendingPathComponent($1) }
    }

    private func relativePath(for url: URL) -> String? {
        let root = StagingIntakePolicy.standardizedPath(rootURL)
        let path = StagingIntakePolicy.standardizedPath(url)
        guard StagingIntakePolicy.hasPrefix(path, directory: root) else { return nil }
        return String(path.dropFirst(root.count + 1))
    }

    private func descendantIDs(of id: UUID) -> Set<UUID> {
        var result: Set<UUID> = []
        var queue = nodes.filter { $0.parentID == id }.map(\.id)
        while let next = queue.popLast() {
            if !result.insert(next).inserted { continue }
            queue.append(contentsOf: nodes.filter { $0.parentID == next }.map(\.id))
        }
        return result
    }

    private func ensureCategory(_ parentID: UUID?) throws {
        guard let parentID else { return }
        guard let parent = node(id: parentID), parent.isCategory else { throw StagingError.notACategory }
    }

    private func validatedName(_ raw: String) throws -> String {
        guard let name = StagingIntakePolicy.sanitizedName(raw) else { throw StagingError.nameEmpty }
        return name
    }

    private func persist() throws {
        do {
            if !fileManager.fileExists(atPath: rootURL.path) {
                try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            }
            let data = try encoder.encode(StagingCatalog(nodes: nodes))
            try data.write(to: catalogURL, options: [.atomic])
        } catch let error as StagingError {
            throw error
        } catch {
            throw StagingError.persistenceFailed(error.localizedDescription)
        }
    }

    private func loadFromDisk() -> [StagingNode] {
        guard fileManager.fileExists(atPath: catalogURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: catalogURL)
            return try decoder.decode(StagingCatalog.self, from: data).nodes
        } catch {
            return []
        }
    }
}
