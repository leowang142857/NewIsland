import Foundation
import Combine

/// Persists user-created `FunctionModule`s as JSON in Application Support.
///
/// Public API: `create` / `update` / `rename` / `delete` / `module(id:)` / `replaceAll` / `reload`.
@MainActor
final class ModuleStore: ObservableObject {
    @Published private(set) var modules: [FunctionModule] = []

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        modules = loadFromDisk()
    }

    var storageURL: URL { fileURL }

    static var defaultFileURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let folder = root.appendingPathComponent("GrokIsland", isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder.appendingPathComponent("function-modules.json")
    }

    func module(id: UUID) -> FunctionModule? {
        modules.first { $0.id == id }
    }

    @discardableResult
    func create(name: String, prompt: String, executor: ExecutorKind) throws -> FunctionModule {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw IslandError.moduleNameEmpty }
        let now = Date()
        let module = FunctionModule(
            name: trimmed,
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            executor: executor,
            createdAt: now,
            updatedAt: now
        )
        modules.append(module)
        try persist()
        return module
    }

    @discardableResult
    func update(_ module: FunctionModule) throws -> FunctionModule {
        let trimmed = module.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw IslandError.moduleNameEmpty }
        guard let index = modules.firstIndex(where: { $0.id == module.id }) else {
            throw IslandError.moduleNotFound
        }
        var next = module
        next.name = trimmed
        next.prompt = module.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        next.updatedAt = Date()
        modules[index] = next
        try persist()
        return next
    }

    @discardableResult
    func rename(id: UUID, to name: String) throws -> FunctionModule {
        guard var module = module(id: id) else { throw IslandError.moduleNotFound }
        module.name = name
        return try update(module)
    }

    func delete(id: UUID) throws {
        guard modules.contains(where: { $0.id == id }) else {
            throw IslandError.moduleNotFound
        }
        modules.removeAll { $0.id == id }
        try persist()
    }

    /// Replaces the store with the provided modules and writes to disk.
    func replaceAll(_ modules: [FunctionModule]) throws {
        self.modules = modules
        try persist()
    }

    func reload() {
        modules = loadFromDisk()
    }

    static func demoModules(now: Date = Date()) -> [FunctionModule] {
        [
            FunctionModule(
                name: "翻译",
                prompt: "将附加资源翻译为简体中文，保持专有名词与代码块不变。",
                executor: .grokBot,
                createdAt: now,
                updatedAt: now
            ),
            FunctionModule(
                name: "整理笔记",
                prompt: "把附加材料整理成条理清晰的笔记：要点、待办、引用。",
                executor: .grokBot,
                createdAt: now,
                updatedAt: now
            ),
            FunctionModule(
                name: "打开文件",
                prompt: "用系统默认应用打开附加的文件或文件夹。",
                executor: .local,
                createdAt: now,
                updatedAt: now
            )
        ]
    }

    private func persist() throws {
        do {
            let folder = fileURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: folder.path) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            let data = try encoder.encode(modules)
            try data.write(to: fileURL, options: [.atomic])
        } catch let error as IslandError {
            throw error
        } catch {
            throw IslandError.persistenceFailed(error.localizedDescription)
        }
    }

    private func loadFromDisk() -> [FunctionModule] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            return try decoder.decode([FunctionModule].self, from: data)
        } catch {
            NSLog("GrokIsland ModuleStore: load failed: \(error.localizedDescription)")
            return []
        }
    }
}
