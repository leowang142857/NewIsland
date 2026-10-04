import XCTest
#if canImport(GrokIslandCore)
@testable import GrokIslandCore
#else
@testable import GrokIsland
#endif

/// AppKit screen space: y increases upward. The time field sits 6 pt above the
/// bottom of the DDL card; the Ask Grok bar is the next view below that edge.
private enum DDLTimeFixture {
    static let panel = CGRect(x: 100, y: 500, width: 320, height: 160)
    static let timeField = CGRect(x: 112, y: 506, width: 168, height: 22)

    static func decide(
        _ phase: DeadlinePointerPhase,
        _ point: CGPoint,
        tracking: Bool = false,
        attachedPopup: Bool = false
    ) -> DeadlineTimeInteraction {
        DeadlineTimeHit.decide(
            phase: phase,
            point: point,
            panel: panel,
            timeField: timeField,
            tracking: tracking,
            attachedPopup: attachedPopup
        )
    }
}

final class DeadlineTimeHitTests: XCTestCase {
    /// 16 pt under the time field, 10 pt under the card — where the Grok bar starts.
    private let justBelow = CGPoint(x: 180, y: 490)
    /// Far enough to be a real click on the Ask Grok field, not a slip.
    private let questionBar = CGPoint(x: 180, y: 430)
    private let onTimeField = CGPoint(x: 200, y: 516)
    /// Level with the slop, but beside the time field so the rest of the bar still works.
    private let besideSlop = CGPoint(x: 400, y: 490)

    func testClaimExtendsDownwardOnly() {
        let claim = DeadlineTimeHit.claimRect(timeField: DDLTimeFixture.timeField, tracking: false)
        XCTAssertEqual(claim.maxY, DDLTimeFixture.timeField.maxY)
        XCTAssertEqual(claim.minY, DDLTimeFixture.timeField.minY - DeadlineTimeHit.slopBelow)
        XCTAssertEqual(claim.minX, DDLTimeFixture.timeField.minX - DeadlineTimeHit.slopSide)

        let dragging = DeadlineTimeHit.claimRect(timeField: DDLTimeFixture.timeField, tracking: true)
        XCTAssertEqual(dragging.maxY, claim.maxY, "a drag must not claim the rows above the time field")
        XCTAssertLessThan(dragging.minY, claim.minY)
    }

    func testSlightDownwardSlipKeepsTheEditorAndTakesTheClick() {
        let hover = DDLTimeFixture.decide(.hover, justBelow)
        XCTAssertTrue(hover.pointerOwnsPanel)
        XCTAssertFalse(hover.absorbPointer)
        XCTAssertFalse(hover.tracking)
        XCTAssertTrue(staysOpen(hover, cardHover: false))

        let click = DDLTimeFixture.decide(.mouseDown, justBelow)
        XCTAssertTrue(click.pointerOwnsPanel)
        XCTAssertTrue(click.tracking)
        XCTAssertTrue(click.absorbPointer, "the click must not reach the Ask Grok bar")
        XCTAssertTrue(staysOpen(click, cardHover: false))
    }

    func testClickOnTheTimeFieldStaysWithThePickerWhenHoverAlreadyFailed() {
        let click = DDLTimeFixture.decide(.mouseDown, onTimeField)
        XCTAssertTrue(click.pointerOwnsPanel)
        XCTAssertTrue(click.tracking)
        XCTAssertFalse(click.absorbPointer, "the date picker itself handles a hit on its field")
        XCTAssertTrue(staysOpen(click, cardHover: false))
    }

    func testDragBelowTheCardStaysWithTheTimeControlThroughMouseUp() {
        let pressed = DDLTimeFixture.decide(.mouseDown, onTimeField)
        let dragged = DDLTimeFixture.decide(.mouseDragged, questionBar, tracking: pressed.tracking)
        XCTAssertTrue(dragged.pointerOwnsPanel)
        XCTAssertTrue(dragged.tracking)
        XCTAssertFalse(dragged.absorbPointer, "the picker is already tracking this drag")
        XCTAssertTrue(staysOpen(dragged, cardHover: false))

        let released = DDLTimeFixture.decide(.mouseUp, questionBar, tracking: dragged.tracking)
        XCTAssertTrue(released.pointerOwnsPanel, "mouse-up must finish on the time control before the card can close")
        XCTAssertFalse(released.tracking)
        XCTAssertFalse(released.absorbPointer)
        XCTAssertTrue(staysOpen(released, cardHover: false))

        let after = DDLTimeFixture.decide(.hover, questionBar, tracking: released.tracking)
        XCTAssertFalse(after.pointerOwnsPanel)
        XCTAssertFalse(staysOpen(after, cardHover: false))
    }

