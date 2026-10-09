import XCTest
#if canImport(GrokIslandCore)
@testable import GrokIslandCore
#else
@testable import GrokIsland
#endif

/// A throwaway home: `tray/` is the staging root, `Desktop/` stands in for where files come from.
private struct TraySandbox {
    let base: URL
    let fileSystem: TrayFileSystem
    var desktop: URL { base.appendingPathComponent("Desktop", isDirectory: true) }
    var root: URL { fileSystem.root }

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrokIslandTray-\(UUID().uuidString)", isDirectory: true)
        fileSystem = TrayFileSystem(root: base.appendingPathComponent("tray", isDirectory: true))
        try FileManager.default.createDirectory(at: base.appendingPathComponent("Desktop"), withIntermediateDirectories: true)
        try fileSystem.ensureRoot()
    }

    @discardableResult
    func desktopFile(_ name: String, _ text: String = "hello") throws -> URL {
        let url = desktop.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    @discardableResult
    func desktopFolder(_ name: String, files: [String: String]) throws -> URL {
        let url = desktop.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (file, text) in files {
            try Data(text.utf8).write(to: url.appendingPathComponent(file))
        }
        return url
    }

    @discardableResult
    func trayFile(_ path: String, _ text: String = "tray") throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    func trayFolder(_ path: String) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
    }

    func text(_ path: String) -> String? {
        (try? Data(contentsOf: root.appendingPathComponent(path))).flatMap { String(data: $0, encoding: .utf8) }
    }

    func names(_ folder: String = "") throws -> [String] {
        try fileSystem.entries(in: folder).map(\.name)
    }

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Runs `body` with `folder` set to `mode`, and puts it back so the sandbox can be cleaned up.
    /// Skips when permissions do not bind (running as root).
    func withPermissions<T>(_ mode: Int, on folder: URL, _ body: () async throws -> T) async throws -> T {
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: folder.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        guard !fm.isWritableFile(atPath: folder.path) else { throw XCTSkip("permissions do not apply to this user") }
        return try await body()
    }
}

/// Records what a `TrayDropAccess` started and stopped.
private final class AccessLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _started: [URL] = []
    private var _stopped: [URL] = []

    var started: [URL] { lock.lock(); defer { lock.unlock() }; return _started }
    var stopped: [URL] { lock.lock(); defer { lock.unlock() }; return _stopped }

    func access(_ urls: [URL], granted: (URL) -> Bool = { _ in true }) -> TrayDropAccess {
        TrayDropAccess(
            urls,
            start: { url in
                self.lock.lock(); defer { self.lock.unlock() }
                self._started.append(url)
                return granted(url)
            },
            stop: { url in
                self.lock.lock(); defer { self.lock.unlock() }
                self._stopped.append(url)
            }
        )
    }
}

final class TrayNamingTests: XCTestCase {
    func testValidateTrimsAndRejectsUnsafeNames() throws {
        XCTAssertEqual(try TrayNaming.validate("  论文草稿 \n"), "论文草稿")
        XCTAssertThrowsError(try TrayNaming.validate("   ")) { XCTAssertEqual($0 as? TrayError, .nameEmpty) }
        for bad in ["a/b", "a:b", ".hidden", ".", ".."] {
            XCTAssertThrowsError(try TrayNaming.validate(bad), bad) { XCTAssertEqual($0 as? TrayError, .nameInvalid) }
        }
        XCTAssertThrowsError(try TrayNaming.validate(String(repeating: "长", count: 100))) {
            XCTAssertEqual($0 as? TrayError, .nameTooLong)
        }
    }

    func testUniqueNameNumbersLikeFinder() {
        let taken: Set<String> = ["报告.pdf", "报告 2.pdf", "资料", "v1.2"]
        XCTAssertEqual(TrayNaming.uniqueName("新的.pdf", isFolder: false, isTaken: taken.contains), "新的.pdf")
        XCTAssertEqual(TrayNaming.uniqueName("报告.pdf", isFolder: false, isTaken: taken.contains), "报告 3.pdf")
        XCTAssertEqual(TrayNaming.uniqueName("资料", isFolder: true, isTaken: taken.contains), "资料 2")
        XCTAssertEqual(TrayNaming.uniqueName("v1.2", isFolder: true, isTaken: taken.contains), "v1.2 2", "folders keep dots in the name")
    }

    func testSplitOnlyTakesARealExtension() {
        XCTAssertEqual(TrayNaming.split("a.tar.gz").ext, "gz")
        XCTAssertEqual(TrayNaming.split("README").ext, "")
        XCTAssertEqual(TrayNaming.split(".env").ext, "")
        XCTAssertEqual(TrayNaming.split("note.final draft").ext, "")
    }
}

final class TrayPathTests: XCTestCase {
    func testJoinParentNameAndTrail() {
        XCTAssertEqual(TrayPath.join("", "a"), "a")
        XCTAssertEqual(TrayPath.join("a", "b"), "a/b")
        XCTAssertEqual(TrayPath.parent(of: "a/b/c.txt"), "a/b")
        XCTAssertEqual(TrayPath.parent(of: "c.txt"), "")
        XCTAssertEqual(TrayPath.name(of: "a/b/c.txt"), "c.txt")
        XCTAssertEqual(TrayPath.title(of: ""), TrayPath.rootTitle)
        XCTAssertEqual(TrayPath.trail(to: ""), [""])
        XCTAssertEqual(TrayPath.trail(to: "a/b"), ["", "a", "a/b"])
    }

