import Foundation

/// Geometry and reveal rule for the collapsed peek strip. AppKit-free so it can be tested.
///
/// On a notched Mac the strip hugs the camera housing: two short wings either side of the
/// notch (lock + task lights on the left, DDL badge on the right), nothing wider, and exactly
/// as tall as the notch so the wings read as part of it.
enum PeekStrip {
    /// Height without a notch, where the strip sits under the menu bar.
    static let height: CGFloat = 22
    /// Tallest strip, whatever a scaled display reports for its notch.
    static let maxHeight: CGFloat = 44
    /// Visible strip each side of the notch. Fits lock + three lights, or a `12小时` DDL badge.
    static let wingWidth: CGFloat = 56
    /// Leftmost slice holding the lock. Hovering it never expands the island, so the lock can be reached.
    static let lockZoneWidth: CGFloat = 22
    static let trailingInset: CGFloat = 8
    /// Room for the name between the wings when there is no notch.
    static let nameGapWidth: CGFloat = 52

    static var defaultWidth: CGFloat { 2 * wingWidth + nameGapWidth }

    /// Notch width plus one wing each side; the plain default without a notch.
    static func width(notchWidth: CGFloat?) -> CGFloat {
        guard let notchWidth, notchWidth > 0 else { return defaultWidth }
        return max(defaultWidth, notchWidth + 2 * wingWidth)
    }

    /// The notch's own height, so the wings line up with the camera housing; the plain default without one.
    static func height(notchHeight: CGFloat?) -> CGFloat {
        guard let notchHeight, notchHeight > 0 else { return height }
        return min(maxHeight, max(height, notchHeight))
    }

    /// Three dots fit a wing; past that show two dots and a `+N`.
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

/// The expanded island: one narrow column hanging under the notch, about three times as tall as
/// it is wide, so it reads as a vertical strip rather than a wide card.
enum IslandShell {
    static let width: CGFloat = 264
    /// Height over width when the screen has the room.
    static let aspect: CGFloat = 3
    /// Floor on short or heavily scaled displays, so the layers never squeeze past the old fixed height.
    static let minimumHeight: CGFloat = 520
    /// Kept clear above the Dock, or the bottom of the screen when the Dock hides.
    static let bottomMargin: CGFloat = 12

    static var idealHeight: CGFloat { width * aspect }

    /// `room` runs from the expanded island's top edge down to the bottom of the visible frame.
    static func size(room: CGFloat) -> CGSize {
        let fitted = min(idealHeight, room - bottomMargin)
        return CGSize(width: width, height: max(minimumHeight, fitted).rounded(.down))
    }
}
