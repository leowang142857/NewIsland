import Foundation

/// Geometry and reveal rule for the collapsed peek strip. AppKit-free so it can be tested.
///
/// The strip is a small pill hanging from the bottom of the menu bar. On a notched Mac it is
/// exactly as wide as the notch and sits right under it, so it reads as the camera housing's
/// shadow; it never reaches up into the menu bar, which stays fully visible and clickable.
enum PeekStrip {
    static let height: CGFloat = 22
    /// Lock + three lights on the left, or a `12小时` DDL badge on the right.
    static let slotWidth: CGFloat = 56
    /// Concave curve where the strip meets the bar above it, like the notch's own corners.
    static let flare: CGFloat = 6
    /// Leftmost slice, flare included, holding the lock. Hovering it never expands the island,
    /// so the lock can be reached.
    static let lockZoneWidth: CGFloat = 24
    /// From the right-hand flare to the DDL badge.
    static let trailingInset: CGFloat = 4
    /// Room for the name between the slots when there is no notch.
    static let nameGapWidth: CGFloat = 52

    static var defaultWidth: CGFloat { 2 * slotWidth + nameGapWidth }
    /// Both slots always fit, whatever a scaled display reports for its notch.
    static var minimumWidth: CGFloat { 2 * slotWidth }

    /// The notch's own width, so the strip stays inside the camera's shadow; the plain default without one.
    static func width(notchWidth: CGFloat?) -> CGFloat {
        guard let notchWidth, notchWidth > 0 else { return defaultWidth }
        return max(minimumWidth, notchWidth)
    }

    /// Three dots fit a slot; past that show two dots and a `+N`.
    static func lightLimit(count: Int) -> Int {
        count > 3 ? 2 : 3
    }

    static func isOnLock(mouseX: CGFloat, stripMinX: CGFloat) -> Bool {
        mouseX >= stripMinX && mouseX < stripMinX + lockZoneWidth
    }

    /// Whether the collapsed strip should expand. While locked it never does, not even for a drag.
    static func shouldReveal(
        locked: Bool,
        mouseInStrip: Bool,
        mouseOnLock: Bool,
        dropTargeted: Bool,
        pinned: Bool,
        awaitingConfirmation: Bool
    ) -> Bool {
        if locked { return false }
        return (mouseInStrip && !mouseOnLock) || dropTargeted || pinned || awaitingConfirmation
    }
}

/// The expanded island: a wide, short panel under the notch, three times as wide as it is tall,
/// like a Dynamic Island that has opened up.
enum IslandShell {
    static let idealHeight: CGFloat = 300
    /// Width over height when the screen has the room.
    static let aspect: CGFloat = 3
    /// Floors on very small or heavily scaled displays, so the two columns never squeeze shut:
    /// at 272 pt the home's left column (DDL, shortcut tiles, both fields) still shows whole.
    static let minimumWidth: CGFloat = 720
    static let minimumHeight: CGFloat = 272
    /// Kept clear of the screen's left and right edges.
    static let sideMargin: CGFloat = 16
    /// Kept clear above the Dock, or the bottom of the screen when the Dock hides.
    static let bottomMargin: CGFloat = 12
    /// Between the bottom of the menu bar (and the notch) and the island's top edge.
    static let menuBarGap: CGFloat = 6

    static var idealWidth: CGFloat { idealHeight * aspect }

    /// `room` runs from the expanded island's top edge down to the bottom of the visible frame.
    static func size(screenWidth: CGFloat, room: CGFloat) -> CGSize {
        let width = min(idealWidth, screenWidth - 2 * sideMargin)
        let height = min(idealHeight, room - bottomMargin)
        return CGSize(
            width: max(minimumWidth, width).rounded(.down),
            height: max(minimumHeight, height).rounded(.down)
        )
    }
}

/// Where the strip and the island sit on a screen (AppKit coordinates, y up). Both hang below
/// the menu bar and are centered on the screen, which puts them under the notch.
enum IslandPlacement {
    /// Around the expanded island that still counts as on it, so a button at its edge doesn't retract it.
    static let hoverSlop: CGFloat = 4

    /// Top of the screen down to the bottom of the menu bar. Takes the largest of the menu bar
    /// the visible frame leaves out, the notch (the menu bar grows to match it), and the bar's
    /// own thickness for when it hides until the pointer reaches the top.
    static func menuBarHeight(frame: CGRect, visibleFrame: CGRect, notchHeight: CGFloat, barThickness: CGFloat) -> CGFloat {
        max(frame.maxY - visibleFrame.maxY, notchHeight, barThickness, 0)
    }

    /// Collapsed: hangs from the bottom of the menu bar.
    static func stripFrame(size: CGSize, screen: CGRect, menuBarHeight: CGFloat) -> CGRect {
        hanging(size: size, screen: screen, top: screen.maxY - menuBarHeight)
    }

    /// Expanded: `IslandShell.menuBarGap` below the menu bar.
    static func shellFrame(size: CGSize, screen: CGRect, menuBarHeight: CGFloat) -> CGRect {
        hanging(size: size, screen: screen, top: shellTop(screen: screen, menuBarHeight: menuBarHeight))
    }

    static func shellTop(screen: CGRect, menuBarHeight: CGFloat) -> CGFloat {
        screen.maxY - menuBarHeight - IslandShell.menuBarGap
    }

    /// Where the pointer keeps things as they are. Collapsed: the strip itself. Expanded: the island
    /// and its slop, up to the bottom of the menu bar, so resting where the strip was doesn't
    /// retract it only to reopen it. Neither reaches into the menu bar.
    static func hotZone(revealed: Bool, frame: CGRect, screen: CGRect, menuBarHeight: CGFloat) -> CGRect {
        guard revealed else { return frame }
        let zone = frame.insetBy(dx: -hoverSlop, dy: -hoverSlop)
        let top = screen.maxY - menuBarHeight
        return CGRect(x: zone.minX, y: zone.minY, width: zone.width, height: top - zone.minY)
    }

    private static func hanging(size: CGSize, screen: CGRect, top: CGFloat) -> CGRect {
        CGRect(x: (screen.midX - size.width / 2).rounded(), y: top - size.height, width: size.width, height: size.height)
    }
}