    func testCanMoveSkipsNoOpsAndSelfNesting() {
        XCTAssertTrue(TrayPath.isWithin("a/b", "a"))
        XCTAssertFalse(TrayPath.isWithin("ab", "a"), "a sibling with a longer name is not inside")
        XCTAssertTrue(TrayPath.canMove(["x.txt"], into: "a"))
        XCTAssertFalse(TrayPath.canMove(["a/x.txt"], into: "a"), "already there")
        XCTAssertFalse(TrayPath.canMove(["a"], into: "a"), "a folder onto itself")
        XCTAssertFalse(TrayPath.canMove(["a"], into: "a/b"), "a folder into its own child")
        XCTAssertTrue(TrayPath.canMove(["a", "x.txt"], into: "a"), "one item can still go")
    }
}

final class TraySelectionTests: XCTestCase {
    private let order = ["f1", "f2", "a", "b", "c", "d"]

    func testPlainClickSelectsOnlyThat() {
        var selection = TraySelection()
        selection.click("a", in: order)
        selection.click("c", in: order)
        XCTAssertEqual(selection.paths, ["c"])
    }

    func testCommandClickToggles() {
        var selection = TraySelection()
        selection.click("a", in: order)
        selection.click("c", in: order, toggle: true)
        XCTAssertEqual(selection.paths, ["a", "c"])
        selection.click("a", in: order, toggle: true)
        XCTAssertEqual(selection.paths, ["c"])
    }

    func testShiftClickSelectsTheRangeFromTheAnchor() {
        var selection = TraySelection()
        selection.click("b", in: order)
        selection.click("d", in: order, extend: true)
        XCTAssertEqual(selection.ordered(in: order), ["b", "c", "d"])
        selection.click("f2", in: order, extend: true)
        XCTAssertEqual(selection.ordered(in: order), ["f2", "a", "b"], "the range pivots on the anchor")
    }

    func testDragCarriesTheSelectionOnlyWhenItStartsOnIt() {
        var selection = TraySelection()
        selection.click("d", in: order)
        selection.click("a", in: order, toggle: true)
        XCTAssertEqual(selection.dragged(from: "d", in: order), ["a", "d"], "display order, not click order")
        XCTAssertEqual(selection.dragged(from: "b", in: order), ["b"])
    }

    func testPruneForgetsWhatIsGone() {
        var selection = TraySelection()
        selection.selectAll(order)
        selection.prune(to: ["a", "b"])
        XCTAssertEqual(selection.paths, ["a", "b"])
        selection.clear()
        XCTAssertTrue(selection.isEmpty)
    }
}

final class TrayFileSystemTests: XCTestCase {
    func testDropMovesAFileFromTheDesktopIntoTheTray() throws {
        let box = try TraySandbox()
        let source = try box.desktopFile("报告.pdf", "pdf bytes")

        let report = box.fileSystem.importItems([source], into: "", mode: .move)

        XCTAssertEqual(report.moved, ["报告.pdf"])
        XCTAssertTrue(report.copied.isEmpty)
        XCTAssertFalse(box.exists(source), "the Desktop copy is gone; it lives in the tray now")
        XCTAssertEqual(box.text("报告.pdf"), "pdf bytes")
        XCTAssertEqual(try box.names(), ["报告.pdf"])
    }

    func testCopyModeLeavesTheOriginal() throws {
        let box = try TraySandbox()
        let source = try box.desktopFile("a.txt")
        let report = box.fileSystem.importItems([source], into: "", mode: .copy)
        XCTAssertEqual(report.copied, ["a.txt"])
        XCTAssertEqual(report.keptOriginals, 0, "keeping the original was asked for, not a fallback")
        XCTAssertTrue(box.exists(source))
        XCTAssertEqual(box.text("a.txt"), "hello")
    }

    func testFoldersComeInWithTheirContents() throws {
        let box = try TraySandbox()
        let folder = try box.desktopFolder("照片", files: ["1.jpg": "one", "2.jpg": "two", ".DS_Store": "x"])
        _ = box.fileSystem.importItems([folder], into: "", mode: .move)

        let entry = try XCTUnwrap(box.fileSystem.entries(in: "").first)
        XCTAssertTrue(entry.isFolder)
        XCTAssertEqual(entry.childCount, 2, "hidden files are not counted")
        XCTAssertEqual(Set(try box.names("照片")), ["1.jpg", "2.jpg"])
        XCTAssertFalse(box.exists(folder))
        XCTAssertEqual(box.text("照片/2.jpg"), "two")
    }

    func testNameClashesGetANumberAndNothingIsOverwritten() throws {
        let box = try TraySandbox()
        try box.trayFile("a.txt", "already here")
        let source = try box.desktopFile("a.txt", "new one")

        let report = box.fileSystem.importItems([source], into: "", mode: .move)

        XCTAssertEqual(report.moved, ["a 2.txt"])
        XCTAssertEqual(box.text("a.txt"), "already here")
        XCTAssertEqual(box.text("a 2.txt"), "new one")
    }

