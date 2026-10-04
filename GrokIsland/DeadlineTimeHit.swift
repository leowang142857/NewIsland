import Foundation

/// Hit testing for the expanded DDL editor's time control.
///
/// Screen coordinates: origin at the bottom left, y increasing upward (AppKit).
/// The time field sits on the bottom edge of the DDL card, directly above the
/// Ask Grok bar. Hover-dismiss uses the card bounds, so a click or drag that
/// slips a few points below the time field used to count as "outside", collapse
/// the editor, and land on that bar. The claim rect keeps that strip.
enum DeadlinePointerPhase: Equatable {
    case hover
    case mouseDown
    case mouseDragged
    case mouseUp
}

struct DeadlineTimeInteraction: Equatable {
    /// Pointer is on the DDL card, in the strip under the time field, or a press
    /// that started on the time control is still in progress.
    var pointerOwnsPanel: Bool
    /// Mouse button is down on the time control (click or vertical drag).
    var tracking: Bool
    /// This mouseDown is in the strip under the card and must not be delivered
    /// to the Ask Grok bar. Drags and mouse-up stay with the control that
    /// received mouse-down, so they are not absorbed here.
    var absorbPointer: Bool
}

enum DeadlineTimeHit {
    /// How far below the time field the pointer may sit and still belong to it.
    /// Covers the card's bottom padding, the gap under the card, and the top of
    /// the Grok bar directly beneath the control — not the whole bar.
    static let slopBelow: CGFloat = 36
    /// Diagonal slips still count; neighboring buttons in the same row do not.
    static let slopSide: CGFloat = 8
    /// A vertical drag that changes the hour or minute can travel well past the
    /// resting slop and still belongs to the time control.
    static let trackingReach: CGFloat = 160

    /// Time field plus the strip underneath it. Does not grow upward.
    static func claimRect(timeField: CGRect, tracking: Bool) -> CGRect {
        let below = tracking ? max(trackingReach, slopBelow) : slopBelow
        return CGRect(
            x: timeField.minX - slopSide,
            y: timeField.minY - below,
            width: timeField.width + slopSide * 2,
            height: timeField.height + below
        )
    }

    static func decide(
        phase: DeadlinePointerPhase,
        point: CGPoint,
        panel: CGRect,
        timeField: CGRect,
        tracking: Bool,
        attachedPopup: Bool = false
    ) -> DeadlineTimeInteraction {
        let fieldReady = isUsable(timeField)
        let panelReady = isUsable(panel)
        let inField = fieldReady && timeField.contains(point)
        let inClaim = fieldReady && claimRect(timeField: timeField, tracking: tracking).contains(point)
        let inPanel = panelReady && panel.contains(point)
        // Only the part of the claim that has left the card. Controls inside the
        // card (clear, cancel) keep their own clicks.
        let inSlop = inClaim && panelReady && !inPanel

        var nowTracking = tracking
        switch phase {
        case .mouseDown:
            if !attachedPopup && (inField || inSlop) { nowTracking = true }
        case .mouseUp:
            nowTracking = false
        case .mouseDragged, .hover:
            break
        }

        var owns = inPanel || inClaim
        if phase == .mouseDown && !attachedPopup && (inField || inSlop) { owns = true }
        if tracking && (phase == .mouseDragged || phase == .mouseUp) {
            owns = true
        }
        // The calendar popup is a child window. Moving onto it is not "leaving"
        // the editor, and its clicks belong to that popup, not the Grok bar.
        if attachedPopup { owns = true }

        let absorb = phase == .mouseDown && inSlop && !attachedPopup
        return DeadlineTimeInteraction(
            pointerOwnsPanel: owns,
            tracking: nowTracking,
            absorbPointer: absorb
        )
    }

    /// Whether the expanded DDL editor stays up. Mirrors `DeadlineEnergyBar`.
    static func staysOpen(
        cardHover: Bool,
        pointerOwnsPanel: Bool,
        tracking: Bool,
        fieldFocused: Bool,
        hasDraft: Bool,
        isEditing: Bool
    ) -> Bool {
        cardHover || pointerOwnsPanel || tracking || fieldFocused || hasDraft || isEditing
    }

    private static func isUsable(_ rect: CGRect) -> Bool {
        rect.width > 1 && rect.height > 1 && !rect.isInfinite && !rect.isNull
    }
}
