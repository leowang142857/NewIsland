import XCTest
#if canImport(GrokIslandCore)
@testable import GrokIslandCore
#else
@testable import GrokIsland
#endif

final class StagingIntakePolicyTests: XCTestCase {
    func testCopyUnlessDesktopMoveIsRequested() {
        XCTAssertEqual(StagingIntakePolicy.mode(sourceIsOnDesktop: true, moveRequested: false), .copy)
        XCTAssertEqual(StagingIntakePolicy.mode(sourceIsOnDesktop: false, moveRequested: false), .copy)
        XCTAssertEqual(StagingIntakePolicy.mode(sourceIsOnDesktop: false, moveRequested: true), .copy)
        XCTAssertEqual(StagingIntakePolicy.mode(sourceIsOnDesktop: true, moveRequested: true), .move)
    }

    func testDesktopDetectionIgnoresTheDesktopFolderItself() {
        let desktop = URL(fileURLWithPath: "/Users/me/Desktop", isDirectory: true)
        XCTAssertTrue(StagingIntakePolicy.isOnDesktop(
            source: desktop.appendingPathComponent("notes.txt"),
            desktopDirectory: desktop
        ))
        XCTAssertTrue(StagingIntakePolicy.isOnDesktop(
            source: desktop.appendingPathComponent("Folder").appendingPathComponent("a.txt"),
            desktopDirectory: desktop
        ))
        XCTAssertFalse(StagingIntakePolicy.isOnDesktop(source: desktop, desktopDirectory: desktop))
        XCTAssertFalse(StagingIntakePolicy.isOnDesktop(
            source: URL(fileURLWithPath: "/Users/me/Desktop-backup/notes.txt"),
            desktopDirectory: desktop
        ))
        XCTAssertFalse(StagingIntakePolicy.isOnDesktop(
            source: URL(fileURLWithPath: "/Users/me/Documents/notes.txt"),
            desktopDirectory: desktop
        ))
    }

    func testRemovalTargetMustBeInsideTheDesktop() {
        let desktop = URL(fileURLWithPath: "/Users/me/Desktop", isDirectory: true)
        XCTAssertTrue(StagingIntakePolicy.isSafeRemovalTarget(
            desktop.appendingPathComponent("notes.txt"),
            desktopDirectory: desktop
        ))
        XCTAssertFalse(StagingIntakePolicy.isSafeRemovalTarget(desktop, desktopDirectory: desktop))
        XCTAssertFalse(StagingIntakePolicy.isSafeRemovalTarget(
            URL(fileURLWithPath: "/"),
            desktopDirectory: desktop
        ))
        XCTAssertFalse(StagingIntakePolicy.isSafeRemovalTarget(
            URL(fileURLWithPath: "/Users/me/Documents/notes.txt"),
            desktopDirectory: desktop
        ))
    }

    func testTrayPathOwnsItemsAndExportCache() {
        let root = "/tmp/GrokIsland/staging"
        let id = UUID()
        XCTAssertEqual(
            StagingIntakePolicy.nodeID(inTrayPath: "\(root)/items/\(id.uuidString)/notes.txt", rootPath: root),
            id
        )
        XCTAssertEqual(
            StagingIntakePolicy.nodeID(inTrayPath: "\(root)/export-cache/\(id.uuidString)/作业/notes.txt", rootPath: root),
            id
        )
        XCTAssertNil(StagingIntakePolicy.nodeID(inTrayPath: "\(root)/catalog.json", rootPath: root))
        XCTAssertNil(StagingIntakePolicy.nodeID(inTrayPath: "/tmp/GrokIsland/staging-other/items/\(id.uuidString)/a", rootPath: root))
    }

    func testSanitizedNamesAndUniqueExportNames() {
        XCTAssertNil(StagingIntakePolicy.sanitizedName("  "))
        XCTAssertNil(StagingIntakePolicy.sanitizedName("."))
        XCTAssertNil(StagingIntakePolicy.sanitizedName(".."))
        XCTAssertNil(StagingIntakePolicy.sanitizedName("a/b"))
        XCTAssertEqual(StagingIntakePolicy.sanitizedName("  notes.txt  "), "notes.txt")

        XCTAssertEqual(
            StagingIntakePolicy.uniqueName("notes.txt", isDirectory: false, existing: ["notes.txt"]),
            "notes 2.txt"
        )
        XCTAssertEqual(
            StagingIntakePolicy.uniqueName("notes.txt", isDirectory: false, existing: ["notes.txt", "notes 2.txt"]),
            "notes 3.txt"
        )
        XCTAssertEqual(
            StagingIntakePolicy.uniqueName("作业", isDirectory: true, existing: ["作业"]),
            "作业 2"
        )
    }