    func testDropStraightIntoASubfolder() throws {
        let box = try TraySandbox()
        try box.trayFolder("论文")
        let source = try box.desktopFile("草稿.docx")
        let report = box.fileSystem.importItems([source], into: "论文", mode: .move)
        XCTAssertEqual(report.moved, ["论文/草稿.docx"])
        XCTAssertEqual(try box.names("论文"), ["草稿.docx"])
    }

    func testDroppingTrayItemsOnAFolderMovesThemInsteadOfCopying() throws {
        let box = try TraySandbox()
        try box.trayFolder("归档")
        let inTray = try box.trayFile("x.txt", "keep me")

        let report = box.fileSystem.importItems([inTray], into: "归档", mode: .copy)

        XCTAssertEqual(report.moved, ["归档/x.txt"], "already in the tray, so it is a move whatever the drop mode")
        XCTAssertTrue(report.copied.isEmpty)
        XCTAssertFalse(box.exists(inTray))
        XCTAssertEqual(box.text("归档/x.txt"), "keep me")
    }

    func testTheTrayCannotSwallowItself() throws {
        let box = try TraySandbox()
        try box.trayFile("safe.txt")
        let report = box.fileSystem.importItems([box.base], into: "", mode: .move)
        XCTAssertTrue(report.arrived.isEmpty)
        XCTAssertEqual(report.failures.first?.reason, TrayError.containsTray.localizedDescription)
        XCTAssertEqual(box.text("safe.txt"), "tray")
    }

    func testMissingSourcesAreReportedNotIgnored() throws {
        let box = try TraySandbox()
        let gone = box.desktop.appendingPathComponent("gone.txt")
        let report = box.fileSystem.importItems([gone], into: "", mode: .move)
        XCTAssertEqual(report.failures.map(\.name), ["gone.txt"])
        XCTAssertEqual(report.failures.first?.reason, "原文件找不到了")
        XCTAssertTrue(report.summary(destination: TrayPath.rootTitle).contains("没放进来"))
    }

    func testAnOriginalThatMayNotBeReadIsAPermissionProblemNotAMissingFile() async throws {
        let box = try TraySandbox()
        let locked = try box.desktopFolder("私密", files: ["secret.txt": "x"])
        let secret = locked.appendingPathComponent("secret.txt")

        let report = try await box.withPermissions(0o000, on: locked) {
            box.fileSystem.importItems([secret], into: "", mode: .move)
        }

        XCTAssertTrue(report.arrived.isEmpty)
        let reason = try XCTUnwrap(report.failures.first?.reason)
        XCTAssertTrue(["没有权限", "没有读取它的权限", "没有写入那里的权限"].contains(reason), reason)
        XCTAssertNotEqual(reason, TrayError.privacyBlocked, "plain file permissions are not macOS privacy protection")
        XCTAssertTrue(try box.names().isEmpty)
        XCTAssertTrue(box.exists(secret))
    }

    func testMoveInRenamesAndLeavesCopiesForCopyIn() throws {
        let box = try TraySandbox()
        let moved = try box.desktopFile("moved.txt")
        let copied = try box.desktopFile("copied.txt", "copy me")

        let first = box.fileSystem.moveIn([moved], into: "", mode: .move)
        XCTAssertEqual(first.report.moved, ["moved.txt"])
        XCTAssertTrue(first.copies.isEmpty, "a same-disk move is only a rename")

        let second = box.fileSystem.moveIn([copied], into: "", mode: .copy)
        XCTAssertTrue(second.report.arrived.isEmpty)
        XCTAssertEqual(second.copies, [TrayPendingCopy(source: copied.standardizedFileURL, wantedMove: false)])
        XCTAssertEqual(try box.names(), ["moved.txt"], "nothing copied yet")

        let report = box.fileSystem.copyIn(second.copies, into: "")
        XCTAssertEqual(report.copied, ["copied.txt"])
        XCTAssertEqual(report.keptOriginals, 0)
        XCTAssertEqual(box.text("copied.txt"), "copy me")
        XCTAssertTrue(box.exists(copied))
    }

    func testFileOperationsGetTheDroppedURLNotAStandardizedCopy() throws {
        let box = try TraySandbox()
        try box.desktopFile("a.txt", "as dropped")
        let dropped = URL(fileURLWithPath: box.desktop.path + "/./a.txt")
        XCTAssertNotEqual(dropped, dropped.standardizedFileURL, "precondition: standardizing would make a new value")

        let (_, copies) = box.fileSystem.moveIn([dropped], into: "", mode: .copy)
        XCTAssertEqual(copies.map(\.source), [dropped], "the value the drop's access was started on")

        let report = box.fileSystem.copyIn(copies, into: "")
        XCTAssertEqual(report.copied, ["a.txt"], "named after the file, not the ./ segment")
        XCTAssertEqual(box.text("a.txt"), "as dropped")
    }

