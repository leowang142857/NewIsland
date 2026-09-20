import Foundation
import UniformTypeIdentifiers

#if canImport(AppKit)
import AppKit
#endif

/// Turns pasteboard / drop payloads into `ResourceItem` references.
enum ResourceIntake {
    static func items(from urls: [URL]) -> [ResourceItem] {
        urls.map(makeItem(from:))
    }

    static func items(fromStrings strings: [String]) -> [ResourceItem] {
        strings.compactMap { raw -> ResourceItem? in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let url = URL(string: trimmed), let scheme = url.scheme, scheme == "http" || scheme == "https" {
                return makeItem(from: url)
            }
            if trimmed.hasPrefix("file://"), let url = URL(string: trimmed) {
                return makeItem(from: url)
            }
            let asPath = URL(fileURLWithPath: trimmed)
            if FileManager.default.fileExists(atPath: asPath.path) {
                return makeItem(from: asPath)
            }
            return nil
        }
    }

    static func makeItem(from url: URL) -> ResourceItem {
        if url.isFileURL {
            return fileItem(at: url)
        }
        let name: String
        if let host = url.host, !host.isEmpty {
            name = url.path.isEmpty || url.path == "/" ? host : "\(host)\(url.path)"
        } else {
            name = url.absoluteString
        }
        return ResourceItem(kind: .url, name: name, location: url.absoluteString, uti: UTType.url.identifier)
    }

    static func fileItem(at url: URL) -> ResourceItem {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        let bookmark = try? url.bookmarkData(
            options: [.minimalBookmark],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        return ResourceItem(
            kind: isDirectory.boolValue ? .folder : .file,
            name: url.lastPathComponent,
            location: url.path,
            uti: values?.contentType?.identifier,
            fileSize: values?.fileSize.map { Int64($0) },
            bookmarkData: bookmark
        )
    }

#if canImport(AppKit)
    @MainActor
    static func loadItems(from providers: [NSItemProvider]) async -> [ResourceItem] {
        var collected: [ResourceItem] = []
        for provider in providers {
            if let item = await loadItem(from: provider) {
                collected.append(item)
            }
        }
        return collected
    }

    @MainActor
    private static func loadItem(from provider: NSItemProvider) async -> ResourceItem? {
        if provider.canLoadObject(ofClass: URL.self) {
            if let url = await loadURL(from: provider) {
                return makeItem(from: url)
            }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if let url = await loadTypedURL(from: provider, type: UTType.fileURL) {
                return makeItem(from: url)
            }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = await loadTypedURL(from: provider, type: UTType.url) {
                return makeItem(from: url)
            }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = await loadString(from: provider) {
                return items(fromStrings: [text]).first
            }
        }
        return nil
    }

    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { object, _ in
                continuation.resume(returning: object as? URL)
            }
        }
    }

    private static func loadTypedURL(from provider: NSItemProvider, type: UTType) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url)
                    return
                }
                if let data = item as? Data {
                    if let url = URL(dataRepresentation: data, relativeTo: nil) {
                        continuation.resume(returning: url)
                        return
                    }
                    if let text = String(data: data, encoding: .utf8),
                       let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        continuation.resume(returning: url)
                        return
                    }
                }
                if let text = item as? String, let url = URL(string: text) {
                    continuation.resume(returning: url)
                    return
                }
                continuation.resume(returning: nil)
            }
        }
    }

    private static func loadString(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                if let text = item as? String {
                    continuation.resume(returning: text)
                } else if let data = item as? Data, let text = String(data: data, encoding: .utf8) {
                    continuation.resume(returning: text)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
#endif
}
