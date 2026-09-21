import Foundation

#if canImport(AppKit)
import AppKit
#endif

/// Copies the running app into ~/Applications and drops a Finder alias on the Desktop.
enum DesktopShortcut {
    static let installedAppName = "grok岛.app"
    static let aliasName = "grok岛"

    static var applicationsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
    }

    static var installedAppURL: URL {
        applicationsDirectory.appendingPathComponent(installedAppName)
    }

    static var desktopAliasURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true)
            .appendingPathComponent(aliasName)
    }

#if canImport(AppKit)
    @discardableResult
    static func install(from bundleURL: URL = Bundle.main.bundleURL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: applicationsDirectory, withIntermediateDirectories: true)

        if fm.fileExists(atPath: installedAppURL.path) {
            try fm.removeItem(at: installedAppURL)
        }
        try fm.copyItem(at: bundleURL, to: installedAppURL)

        if fm.fileExists(atPath: desktopAliasURL.path) {
            try fm.removeItem(at: desktopAliasURL)
        }
        let bookmark = try installedAppURL.bookmarkData(
            options: [.suitableForBookmarkFile],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        try URL.writeBookmarkData(bookmark, to: desktopAliasURL)
        return desktopAliasURL
    }
#endif
}