    func testAnOriginalThatCannotBeMovedIsCopied() async throws {
        let box = try TraySandbox()
        let readOnly = try box.desktopFolder("只读", files: ["kept.txt": "kept"])
        let kept = readOnly.appendingPathComponent("kept.txt")

        let (report, copies, copied) = try await box.withPermissions(0o555, on: readOnly) {
            let (report, copies) = box.fileSystem.moveIn([kept], into: "", mode: .move)
            return (report, copies, box.fileSystem.copyIn(copies, into: ""))
        }

        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(copies, [TrayPendingCopy(source: kept.standardizedFileURL, wantedMove: true)])
        XCTAssertEqual(copied.copied, ["kept.txt"])
        XCTAssertEqual(copied.keptOriginals, 1)
        XCTAssertTrue(box.exists(kept))
    }

    func testListingHidesDotFilesAndPutsFoldersFirst() throws {
        let box = try TraySandbox()
        try box.trayFile("b.txt")
        try box.trayFile(".DS_Store")
        try box.trayFolder("Zeta")
        try box.trayFolder("alpha")
        let entries = try box.fileSystem.entries(in: "")
        XCTAssertEqual(entries.map(\.name).prefix(2), ["alpha", "Zeta"])
        XCTAssertEqual(entries.map(\.name).last, "b.txt")
        XCTAssertFalse(entries.contains { $0.name.hasPrefix(".") })
        XCTAssertEqual(entries.last?.byteSize, 4)
        XCTAssertNil(entries.first?.byteSize)
    }

    func testTheTrayIsWhatIsOnDiskSoItSurvivesARelaunch() throws {
        let box = try TraySandbox()
        let source = try box.desktopFile("留着.txt")
        _ = box.fileSystem.importItems([source], into: "", mode: .move)
        _ = try box.fileSystem.createFolder(named: "整理", in: "")

        let relaunched = TrayFileSystem(root: box.root)
        XCTAssertEqual(try relaunched.entries(in: "").map(\.name), ["整理", "留着.txt"])
    }

    func testNewFolderNamesCountUp() throws {
        let box = try TraySandbox()
        XCTAssertEqual(try box.fileSystem.createFolder(in: ""), TrayNaming.newFolderName)
        XCTAssertEqual(try box.fileSystem.createFolder(in: ""), "\(TrayNaming.newFolderName) 2")
        try box.trayFolder("论文")
        XCTAssertEqual(try box.fileSystem.createFolder(named: "图", in: "论文"), "论文/图")
        XCTAssertThrowsError(try box.fileSystem.createFolder(named: "图", in: "论文")) {
            XCTAssertEqual($0 as? TrayError, .nameTaken("图"))
        }
    }

    func testRenameRefusesClashesAndBadNames() throws {
        let box = try TraySandbox()
        try box.trayFile("a.txt", "A")
        try box.trayFile("b.txt", "B")

        XCTAssertEqual(try box.fileSystem.rename("a.txt", to: " 新名字.txt "), "新名字.txt")
        XCTAssertEqual(box.text("新名字.txt"), "A")
        XCTAssertThrowsError(try box.fileSystem.rename("新名字.txt", to: "b.txt")) {
            XCTAssertEqual($0 as? TrayError, .nameTaken("b.txt"))
        }
        XCTAssertThrowsError(try box.fileSystem.rename("b.txt", to: "x/y")) {
            XCTAssertEqual($0 as? TrayError, .nameInvalid)
        }
        XCTAssertThrowsError(try box.fileSystem.rename("missing.txt", to: "z")) {
            XCTAssertEqual($0 as? TrayError, .notFound("missing.txt"))
        }
        XCTAssertEqual(box.text("b.txt"), "B")
    }

    func testCaseOnlyRenameWorks() throws {
        let box = try TraySandbox()
        try box.trayFile("readme.md", "doc")
        XCTAssertEqual(try box.fileSystem.rename("readme.md", to: "README.md"), "README.md")
        XCTAssertEqual(try box.names(), ["README.md"])
        XCTAssertEqual(box.text("README.md"), "doc")
    }

    func testMoveBetweenFoldersAndNoFolderIntoItself() throws {
        let box = try TraySandbox()
        try box.trayFolder("a/inner")
        try box.trayFolder("b")
        try box.trayFile("x.txt", "X")
        try box.trayFile("b/x.txt", "other X")

        var report = box.fileSystem.move(["x.txt"], into: "b")
        XCTAssertEqual(report.moved, ["b/x 2.txt"], "a clash in the destination is numbered")
        XCTAssertEqual(box.text("b/x.txt"), "other X")

        report = box.fileSystem.move(["a"], into: "a/inner")
        XCTAssertTrue(report.moved.isEmpty)
        XCTAssertEqual(report.failures.first?.reason, TrayError.intoItself("a").localizedDescription)

        report = box.fileSystem.move(["b/x 2.txt"], into: "b")
        XCTAssertEqual(report.unchanged, 1)
        XCTAssertEqual(report.summary(destination: "b"), "已经在「b」里了")

        report = box.fileSystem.move(["b"], into: "a")
        XCTAssertEqual(report.moved, ["a/b"])
        XCTAssertEqual(Set(try box.names("a/b")), ["x.txt", "x 2.txt"])
    }

