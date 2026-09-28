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

    func credentials() -> CursorCredentials? {
        guard let key = loadAPIKey() else { return nil }
        return CursorCredentials(apiKey: key, modelID: grokModelID)
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

    init(storage: IslandSettingsStorage = IslandSettingsStorage()) {
        self.storage = storage
        hasAPIKey = storage.loadAPIKey() != nil
        prRepo = storage.prRepo
        grokModelID = storage.grokModelID
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
