import Foundation
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif

/// What the Cursor Cloud Agents client needs for one request.
struct CursorCredentials: Equatable, Sendable {
    var apiKey: String
    /// Empty means "pick a Grok model from `/v1/models`".
    var modelID: String
}

/// Reads and writes the Cursor API key and island preferences.
///
/// The key lives in a `0600` file under Application Support rather than the login
/// keychain: ad-hoc signed dev builds get a new code identity on every rebuild, and
/// each one would trigger a keychain access prompt.
struct IslandSettingsStorage: Sendable {
    static let defaultPRRepo = "leowang142857/GrokIsland"

    var folder: URL
    var defaultsSuite: String?

    init(folder: URL? = nil, defaultsSuite: String? = nil) {
        self.folder = folder ?? Self.defaultFolder
        self.defaultsSuite = defaultsSuite
    }

    static var defaultFolder: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return root.appendingPathComponent("GrokIsland", isDirectory: true)
    }

    private var keyURL: URL { folder.appendingPathComponent("cursor-api-key") }

    private var defaults: UserDefaults {
        defaultsSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    func loadAPIKey() -> String? {
        guard let data = try? Data(contentsOf: keyURL),
              let raw = String(data: data, encoding: .utf8)
        else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    func saveAPIKey(_ key: String?) throws {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fm = FileManager.default
        if trimmed.isEmpty {
            if fm.fileExists(atPath: keyURL.path) {
                try fm.removeItem(at: keyURL)
            }
            return
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(trimmed.utf8).write(to: keyURL, options: [.atomic])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
    }

    var prRepo: String {
        get {
            let value = defaults.string(forKey: "prRepo")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? Self.defaultPRRepo : value
        }
        nonmutating set { defaults.set(newValue, forKey: "prRepo") }
    }

    var grokModelID: String {
        get { defaults.string(forKey: "grokModelID")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        nonmutating set { defaults.set(newValue, forKey: "grokModelID") }
    }

    /// Keeps the island collapsed: hovering the peek strip no longer expands it.
    var isPeekLocked: Bool {
        get { defaults.bool(forKey: "peekLocked") }
        nonmutating set { defaults.set(newValue, forKey: "peekLocked") }
    }

    func credentials() -> CursorCredentials? {
        guard let key = loadAPIKey() else { return nil }
        return CursorCredentials(apiKey: key, modelID: grokModelID)
    }

    // MARK: - Island background

    static let backgroundImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "gif", "tif", "tiff", "webp", "bmp", "avif"
    ]
    static let maxBackgroundImageBytes: Int64 = 40 * 1_048_576

    /// Picked images are copied here, so moving or deleting the original does not break the island.
    var backgroundsFolder: URL { folder.appendingPathComponent("backgrounds", isDirectory: true) }

    var islandBackground: IslandBackgroundStyle {
        get {
            guard let data = defaults.data(forKey: "islandBackground"),
                  let style = try? JSONDecoder().decode(IslandBackgroundStyle.self, from: data)
            else { return .default }
            return style
        }
        nonmutating set {
            let data = try? JSONEncoder().encode(newValue.sanitized())
            defaults.set(data, forKey: "islandBackground")
        }
    }

    /// The copied image for `style`, or nil when it has none or the file is gone.
    func backgroundImageURL(for style: IslandBackgroundStyle) -> URL? {
        guard let name = style.imageFileName, IslandBackgroundStyle.isPlainFileName(name) else { return nil }
        let url = backgroundsFolder.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Copies `source` into the backgrounds folder under a fresh name and returns that name.
    func importBackgroundImage(from source: URL) throws -> String {
        let ext = source.pathExtension.lowercased()
        guard Self.backgroundImageExtensions.contains(ext) else {
            throw IslandBackgroundError.unsupportedFormat(ext)
        }
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: source.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular
        else { throw IslandBackgroundError.unreadable }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw IslandBackgroundError.unreadable }
        guard size <= Self.maxBackgroundImageBytes else { throw IslandBackgroundError.tooLarge(size) }

        try fm.createDirectory(at: backgroundsFolder, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString).\(ext)"
        try fm.copyItem(at: source, to: backgroundsFolder.appendingPathComponent(name))
        return name
    }

    /// Deletes every copied image except `fileName`.
    func pruneBackgroundImages(keeping fileName: String?) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: backgroundsFolder.path) else { return }
        for name in names where name != fileName {
            try? fm.removeItem(at: backgroundsFolder.appendingPathComponent(name))
        }
    }
}

/// Observable mirror of `IslandSettingsStorage` for the settings screen.
@MainActor
final class IslandSettings: ObservableObject {
    let storage: IslandSettingsStorage

    @Published private(set) var hasAPIKey: Bool
    @Published var prRepo: String {
        didSet { storage.prRepo = prRepo }
    }
    @Published var grokModelID: String {
        didSet { storage.grokModelID = grokModelID }
    }
    @Published var background: IslandBackgroundStyle {
        didSet {
            guard background != oldValue else { return }
            storage.islandBackground = background
        }
    }
    @Published var isPeekLocked: Bool {
        didSet { storage.isPeekLocked = isPeekLocked }
    }

    init(storage: IslandSettingsStorage = IslandSettingsStorage()) {
        self.storage = storage
        hasAPIKey = storage.loadAPIKey() != nil
        prRepo = storage.prRepo
        grokModelID = storage.grokModelID
        background = storage.islandBackground
        isPeekLocked = storage.isPeekLocked
    }

    var backgroundImageURL: URL? { storage.backgroundImageURL(for: background) }

    /// Copies the picked image into Application Support and switches the island to it.
    func importBackgroundImage(from url: URL) throws {
        let name = try storage.importBackgroundImage(from: url)
        var next = background
        next.kind = .image
        next.imageFileName = name
        background = next
        storage.pruneBackgroundImages(keeping: name)
    }

    /// Back to the stock aurora; the copied image is deleted.
    func resetBackground() {
        background = .default
        storage.pruneBackgroundImages(keeping: nil)
    }

    func saveAPIKey(_ key: String) throws {
        try storage.saveAPIKey(key)
        hasAPIKey = storage.loadAPIKey() != nil
    }

    func clearAPIKey() throws {
        try storage.saveAPIKey(nil)
        hasAPIKey = false
    }

    var credentials: CursorCredentials? { storage.credentials() }
}
