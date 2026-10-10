import XCTest
#if canImport(GrokIslandCore)
@testable import GrokIslandCore
#else
@testable import GrokIsland
#endif

final class PeekStripGeometryTests: XCTestCase {
    func testNotchedStripIsExactlyAsWideAsTheNotch() {
        XCTAssertEqual(PeekStrip.width(notchWidth: 190), 190, "inside the camera's shadow, no wings")
        XCTAssertEqual(PeekStrip.width(notchWidth: 230), 230, "a wider housing at another display scale")
        XCTAssertEqual(PeekStrip.width(notchWidth: 90), PeekStrip.minimumWidth, "an odd report still fits both slots")
    }

    func testNoNotchUsesTheCompactDefault() {
        XCTAssertEqual(PeekStrip.width(notchWidth: nil), PeekStrip.defaultWidth)
        XCTAssertEqual(PeekStrip.width(notchWidth: 0), PeekStrip.defaultWidth)
        XCTAssertLessThan(PeekStrip.defaultWidth, 240, "narrower than the old 240 pt bar")
    }

    func testSlotsFitLockLightsAndBadge() {
        let dot: CGFloat = 6 * 1.4
        let threeDots = 3 * dot + 2 * 2
        XCTAssertLessThanOrEqual(PeekStrip.lockZoneWidth + 2 + threeDots, PeekStrip.slotWidth)
        XCTAssertGreaterThanOrEqual(PeekStrip.lockZoneWidth - PeekStrip.flare, 18, "the lock stays easy to hit past the flare")
        XCTAssertLessThan(PeekStrip.minimumWidth, 185, "both slots fit under a typical notch")
        XCTAssertEqual(PeekStrip.lightLimit(count: 0), 3)
        XCTAssertEqual(PeekStrip.lightLimit(count: 3), 3)
        XCTAssertEqual(PeekStrip.lightLimit(count: 7), 2, "two dots plus +N when crowded")
    }

    func testLockZoneIsTheLeftmostSlice() {
        XCTAssertTrue(PeekStrip.isOnLock(mouseX: 100, stripMinX: 100))
        XCTAssertTrue(PeekStrip.isOnLock(mouseX: 100 + PeekStrip.lockZoneWidth - 1, stripMinX: 100))
        XCTAssertFalse(PeekStrip.isOnLock(mouseX: 100 + PeekStrip.lockZoneWidth, stripMinX: 100))
        XCTAssertFalse(PeekStrip.isOnLock(mouseX: 99, stripMinX: 100))
    }
}

final class IslandShellGeometryTests: XCTestCase {
    func testRoomyScreenGetsAPanelThreeTimesAsWideAsTall() {
        let size = IslandShell.size(screenWidth: 1710, room: 2000)
        XCTAssertEqual(size.width, IslandShell.idealWidth)
        XCTAssertEqual(size.height, IslandShell.idealHeight)
        XCTAssertEqual(size.width / size.height, 3, accuracy: 0.01)
    }

    func testFullPanelFitsA13InchMacBookAir() {
        // 1470 x 956 pt by default; menu bar as tall as the notch, about 32 pt; Dock 70 pt.
        let room: CGFloat = 956 - 32 - IslandShell.menuBarGap - 70
        let size = IslandShell.size(screenWidth: 1470, room: room)
        XCTAssertEqual(size, CGSize(width: 900, height: 300))
        XCTAssertEqual(size.width / size.height, 3, accuracy: 0.01)
        XCTAssertLessThanOrEqual(size.width, 1470 - 2 * IslandShell.sideMargin)
    }

    func testSmallestScaledAirStillGetsTheFullPanel() {
        // "Larger Text" at its biggest: 1024 x 665 pt.
        let size = IslandShell.size(screenWidth: 1024, room: 665 - 32 - IslandShell.menuBarGap - 70)
        XCTAssertEqual(size.width / size.height, 3, accuracy: 0.01)
    }