    func testDragPayloadRoundTrip() {
        let id = UUID()
        XCTAssertEqual(StagingDrag.nodeID(in: StagingDrag.payload(for: id)), id)
        XCTAssertNil(StagingDrag.nodeID(in: "https://example.com"))
        XCTAssertNil(StagingDrag.nodeID(in: StagingDrag.prefix + "not-a-uuid"))
    }
}

final class StagingFileCheckTests: XCTestCase {
    func testCopyIsCompleteOnlyWhenBytesMatch() throws {
        let folder = try makeFolder()
        let source = folder.appendingPathComponent("a.txt")
        let dest = folder.appendingPathComponent("b.txt")
        try Data("hello".utf8).write(to: source)
        try Data("hello".utf8).write(to: dest)
        XCTAssertTrue(StagingFileCheck.copyIsComplete(source: source, destination: dest))
        try Data("hello!".utf8).write(to: dest)
        XCTAssertFalse(StagingFileCheck.copyIsComplete(source: source, destination: dest))
        XCTAssertFalse(StagingFileCheck.copyIsComplete(source: source, destination: folder.appendingPathComponent("missing.txt")))
    }

    func testDirectoryCopyCountsEveryEntry() throws {
        let folder = try makeFolder()
        let source = folder.appendingPathComponent("src", isDirectory: true)
        let dest = folder.appendingPathComponent("dst", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("nested", isDirectory: true), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: source.appendingPathComponent("nested").appendingPathComponent("a.txt"))
        try FileManager.default.copyItem(at: source, to: dest)
        XCTAssertTrue(StagingFileCheck.copyIsComplete(source: source, destination: dest))
        try Data("b".utf8).write(to: dest.appendingPathComponent("extra.txt"))
        XCTAssertFalse(StagingFileCheck.copyIsComplete(source: source, destination: dest))
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrokIslandStageCheck-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

@MainActor
final class StagingTrayStoreTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let desktop: URL
        let documents: URL
        let store: StagingTrayStore
    }

    private func makeFixture(copyIsComplete: ((URL, URL) -> Bool)? = nil) throws -> Fixture {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrokIslandStage-\(UUID().uuidString)", isDirectory: true)
        let desktop = base.appendingPathComponent("Desktop", isDirectory: true)
        let documents = base.appendingPathComponent("Documents", isDirectory: true)
        let root = base.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let store = StagingTrayStore(
            rootURL: root,
            desktopDirectory: desktop,
            copyIsComplete: copyIsComplete
        )
        return Fixture(root: root, desktop: desktop, documents: documents, store: store)
    }