    func testDeleteTakesItemsOutOfTheTray() throws {
        let box = try TraySandbox()
        try box.trayFile("a.txt")
        try box.trayFile("f/b.txt")
        let report = box.fileSystem.delete(["a.txt", "f", "never-there.txt"])
        XCTAssertEqual(report.trashed + report.removed, 2)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(try box.names(), [])
    }

    func testPathsCannotPointOutsideTheTray() throws {
        let box = try TraySandbox()
        XCTAssertEqual(box.fileSystem.url(for: ""), box.root)
        XCTAssertNil(box.fileSystem.url(for: "../escape"))
        XCTAssertNil(box.fileSystem.url(for: "a/../../escape"))
        XCTAssertNil(box.fileSystem.url(for: ".hidden"))
        XCTAssertNil(box.fileSystem.url(for: "a//b"))
        XCTAssertEqual(box.fileSystem.relativePath(of: box.root.appendingPathComponent("a/b.txt")), "a/b.txt")
        XCTAssertEqual(box.fileSystem.relativePath(of: box.root), "")
        XCTAssertNil(box.fileSystem.relativePath(of: box.desktop.appendingPathComponent("a.txt")))
        let sibling = box.base.appendingPathComponent("tray-old/a.txt")
        XCTAssertNil(box.fileSystem.relativePath(of: sibling), "a folder that merely starts with the same name is outside")
        XCTAssertNil(box.fileSystem.relativePath(of: URL(string: "https://example.com/a")!))
    }

    func testFolderTreeIsDepthFirstWithTheRootOnTop() throws {
        let box = try TraySandbox()
        try box.trayFolder("b")
        try box.trayFolder("a/z")
        try box.trayFolder("a/c")
        try box.trayFile("a/file.txt")
        let tree = box.fileSystem.folderTree()
        XCTAssertEqual(tree.map(\.path), ["", "a", "a/c", "a/z", "b"])
        XCTAssertEqual(tree.map(\.depth), [0, 1, 2, 2, 1])
        XCTAssertEqual(tree.first?.name, TrayPath.rootTitle)
    }

    func testAnotherDiskIsCopiedEvenWhenMovingWasAsked() throws {
        let shm = URL(fileURLWithPath: "/dev/shm", isDirectory: true)
        let box = try TraySandbox()
        guard FileManager.default.isWritableFile(atPath: shm.path),
              !TrayFileSystem.sameVolume(shm, box.root)
        else { throw XCTSkip("no second file system to drop from") }
        let source = shm.appendingPathComponent("GrokIslandTray-\(UUID().uuidString).txt")
        try Data("usb".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let report = box.fileSystem.importItems([source], into: "", mode: .move)

        XCTAssertEqual(report.copied.count, 1)
        XCTAssertEqual(report.keptOriginals, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "like Finder: another disk is copied, not moved")
    }
}

final class TrayReportTests: XCTestCase {
    func testSummariesReadLikeSentences() {
        var report = TrayTransferReport()
        report.moved = ["a", "b", "c"]
        XCTAssertEqual(report.summary(destination: "暂存"), "已移进「暂存」3 项")

        report = TrayTransferReport(copied: ["a"])
        XCTAssertEqual(report.summary(destination: "论文"), "已拷贝 1 项到「论文」")

        report = TrayTransferReport(moved: ["a"], copied: ["b"], keptOriginals: 1)
        XCTAssertEqual(report.summary(destination: "暂存"), "已移进「暂存」1 项，另拷贝 1 项（1 项在别的磁盘或移不动，原件留着）")

        report = TrayTransferReport(moved: ["a"], failures: [TrayFailure(name: "x.mov", reason: "没有权限")])
        XCTAssertEqual(report.summary(destination: "暂存"), "已移进「暂存」1 项；「x.mov」没放进来：没有权限")

        report = TrayTransferReport(failures: [TrayFailure(name: "x", reason: "r"), TrayFailure(name: "y", reason: "r")])
        XCTAssertEqual(report.summary(destination: "暂存"), "2 项没放进来：r")

        XCTAssertEqual(TrayDeleteReport(trashed: 2).summary, "已移到废纸篓 2 项，可以从废纸篓放回")
        XCTAssertEqual(TrayDeleteReport(removed: 1).summary, "已删除 1 项")
    }

    func testPermissionErrorsSayWhoRefused() {
        func cocoa(_ code: CocoaError.Code, posix: POSIXErrorCode?) -> CocoaError {
            guard let posix else { return CocoaError(code) }
            let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(posix.rawValue))
            return CocoaError(code, userInfo: [NSUnderlyingErrorKey: underlying])
        }
        // What macOS throws for Desktop or Downloads without the drop's access: 513 over EPERM.
        XCTAssertEqual(TrayError.describe(cocoa(.fileWriteNoPermission, posix: .EPERM)), TrayError.privacyBlocked)
        XCTAssertEqual(TrayError.describe(cocoa(.fileReadNoPermission, posix: .EPERM)), TrayError.privacyBlocked)
        XCTAssertEqual(TrayError.describe(POSIXError(.EPERM)), TrayError.privacyBlocked)
        XCTAssertTrue(TrayError.privacyBlocked.contains("文件与文件夹"))