    func testNarrowOrShortScreensShrinkDownToFloors() {
        let narrow = IslandShell.size(screenWidth: 800, room: 2000)
        XCTAssertEqual(narrow.width, 800 - 2 * IslandShell.sideMargin)
        XCTAssertEqual(narrow.height, IslandShell.idealHeight)
        XCTAssertEqual(IslandShell.size(screenWidth: 500, room: 2000).width, IslandShell.minimumWidth)
        XCTAssertEqual(IslandShell.size(screenWidth: 1470, room: 290.6).height, 278, "lands on whole points")
        XCTAssertEqual(IslandShell.size(screenWidth: 1470, room: 100).height, IslandShell.minimumHeight)
        XCTAssertGreaterThan(IslandShell.minimumHeight, 62 + 208, "header, padding, and the home's left column")
    }
}

final class IslandPlacementTests: XCTestCase {
    /// 13" MacBook Air at 1470 x 956 pt with the Dock at the bottom.
    private let screen = CGRect(x: 0, y: 0, width: 1470, height: 956)
    private let visible = CGRect(x: 0, y: 70, width: 1470, height: 956 - 70 - 32)

    func testMenuBarHeightCoversShownHiddenAndNotchedBars() {
        XCTAssertEqual(IslandPlacement.menuBarHeight(frame: screen, visibleFrame: visible, notchHeight: 32, barThickness: 24), 32)
        let autoHidden = CGRect(x: 0, y: 70, width: 1470, height: 956 - 70)
        XCTAssertEqual(IslandPlacement.menuBarHeight(frame: screen, visibleFrame: autoHidden, notchHeight: 32, barThickness: 24), 32, "the notch still reserves the bar")
        let external = CGRect(x: 1470, y: 0, width: 1920, height: 1080)
        let externalVisible = CGRect(x: 1470, y: 0, width: 1920, height: 1080 - 25)
        XCTAssertEqual(IslandPlacement.menuBarHeight(frame: external, visibleFrame: externalVisible, notchHeight: 0, barThickness: 24), 25)
        XCTAssertEqual(IslandPlacement.menuBarHeight(frame: external, visibleFrame: external, notchHeight: 0, barThickness: 24), 24, "a hiding bar still gets its room")
    }

    func testCollapsedStripHangsUnderTheNotchWithoutTouchingTheMenuBar() {
        let bar: CGFloat = 32
        let size = CGSize(width: PeekStrip.width(notchWidth: 190), height: PeekStrip.height)
        let strip = IslandPlacement.stripFrame(size: size, screen: screen, menuBarHeight: bar)
        XCTAssertEqual(strip.maxY, menuBarBottom(bar), "top edge on the bottom of the menu bar, never above it")
        XCTAssertEqual(strip.midX, screen.midX, accuracy: 0.5, "centered under the notch")
        XCTAssertEqual(strip.width, 190)
    }

    func testExpandedIslandSitsBelowTheMenuBar() {
        let bar: CGFloat = 32
        let shell = expandedShell(menuBarHeight: bar)
        XCTAssertEqual(shell.maxY, menuBarBottom(bar) - IslandShell.menuBarGap, "a small gap under the menu bar")
        XCTAssertEqual(shell.size, CGSize(width: 900, height: 300))
        XCTAssertGreaterThanOrEqual(shell.minY, visible.minY + IslandShell.bottomMargin, "clear of the Dock")
        XCTAssertGreaterThanOrEqual(shell.minX, screen.minX + IslandShell.sideMargin)
        XCTAssertLessThanOrEqual(shell.maxX, screen.maxX - IslandShell.sideMargin)
    }

