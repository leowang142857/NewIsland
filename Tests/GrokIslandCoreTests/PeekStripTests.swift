import XCTest
#if canImport(GrokIslandCore)
@testable import GrokIslandCore
#else
@testable import GrokIsland
#endif

final class PeekStripGeometryTests: XCTestCase {
    func testNotchedStripHugsTheCameraHousing() {
        let notch: CGFloat = 190
        let width = PeekStrip.width(notchWidth: notch)
        XCTAssertEqual(width, notch + 2 * PeekStrip.wingWidth)
        XCTAssertLessThan(width, notch + 2 * 108, "narrower than the old 108 pt wings")
        XCTAssertLessThanOrEqual(width - notch, 120, "only short wings either side of the notch")
    }

    func testNoNotchUsesTheCompactDefault() {
        XCTAssertEqual(PeekStrip.width(notchWidth: nil), PeekStrip.defaultWidth)
        XCTAssertEqual(PeekStrip.width(notchWidth: 0), PeekStrip.defaultWidth)
        XCTAssertLessThan(PeekStrip.defaultWidth, 240, "narrower than the old 240 pt bar")
        XCTAssertEqual(PeekStrip.width(notchWidth: 10), PeekStrip.defaultWidth, "never smaller than the default")
    }

    func testLeftWingFitsLockAndLights() {
        let dot: CGFloat = 6 * 1.4
        let threeDots = 3 * dot + 2 * 2
        XCTAssertLessThanOrEqual(PeekStrip.lockZoneWidth + 2 + threeDots, PeekStrip.wingWidth)
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