        XCTAssertEqual(TrayError.describe(cocoa(.fileReadNoPermission, posix: .EACCES)), "没有读取它的权限")
        XCTAssertEqual(TrayError.describe(cocoa(.fileWriteNoPermission, posix: .EACCES)), "没有写入那里的权限")
        XCTAssertEqual(TrayError.describe(cocoa(.fileReadNoPermission, posix: nil)), "没有权限")
        XCTAssertEqual(TrayError.describe(cocoa(.fileWriteOutOfSpace, posix: nil)), "磁盘空间不够")

        XCTAssertTrue(TrayError.isNoSuchFile(cocoa(.fileReadNoSuchFile, posix: nil)))
        XCTAssertTrue(TrayError.isNoSuchFile(POSIXError(.ENOENT)))
        XCTAssertFalse(TrayError.isNoSuchFile(cocoa(.fileReadNoPermission, posix: .EACCES)))
    }

    func testDroppedFileURLsComeInEveryPasteboardShape() {
        let file = URL(fileURLWithPath: "/tmp/放着/a b.txt")
        XCTAssertEqual(TrayInbound.fileURL(from: file)?.path, file.path)
        XCTAssertEqual(TrayInbound.fileURL(from: file.dataRepresentation)?.path, file.path)
        XCTAssertEqual(TrayInbound.fileURL(from: Data(file.absoluteString.utf8))?.path, file.path)
        XCTAssertEqual(TrayInbound.fileURL(from: Data("/tmp/放着/a b.txt\0".utf8))?.path, file.path)
        XCTAssertEqual(TrayInbound.fileURL(from: " /tmp/放着/a b.txt\n")?.path, file.path)
        XCTAssertEqual(TrayInbound.fileURL(from: file.absoluteString)?.path, file.path)
        XCTAssertNil(TrayInbound.fileURL(from: "https://x.ai/grok"))
        XCTAssertNil(TrayInbound.fileURL(from: Data()))
        XCTAssertNil(TrayInbound.fileURL(from: nil))
        XCTAssertNil(TrayInbound.fileURL(from: 42))

        XCTAssertEqual(TrayInbound.fileURLs([file, URL(string: "https://x.ai")!]), [file])
    }

    func testDropAccessStartsAtOnceAndEndsExactlyOnce() {
        let log = AccessLog()
        let a = URL(fileURLWithPath: "/tmp/a.txt")
        let b = URL(fileURLWithPath: "/tmp/b.txt")
        let plain = URL(fileURLWithPath: "/tmp/plain.txt")

        let access = log.access([a, b, plain], granted: { $0 != plain })
        XCTAssertEqual(log.started, [a, b, plain], "started while the drop is still being handled")
        XCTAssertEqual(log.stopped, [])

        access.end()
        access.end()
        XCTAssertEqual(log.stopped, [a, b], "only what was granted is stopped, and only once")

        do { _ = log.access([plain]) }
        XCTAssertEqual(log.stopped, [a, b, plain], "a forgotten access still ends")
    }

    func testTheFilesToTransferAreExactlyTheURLsAccessStartedOn() {
        let log = AccessLog()
        let a = URL(fileURLWithPath: "/tmp/桌面/a.txt")
        let plain = URL(fileURLWithPath: "/tmp/下载/plain.txt")
        let link = URL(string: "https://x.ai")!

        let drop = log.access([a, link, plain], granted: { $0 != plain })

        XCTAssertEqual(drop.urls, [a, plain], "a URL whose access did not start is still brought in")
        XCTAssertEqual(log.started, drop.urls, "access starts on the very values the tray moves or copies")
        XCTAssertEqual(drop.startedCount, 1)
        XCTAssertEqual(TrayInbound.filePath(a), a, "a path URL is not rebuilt")
    }


    func testDropModeFlips() {
        XCTAssertEqual(TrayDropMode.move.flipped, .copy)
        XCTAssertEqual(TrayDropMode.copy.flipped, .move)
    }

    func testOutsideFilesFollowTheModeOptionAndTheSourceApp() {
        XCTAssertEqual(TrayDropIntent.forOutsideFiles(mode: .move, option: false), .move)
        XCTAssertEqual(TrayDropIntent.forOutsideFiles(mode: .move, option: true), .copy)
        XCTAssertEqual(TrayDropIntent.forOutsideFiles(mode: .copy, option: false), .copy)
        XCTAssertEqual(TrayDropIntent.forOutsideFiles(mode: .copy, option: true), .move)
        XCTAssertEqual(
            TrayDropIntent.forOutsideFiles(mode: .move, option: false, sourceAllowsMove: false), .copy,
            "an app that only offers copies never loses its file"
        )
        XCTAssertEqual(TrayDropIntent.forOutsideFiles(mode: .copy, option: true, sourceAllowsMove: false), .copy)
    }

    func testTrayItemsOnlyMoveAndOnlyWhereSomethingChanges() {
        XCTAssertEqual(TrayDropIntent.forTrayItems(["a.txt"], into: "归档"), .move)
        XCTAssertEqual(TrayDropIntent.forTrayItems(["归档/a.txt"], into: ""), .move)
        XCTAssertEqual(TrayDropIntent.forTrayItems(["a.txt"], into: ""), .refuse, "already there")
        XCTAssertEqual(TrayDropIntent.forTrayItems(["归档"], into: "归档/旧"), .refuse, "a folder cannot go inside itself")
        XCTAssertNil(TrayDropIntent.refuse.mode)
        XCTAssertEqual(TrayDropIntent.copy.mode, .copy)
    }
}