    func testExpandedHotZoneReachesTheMenuBarButNeverEntersIt() {
        let bar: CGFloat = 32
        let shell = expandedShell(menuBarHeight: bar)
        let zone = IslandPlacement.hotZone(revealed: true, frame: shell, screen: screen, menuBarHeight: bar)
        XCTAssertEqual(zone.maxY, menuBarBottom(bar))
        XCTAssertEqual(zone.minY, shell.minY - IslandPlacement.hoverSlop)
        XCTAssertEqual(zone.minX, shell.minX - IslandPlacement.hoverSlop)
        XCTAssertEqual(zone.maxX, shell.maxX + IslandPlacement.hoverSlop)
        XCTAssertTrue(zone.contains(CGPoint(x: screen.midX, y: menuBarBottom(bar) - 1)), "the gap above the island keeps it open")
        XCTAssertFalse(zone.contains(CGPoint(x: screen.midX, y: menuBarBottom(bar) + 1)), "pointing at the menu bar lets it go")
    }

    func testRetractingNeverLeavesThePointerInTheStrip() {
        // Otherwise the island would reopen the moment it closed.
        let bar: CGFloat = 32
        let zone = IslandPlacement.hotZone(revealed: true, frame: expandedShell(menuBarHeight: bar), screen: screen, menuBarHeight: bar)
        let strip = IslandPlacement.stripFrame(size: CGSize(width: 190, height: PeekStrip.height), screen: screen, menuBarHeight: bar)
        XCTAssertLessThanOrEqual(zone.minX, strip.minX)
        XCTAssertGreaterThanOrEqual(zone.maxX, strip.maxX)
        XCTAssertLessThanOrEqual(zone.minY, strip.minY)
        XCTAssertGreaterThanOrEqual(zone.maxY, strip.maxY)
        XCTAssertEqual(IslandPlacement.hotZone(revealed: false, frame: strip, screen: screen, menuBarHeight: bar), strip, "collapsed, only the strip counts")
    }

    private func expandedShell(menuBarHeight bar: CGFloat) -> CGRect {
        let room = IslandPlacement.shellTop(screen: screen, menuBarHeight: bar) - visible.minY
        let size = IslandShell.size(screenWidth: screen.width, room: room)
        return IslandPlacement.shellFrame(size: size, screen: screen, menuBarHeight: bar)
    }

    private func menuBarBottom(_ height: CGFloat) -> CGFloat {
        screen.maxY - height
    }
}

final class PeekStripRevealTests: XCTestCase {
    private func reveal(
        locked: Bool = false,
        inStrip: Bool = false,
        onLock: Bool = false,
        drop: Bool = false,
        pinned: Bool = false,
        confirm: Bool = false
    ) -> Bool {
        PeekStrip.shouldReveal(
            locked: locked,
            mouseInStrip: inStrip,
            mouseOnLock: onLock,
            dropTargeted: drop,
            pinned: pinned,
            awaitingConfirmation: confirm
        )
    }

    func testUnlockedHoverExpandsExceptOverTheLock() {
        XCTAssertFalse(reveal())
        XCTAssertTrue(reveal(inStrip: true))
        XCTAssertFalse(reveal(inStrip: true, onLock: true), "reaching for the lock must not expand the island")
        XCTAssertTrue(reveal(drop: true))
        XCTAssertTrue(reveal(confirm: true))
    }

    func testLockedStaysCollapsedWhateverHappens() {
        XCTAssertFalse(reveal(locked: true, inStrip: true))
        XCTAssertFalse(reveal(locked: true, drop: true))
        XCTAssertFalse(reveal(locked: true, inStrip: true, drop: true, pinned: true, confirm: true))
    }
}

@MainActor
final class PeekLockPersistenceTests: XCTestCase {
    func testLockSurvivesRelaunchAndUnlockRestoresHover() async {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrokIslandPeek-\(UUID().uuidString)", isDirectory: true)
        let storage = IslandSettingsStorage(folder: folder, defaultsSuite: "GrokIslandTests-\(UUID().uuidString)")
        let settings = IslandSettings(storage: storage)
        XCTAssertFalse(settings.isPeekLocked, "hover-to-expand is on by default")

        settings.isPeekLocked = true
        XCTAssertTrue(IslandSettings(storage: storage).isPeekLocked)

        settings.isPeekLocked = false
        XCTAssertFalse(IslandSettings(storage: storage).isPeekLocked)
    }
}