    private func write(_ name: String, in directory: URL, contents: String = "hello") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func testDefaultCopyLeavesTheOriginal() async throws {
        let fixture = try makeFixture()
        let source = try write("notes.txt", in: fixture.desktop, contents: "keep-me")
        let imported = try fixture.store.stage(urls: [source], into: nil)
        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported[0].mode, .copy)
        XCTAssertFalse(imported[0].originalDeleteFailed)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "keep-me")
        let staged = try XCTUnwrap(fixture.store.storedFileURL(for: imported[0].node.id))
        XCTAssertEqual(try String(contentsOf: staged, encoding: .utf8), "keep-me")
        XCTAssertEqual(fixture.store.stagedItemCount, 1)
    }

    func testMoveRequestOffDesktopStillCopies() async throws {
        let fixture = try makeFixture()
        fixture.store.moveFromDesktop = true
        let source = try write("brief.txt", in: fixture.documents, contents: "docs")
        let imported = try fixture.store.stage(urls: [source], into: nil)
        XCTAssertEqual(imported[0].mode, .copy)
        XCTAssertTrue(imported[0].keptOriginalBecauseNotOnDesktop)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(fixture.store.statusNote?.contains("不在桌面") == true)
    }

    func testDesktopMoveRemovesOriginalOnlyAfterACompleteCopy() async throws {
        let fixture = try makeFixture()
        fixture.store.moveFromDesktop = true
        let source = try write("slide.txt", in: fixture.desktop, contents: "moved")
        let imported = try fixture.store.stage(urls: [source], into: nil)
        XCTAssertEqual(imported[0].mode, .move)
        XCTAssertFalse(imported[0].originalDeleteFailed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let staged = try XCTUnwrap(fixture.store.storedFileURL(for: imported[0].node.id))
        XCTAssertEqual(try String(contentsOf: staged, encoding: .utf8), "moved")
    }

    func testIncompleteCopyNeverDeletesTheOriginal() async throws {
        let fixture = try makeFixture(copyIsComplete: { _, _ in false })
        fixture.store.moveFromDesktop = true
        let source = try write("risky.txt", in: fixture.desktop, contents: "still-here")
        let imported = try fixture.store.stage(urls: [source], into: nil)
        XCTAssertEqual(imported[0].mode, .move)
        XCTAssertTrue(imported[0].originalDeleteFailed)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "still-here")
        XCTAssertNotNil(fixture.store.storedFileURL(for: imported[0].node.id))
    }

    func testFailedDeleteKeepsBothCopies() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrokIslandStage-\(UUID().uuidString)", isDirectory: true)
        let desktop = base.appendingPathComponent("Desktop", isDirectory: true)
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        let store = StagingTrayStore(
            rootURL: base.appendingPathComponent("staging"),
            desktopDirectory: desktop,
            deleteOriginal: { _ in throw StagingError.fileOperationFailed("busy") }
        )
        store.moveFromDesktop = true
        let source = try write("locked.txt", in: desktop, contents: "locked")
        let imported = try store.stage(urls: [source], into: nil)
        XCTAssertTrue(imported[0].originalDeleteFailed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.storedFileURL(for: imported[0].node.id)!.path))
    }

    func testRefusesToStageTheDesktopFolderItself() async throws {
        let fixture = try makeFixture()
        fixture.store.moveFromDesktop = true
        XCTAssertThrowsError(try fixture.store.stage(urls: [fixture.desktop], into: nil)) { error in
            XCTAssertEqual(error as? StagingError, .refusesDesktopFolder)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.desktop.path))
        XCTAssertEqual(fixture.store.stagedItemCount, 0)
    }

    func testFoldersCategoriesRenameMoveAndPersistence() async throws {
        let fixture = try makeFixture()
        let source = try write("a.txt", in: fixture.desktop, contents: "aaa")
        let nested = fixture.desktop.appendingPathComponent("Packet", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: nested.appendingPathComponent("b.txt"))

        let folder = try fixture.store.createFolder(name: "  作业  ", in: nil)
        XCTAssertEqual(folder.name, "作业")
        let file = try fixture.store.stage(urls: [source], into: folder.id)[0].node
        let directory = try fixture.store.stage(urls: [nested], into: nil)[0].node
        XCTAssertEqual(directory.kind, .directory)
        XCTAssertEqual(fixture.store.children(of: folder.id).map(\.id), [file.id])

        try fixture.store.move(id: directory.id, into: folder.id)
        XCTAssertEqual(fixture.store.node(id: directory.id)?.parentID, folder.id)
        let renamed = try fixture.store.rename(id: file.id, to: "renamed.txt")
        XCTAssertEqual(renamed.name, "renamed.txt")
        let renamedURL = try XCTUnwrap(fixture.store.storedFileURL(for: file.id))
        XCTAssertEqual(renamedURL.lastPathComponent, "renamed.txt")
        XCTAssertEqual(try String(contentsOf: renamedURL, encoding: .utf8), "aaa")

        let child = try fixture.store.createFolder(name: "草稿", in: folder.id)
        XCTAssertThrowsError(try fixture.store.move(id: folder.id, into: child.id)) { error in
            XCTAssertEqual(error as? StagingError, .cycle)
        }
        XCTAssertThrowsError(try fixture.store.move(id: folder.id, into: folder.id)) { error in
            XCTAssertEqual(error as? StagingError, .cannotMoveIntoSelf)
        }
        XCTAssertThrowsError(try fixture.store.rename(id: file.id, to: "   ")) { error in
            XCTAssertEqual(error as? StagingError, .nameEmpty)
        }

        let reloaded = StagingTrayStore(rootURL: fixture.root, desktopDirectory: fixture.desktop)
        XCTAssertEqual(reloaded.stagedItemCount, 2)
        XCTAssertEqual(reloaded.node(id: file.id)?.name, "renamed.txt")
        XCTAssertEqual(reloaded.node(id: file.id)?.parentID, folder.id)
        XCTAssertEqual(reloaded.node(id: folder.id)?.name, "作业")
        XCTAssertEqual(reloaded.stagedItemCount, 2, "categories are not part of the badge count")
        XCTAssertEqual(reloaded.children(of: nil).filter(\.isCategory).map(\.name), ["作业"])
    }

    func testRemoveRequiresConfirmationAndDeletesOnlyTheStagedCopy() async throws {
        let fixture = try makeFixture()
        let source = try write("keep.txt", in: fixture.desktop, contents: "original")
        let node = try fixture.store.stage(urls: [source], into: nil)[0].node
        let staged = try XCTUnwrap(fixture.store.storedFileURL(for: node.id))

        XCTAssertThrowsError(try fixture.store.remove(id: node.id, confirmed: false)) { error in
            XCTAssertEqual(error as? StagingError, .confirmationRequired)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertEqual(fixture.store.stagedItemCount, 1)

        try fixture.store.remove(id: node.id, confirmed: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(fixture.store.stagedItemCount, 0)

        let reloaded = StagingTrayStore(rootURL: fixture.root, desktopDirectory: fixture.desktop)
        XCTAssertTrue(reloaded.nodes.isEmpty)
    }

    func testRemovingACategoryRemovesNestedCopies() async throws {
        let fixture = try makeFixture()
        let source = try write("nested.txt", in: fixture.desktop, contents: "n")
        let folder = try fixture.store.createFolder(name: "分类", in: nil)
        let node = try fixture.store.stage(urls: [source], into: folder.id)[0].node
        let staged = try XCTUnwrap(fixture.store.storedFileURL(for: node.id))
        try fixture.store.remove(id: folder.id, confirmed: true)
        XCTAssertNil(fixture.store.node(id: node.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testExportCopyLeavesTheTrayIntactAndUniquesNames() async throws {
        let fixture = try makeFixture()
        let source = try write("photo.txt", in: fixture.desktop, contents: "pixels")
        let node = try fixture.store.stage(urls: [source], into: nil)[0].node
        let desktopOut = fixture.desktop.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: desktopOut, withIntermediateDirectories: true)

        let first = try fixture.store.exportCopy(of: node.id, to: desktopOut)
        let second = try fixture.store.exportCopy(of: node.id, to: desktopOut)
        XCTAssertEqual(first.lastPathComponent, "photo.txt")
        XCTAssertEqual(second.lastPathComponent, "photo 2.txt")
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "pixels")
        XCTAssertEqual(fixture.store.stagedItemCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.store.storedFileURL(for: node.id)!.path))

        let exported = try fixture.store.exportURL(for: node.id)
        XCTAssertEqual(try String(contentsOf: exported, encoding: .utf8), "pixels")
        try FileManager.default.removeItem(at: exported)
        XCTAssertEqual(
            try String(contentsOf: fixture.store.storedFileURL(for: node.id)!, encoding: .utf8),
            "pixels",
            "dragging the export away must not eat the staged copy"
        )
    }

    func testExportingACategoryBuildsAFolderOfItsChildren() async throws {
        let fixture = try makeFixture()
        let source = try write("c.txt", in: fixture.desktop, contents: "child")
        let folder = try fixture.store.createFolder(name: "作业", in: nil)
        _ = try fixture.store.stage(urls: [source], into: folder.id)
        let out = fixture.documents.appendingPathComponent("drop", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let exported = try fixture.store.exportCopy(of: folder.id, to: out)
        XCTAssertEqual(exported.lastPathComponent, "作业")
        XCTAssertEqual(
            try String(contentsOf: exported.appendingPathComponent("c.txt"), encoding: .utf8),
            "child"
        )
        XCTAssertEqual(fixture.store.node(id: folder.id)?.name, "作业")
    }

    func testDroppingAStagedURLMovesItInsteadOfCopyingAgain() async throws {
        let fixture = try makeFixture()
        let source = try write("once.txt", in: fixture.desktop, contents: "1")
        let node = try fixture.store.stage(urls: [source], into: nil)[0].node
        let stored = try XCTUnwrap(fixture.store.storedFileURL(for: node.id))
        let folder = try fixture.store.createFolder(name: "收件", in: nil)
        let again = try fixture.store.stage(urls: [stored], into: folder.id)
        XCTAssertTrue(again.isEmpty)
        XCTAssertEqual(fixture.store.node(id: node.id)?.parentID, folder.id)
        XCTAssertEqual(fixture.store.stagedItemCount, 1)
    }

    func testMissingSourceDoesNotCreateANode() async throws {
        let fixture = try makeFixture()
        let missing = fixture.desktop.appendingPathComponent("gone.txt")
        XCTAssertThrowsError(try fixture.store.stage(urls: [missing], into: nil)) { error in
            XCTAssertEqual(error as? StagingError, .sourceMissing)
        }
        XCTAssertTrue(fixture.store.nodes.isEmpty)
    }

    func testBadgeLabelHidesAnEmptyTray() async {
        XCTAssertNil(PeekStrip.stagingBadgeLabel(count: 0))
        XCTAssertEqual(PeekStrip.stagingBadgeLabel(count: 3), "3")
        XCTAssertEqual(PeekStrip.stagingBadgeLabel(count: 120), "99+")
    }
}