@MainActor
final class FileTrayModelTests: XCTestCase {
    private func makeTray(_ box: TraySandbox, suite: String = "GrokIslandTrayTests-\(UUID().uuidString)") -> FileTray {
        FileTray(fileSystem: box.fileSystem, defaults: UserDefaults(suiteName: suite)!)
    }

    func testReceiveSelectsWhatArrivedAndSaysSo() async throws {
        let box = try TraySandbox()
        let tray = makeTray(box)
        let a = try box.desktopFile("a.txt")
        let b = try box.desktopFile("b.txt")

        let report = await tray.receive([a, b])

        XCTAssertEqual(Set(report.moved), ["a.txt", "b.txt"])
        XCTAssertEqual(Set(tray.entries.map(\.name)), ["a.txt", "b.txt"])
        XCTAssertEqual(tray.selection.paths, ["a.txt", "b.txt"])
        XCTAssertEqual(tray.notice?.text, "已移进「暂存」2 项")
        XCTAssertEqual(tray.rootCount, 2)
        XCTAssertFalse(tray.isImporting)
    }

    func testEmptyDropSaysNothingWasTaken() async throws {
        let tray = makeTray(try TraySandbox())
        let log = AccessLog()
        await tray.take(log.access([URL(string: "https://x.ai")!])).value
        XCTAssertEqual(tray.notice?.isProblem, true)
        XCTAssertEqual(log.started, [], "a link is neither started nor brought in")
    }

    func testADropMovesBeforeTakeReturnsThenEndsItsAccess() async throws {
        let box = try TraySandbox()
        let tray = makeTray(box)
        let a = try box.desktopFile("a.txt")
        let log = AccessLog()

        let task = tray.take(log.access([a]))

        // No await yet: still inside the drop callback, as far as the drop is concerned.
        XCTAssertTrue(box.exists(box.root.appendingPathComponent("a.txt")))
        XCTAssertFalse(box.exists(a))
        XCTAssertEqual(tray.entries.map(\.name), ["a.txt"])
        XCTAssertEqual(tray.notice?.text, "已移进「暂存」1 项")
        XCTAssertFalse(tray.isImporting)
        XCTAssertEqual(log.stopped, [a])

        let report = await task.value
        XCTAssertEqual(report.moved, ["a.txt"])
    }

    func testCopiesHoldTheDropAccessUntilTheyAreDone() async throws {
        let box = try TraySandbox()
        let tray = makeTray(box)
        let moved = try box.desktopFile("moved.txt")
        let readOnly = try box.desktopFolder("只读", files: ["kept.txt": "kept"])
        let kept = readOnly.appendingPathComponent("kept.txt")
        let log = AccessLog()

        let report = try await box.withPermissions(0o555, on: readOnly) { () async -> TrayTransferReport in
            let task = tray.take(log.access([moved, kept]), mode: .move)

            XCTAssertEqual(tray.entries.map(\.name), ["moved.txt"], "the rename shows up right away")
            XCTAssertTrue(tray.isImporting)
            XCTAssertEqual(log.stopped, [], "the copy has not run yet")

            return await task.value
        }

        XCTAssertEqual(report.moved, ["moved.txt"])
        XCTAssertEqual(report.copied, ["kept.txt"])
        XCTAssertEqual(Set(log.stopped), [moved, kept])
        XCTAssertFalse(tray.isImporting)
        XCTAssertTrue(box.exists(kept), "an original that cannot move stays where it was")
        XCTAssertEqual(Set(tray.entries.map(\.name)), ["moved.txt", "kept.txt"])
        XCTAssertEqual(tray.notice?.text, "已移进「暂存」1 项，另拷贝 1 项（1 项在别的磁盘或移不动，原件留着）")
    }

    func testOpenAndGoUpAndAVanishedFolderFallsBackToTheRoot() async throws {
        let box = try TraySandbox()
        try box.trayFile("论文/草稿.docx")
        let tray = makeTray(box)

        tray.open("论文")
        XCTAssertEqual(tray.folder, "论文")
        XCTAssertEqual(tray.entries.map(\.path), ["论文/草稿.docx"])
        XCTAssertEqual(tray.rootCount, 1, "the tab badge still counts the root")

        tray.goUp()
        XCTAssertEqual(tray.folder, "")
        XCTAssertEqual(tray.selection.paths, ["论文"], "coming back up highlights where you were")

        tray.open("论文")
        try FileManager.default.removeItem(at: box.root.appendingPathComponent("论文"))
        tray.refresh()
        XCTAssertEqual(tray.folder, "")
        XCTAssertTrue(tray.entries.isEmpty)

        tray.open("nope")
        XCTAssertEqual(tray.folder, "")
        XCTAssertEqual(tray.notice?.isProblem, true)
    }