    func testPointerWellBelowReachesTheAskGrokBar() {
        let hover = DDLTimeFixture.decide(.hover, questionBar)
        XCTAssertFalse(hover.pointerOwnsPanel)
        XCTAssertFalse(hover.absorbPointer)
        XCTAssertFalse(staysOpen(hover, cardHover: false))

        let click = DDLTimeFixture.decide(.mouseDown, questionBar)
        XCTAssertFalse(click.absorbPointer)
        XCTAssertFalse(click.tracking)
    }

    func testSlipBesideTheTimeFieldDoesNotBlockTheRestOfTheBar() {
        let click = DDLTimeFixture.decide(.mouseDown, besideSlop)
        XCTAssertFalse(click.pointerOwnsPanel)
        XCTAssertFalse(click.absorbPointer)
        XCTAssertFalse(click.tracking)
    }

    func testPaddingUnderTheTimeFieldIsStillTheCard() {
        let padding = CGPoint(x: 180, y: 502)
        XCTAssertTrue(DDLTimeFixture.panel.contains(padding))
        XCTAssertFalse(DDLTimeFixture.timeField.contains(padding))
        let click = DDLTimeFixture.decide(.mouseDown, padding)
        XCTAssertTrue(click.pointerOwnsPanel)
        XCTAssertFalse(click.absorbPointer, "in-card controls under the field keep the click")
        XCTAssertFalse(click.tracking)
    }

    func testDraftFocusAndEditingHoldTheEditorOpen() {
        let away = DDLTimeFixture.decide(.hover, questionBar)
        XCTAssertTrue(staysOpen(away, cardHover: false, fieldFocused: true))
        XCTAssertTrue(staysOpen(away, cardHover: false, hasDraft: true))
        XCTAssertTrue(staysOpen(away, cardHover: false, isEditing: true))
        XCTAssertTrue(staysOpen(away, cardHover: true))
    }

    func testUnmeasuredTimeFieldDoesNotClaimTheBar() {
        let click = DeadlineTimeHit.decide(
            phase: .mouseDown,
            point: justBelow,
            panel: DDLTimeFixture.panel,
            timeField: .zero,
            tracking: false
        )
        XCTAssertFalse(click.pointerOwnsPanel)
        XCTAssertFalse(click.absorbPointer)
        XCTAssertFalse(click.tracking)
    }

    func testCalendarPopupKeepsTheEditorWithoutSwallowingItsClicks() {
        let hover = DDLTimeFixture.decide(.hover, questionBar, attachedPopup: true)
        XCTAssertTrue(hover.pointerOwnsPanel)
        XCTAssertFalse(hover.absorbPointer)
        XCTAssertTrue(staysOpen(hover, cardHover: false))

        let click = DDLTimeFixture.decide(.mouseDown, justBelow, attachedPopup: true)
        XCTAssertTrue(click.pointerOwnsPanel)
        XCTAssertFalse(click.absorbPointer, "a click inside the calendar popup is not retargeted")
        XCTAssertFalse(click.tracking)
    }

    private func staysOpen(
        _ interaction: DeadlineTimeInteraction,
        cardHover: Bool,
        fieldFocused: Bool = false,
        hasDraft: Bool = false,
        isEditing: Bool = false
    ) -> Bool {
        DeadlineTimeHit.staysOpen(
            cardHover: cardHover,
            pointerOwnsPanel: interaction.pointerOwnsPanel,
            tracking: interaction.tracking,
            fieldFocused: fieldFocused,
            hasDraft: hasDraft,
            isEditing: isEditing
        )
    }
}
