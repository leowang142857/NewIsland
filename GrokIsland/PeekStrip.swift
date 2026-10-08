import Foundation

/// Geometry and reveal rule for the collapsed peek strip. AppKit-free so it can be tested.
///
/// On a notched Mac the strip hugs the camera housing: two short wings either side of the
/// notch (lock + task lights on the left, DDL badge on the right), nothing wider.
enum PeekStrip {
    static let height: CGFloat = 22
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