    func testDropModeIsRemembered() async throws {
        let box = try TraySandbox()
        let suite = "GrokIslandTrayTests-\(UUID().uuidString)"
        let tray = makeTray(box, suite: suite)
        XCTAssertEqual(tray.dropMode, .move, "moving off the Desktop is the default")
        tray.dropMode = .copy
        XCTAssertEqual(makeTray(box, suite: suite).dropMode, .copy)
    }

    func testNewFolderIsReadyToNameThenRenamed() async throws {
        let box = try TraySandbox()
        let tray = makeTray(box)
        let path = try XCTUnwrap(tray.createFolder())
        XCTAssertEqual(tray.renamingPath, path)
        XCTAssertEqual(tray.selection.paths, [path])

        XCTAssertTrue(tray.rename(path, to: "课程"))
        XCTAssertNil(tray.renamingPath)
        XCTAssertEqual(tray.entries.map(\.name), ["课程"])
        XCTAssertEqual(tray.selection.paths, ["课程"])

        XCTAssertFalse(tray.rename("课程", to: ""))
        XCTAssertEqual(tray.notice?.text, TrayError.nameEmpty.localizedDescription)
    }

    func testGroupingTheSelectionIntoANewFolder() async throws {
        let box = try TraySandbox()
        try box.trayFile("1.png")
        try box.trayFile("2.png")
        try box.trayFile("keep.txt")
        let tray = makeTray(box)

        let folder = try XCTUnwrap(tray.groupIntoNewFolder(["1.png", "2.png"]))

        XCTAssertEqual(tray.entries.map(\.name), [TrayNaming.newFolderName, "keep.txt"])
        XCTAssertEqual(Set(try box.names(folder)), ["1.png", "2.png"])
        XCTAssertEqual(tray.renamingPath, folder)
    }

    func testMoveAndDeleteKeepTheSelectionHonest() async throws {
        let box = try TraySandbox()
        try box.trayFolder("归档")
        try box.trayFile("a.txt")
        try box.trayFile("b.txt")
        let tray = makeTray(box)
        tray.selection.selectAll(tray.orderedPaths)

        tray.move(["a.txt"], into: "归档")
        XCTAssertEqual(tray.selection.paths, ["归档", "b.txt"])
        XCTAssertEqual(tray.notice?.text, "已移进「归档」1 项")

        tray.delete(["b.txt"])
        XCTAssertEqual(tray.selection.paths, ["归档"])
        XCTAssertEqual(tray.entries.map(\.name), ["归档"])
    }

    func testDragOutCountsWhatFinderTookBack() async throws {
        let box = try TraySandbox()
        let file = try box.trayFile("给桌面.txt")
        try box.trayFile("留下.txt")
        let tray = makeTray(box)

        tray.beginDragOut(["给桌面.txt", "留下.txt"])
        XCTAssertTrue(tray.isDraggingOut)
        try FileManager.default.moveItem(at: file, to: box.desktop.appendingPathComponent("给桌面.txt"))
        await tray.finishDragOut(droppedOutside: true, operationWasCopy: false, cancelled: false)

        XCTAssertFalse(tray.isDraggingOut)
        XCTAssertEqual(tray.entries.map(\.name), ["留下.txt"])
        XCTAssertEqual(tray.notice?.text, "已拿回 1 项，还有 1 项留在暂存区")
    }

    func testDropIntentTellsTrayItemsFromNewFiles() async throws {
        let box = try TraySandbox()
        try box.trayFolder("归档")
        let inTray = try box.trayFile("a.txt")
        let fromDesktop = try box.desktopFile("new.txt")
        let tray = makeTray(box)

        XCTAssertEqual(tray.dropIntent(for: [inTray], into: "", option: false), .refuse)
        XCTAssertEqual(tray.dropIntent(for: [inTray], into: "归档", option: true), .move, "⌥ does not copy within the tray")
        XCTAssertEqual(tray.dropIntent(for: [fromDesktop], into: "", option: false), .move)
        XCTAssertEqual(tray.dropIntent(for: [fromDesktop], into: "", option: true), .copy)
        XCTAssertEqual(tray.dropIntent(for: [inTray, fromDesktop], into: "", option: false), .move, "a mix counts as new files")
        XCTAssertEqual(tray.dropIntent(for: [fromDesktop], into: "", option: false, sourceAllowsMove: false), .copy)

        tray.dropMode = .copy
        XCTAssertEqual(tray.dropIntent(for: nil, into: "", option: false), .copy, "unknown URLs from outside follow the mode")

        tray.beginDragOut(["a.txt"])
        XCTAssertEqual(tray.dropIntent(for: nil, into: "", option: false), .refuse, "a drag out stands in for unknown URLs")
        XCTAssertEqual(tray.dropIntent(for: nil, into: "归档", option: false), .move)
        await tray.finishDragOut(droppedOutside: false, operationWasCopy: false, cancelled: true)
    }

    func testDragOutThatStaysInsideTheIslandSaysNothing() async throws {
        let box = try TraySandbox()
        try box.trayFile("a.txt")
        let tray = makeTray(box)
        tray.beginDragOut(["a.txt"])
        await tray.finishDragOut(droppedOutside: false, operationWasCopy: false, cancelled: false)
        XCTAssertNil(tray.notice)
        XCTAssertFalse(tray.isDraggingOut)
    }
}
