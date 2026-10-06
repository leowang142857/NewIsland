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

/// Reads and writes provider API keys and island preferences.
///
/// Keys live in `0600` files under Application Support rather than the login
/// keychain: ad-hoc signed dev builds get a new code identity on every rebuild, and
/// each one would trigger a keychain access prompt. Keys are never written to logs.
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

    private var defaults: UserDefaults {
        defaultsSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    func loadAPIKey() -> String? {
        loadAPIKey(for: .cursor)
    }

    func saveAPIKey(_ key: String?) throws {
        try saveAPIKey(key, for: .cursor)
    }

    func loadAPIKey(for kind: ModelProviderKind) -> String? {
        let url = folder.appendingPathComponent(kind.secretFileName)
        guard let data = try? Data(contentsOf: url),
              let raw = String(data: data, encoding: .utf8)
        else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    func saveAPIKey(_ key: String?, for kind: ModelProviderKind) throws {
        try writeSecret(key, to: folder.appendingPathComponent(kind.secretFileName))
    }

    private func writeSecret(_ key: String?, to url: URL) throws {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fm = FileManager.default
        if trimmed.isEmpty {
            if fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
            }
            return
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(trimmed.utf8).write(to: url, options: [.atomic])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
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

    // MARK: - Model provider

    /// Nil until the user picks a provider in Settings. An older install with only a Cursor key
    /// stays on Cursor without this being written.
    var storedProviderKind: ModelProviderKind? {
        get {
            guard let raw = defaults.string(forKey: "modelProvider") else { return nil }
            return ModelProviderKind(rawValue: raw)
        }
        nonmutating set {
            if let newValue {
                defaults.set(newValue.rawValue, forKey: "modelProvider")
            } else {
                defaults.removeObject(forKey: "modelProvider")
            }
        }
    }

    /// Explicit choice, otherwise Cursor when that key is already on disk, otherwise xAI as the suggested default.
    var resolvedProviderKind: ModelProviderKind {
        if let storedProviderKind { return storedProviderKind }
        if loadAPIKey(for: .cursor) != nil { return .cursor }
        return .xai
    }

    func modelID(for kind: ModelProviderKind) -> String {
        if kind == .cursor { return grokModelID }
        let stored = defaults.string(forKey: "modelID.\(kind.rawValue)")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? kind.defaultModel : stored
    }

    func setModelID(_ value: String, for kind: ModelProviderKind) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .cursor {
            grokModelID = trimmed
            return
        }
        let key = "modelID.\(kind.rawValue)"
        if trimmed.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(trimmed, forKey: key)
        }
    }

    func baseURLString(for kind: ModelProviderKind) -> String {
        guard kind.allowsCustomBaseURL else { return kind.defaultBaseURL }
        let stored = defaults.string(forKey: "baseURL.\(kind.rawValue)")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? kind.defaultBaseURL : stored
    }

    func setBaseURLString(_ value: String, for kind: ModelProviderKind) {
        guard kind.allowsCustomBaseURL else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = "baseURL.\(kind.rawValue)"
        if trimmed.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(trimmed, forKey: key)
        }
    }

    func resolveProvider() -> ModelProviderResolution {
        let kind = resolvedProviderKind
        return ModelProviderResolution(
            kind: kind,
            isExplicit: storedProviderKind != nil,
            configuration: makeConfiguration(for: kind)
        )
    }

    func makeConfiguration(for kind: ModelProviderKind) -> ModelProviderConfiguration? {
        let key = loadAPIKey(for: kind) ?? ""
        if kind.requiresAPIKey && key.isEmpty { return nil }
        let model = modelID(for: kind)
        if kind != .cursor && model.isEmpty { return nil }
        guard let baseURL = ModelEndpoint.normalizedBaseURL(baseURLString(for: kind)) else { return nil }
        return ModelProviderConfiguration(kind: kind, apiKey: key, model: model, baseURL: baseURL)
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

    /// The three expanded-island shortcut buttons. Missing or corrupt data is the built-in trio.
    var islandShortcutButtons: IslandShortcutButtons {
        get {
            guard let data = defaults.data(forKey: "islandShortcutButtons"),
                  !data.isEmpty,
                  let buttons = try? JSONDecoder().decode(IslandShortcutButtons.self, from: data)
            else { return .default }
            return buttons.sanitized()
        }
        nonmutating set {
            let data = try? JSONEncoder().encode(newValue.sanitized())
            defaults.set(data, forKey: "islandShortcutButtons")
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
    @Published private(set) var hasSelectedAPIKey: Bool
    @Published private(set) var isModelReady: Bool
    @Published var providerKind: ModelProviderKind {
        didSet {
            guard providerKind != oldValue else { return }
            storage.storedProviderKind = providerKind
            let nextModel = storage.modelID(for: providerKind == .cursor ? .xai : providerKind)
            if providerModelID != nextModel {
                providerModelID = nextModel
            }
            let nextBase = storage.baseURLString(for: providerKind)
            if endpointBaseURL != nextBase {
                endpointBaseURL = nextBase
            }
            refreshReadiness()
        }
    }
    /// Model id for the non-Cursor providers. Cursor keeps using `grokModelID`.
    @Published var providerModelID: String {
        didSet {
            guard providerModelID != oldValue else { return }
            guard providerKind != .cursor else { return }
            storage.setModelID(providerModelID, for: providerKind)
            storage.storedProviderKind = providerKind
            refreshReadiness()
        }
    }
    /// Base URL for Ollama and OpenAI-compatible endpoints.
    @Published var endpointBaseURL: String {
        didSet {
            guard endpointBaseURL != oldValue else { return }
            guard providerKind.allowsCustomBaseURL else { return }
            storage.setBaseURLString(endpointBaseURL, for: providerKind)
            storage.storedProviderKind = providerKind
            refreshReadiness()
        }
    }
    @Published var prRepo: String {
        didSet { storage.prRepo = prRepo }
    }
    @Published var grokModelID: String {
        didSet {
            guard grokModelID != oldValue else { return }
            storage.grokModelID = grokModelID
            if providerKind == .cursor {
                storage.storedProviderKind = .cursor
            }
        }
    }
    @Published var background: IslandBackgroundStyle {
        didSet {
            guard background != oldValue else { return }
            storage.islandBackground = background
        }
    }
    @Published var shortcutButtons: IslandShortcutButtons {
        didSet {
            guard shortcutButtons != oldValue else { return }
            storage.islandShortcutButtons = shortcutButtons
        }
    }
    @Published var isPeekLocked: Bool {
        didSet { storage.isPeekLocked = isPeekLocked }
    }

    init(storage: IslandSettingsStorage = IslandSettingsStorage()) {
        self.storage = storage
        let resolved = storage.resolvedProviderKind
        hasAPIKey = storage.loadAPIKey() != nil
        hasSelectedAPIKey = storage.loadAPIKey(for: resolved) != nil
        isModelReady = storage.resolveProvider().configuration != nil
        providerKind = resolved
        providerModelID = storage.modelID(for: resolved == .cursor ? .xai : resolved)
        endpointBaseURL = storage.baseURLString(for: resolved)
        prRepo = storage.prRepo
        grokModelID = storage.grokModelID
        background = storage.islandBackground
        shortcutButtons = storage.islandShortcutButtons
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
        refreshReadiness()
    }

    func clearAPIKey() throws {
        try storage.saveAPIKey(nil)
        refreshReadiness()
    }

    /// Saves the key for the provider currently shown in Settings and remembers that choice.
    func saveProviderKey(_ key: String) throws {
        try storage.saveAPIKey(key, for: providerKind)
        storage.storedProviderKind = providerKind
        refreshReadiness()
    }

    func clearProviderKey() throws {
        try storage.saveAPIKey(nil, for: providerKind)
        storage.storedProviderKind = providerKind
        refreshReadiness()
    }

    func refreshReadiness() {
        hasAPIKey = storage.loadAPIKey(for: .cursor) != nil
        hasSelectedAPIKey = storage.loadAPIKey(for: providerKind) != nil
        isModelReady = storage.resolveProvider().configuration != nil
    }

    var credentials: CursorCredentials? { storage.credentials() }
}
