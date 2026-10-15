import XCTest
@testable import MagicMeeting

final class UndoResolverTests: XCTestCase {
    func testTextEqualToAfterRestoresBefore() {
        XCTAssertEqual(
            UndoResolver.resolve(current: "C", before: "B", after: "C", allowsAppend: false),
            .restore("B")
        )
        XCTAssertEqual(
            UndoResolver.resolve(current: "C", before: "B", after: "C", allowsAppend: true),
            .restore("B")
        )
    }

    func testAppendedSegmentIsKeptWhenAllowed() {
        XCTAssertEqual(
            UndoResolver.resolve(current: "C\n\nX", before: "B", after: "C", allowsAppend: true),
            .restore("B\n\nX")
        )
    }

    func testAppendedTextIsAConflictWhenNotAllowed() {
        XCTAssertEqual(
            UndoResolver.resolve(current: "C\n\nX", before: "B", after: "C", allowsAppend: false),
            .conflict
        )
    }

    func testUnrelatedTextIsAConflict() {
        XCTAssertEqual(
            UndoResolver.resolve(current: "something else", before: "B", after: "C", allowsAppend: true),
            .conflict
        )
    }

    func testTextThatDoesNotExtendAfterIsAConflict() {
        // Shorter than `after`, and a prefix mismatch: both are manual edits.
        XCTAssertEqual(
            UndoResolver.resolve(current: "Cx", before: "B", after: "CC", allowsAppend: true),
            .conflict
        )
        XCTAssertEqual(
            UndoResolver.resolve(current: "xC\n\nX", before: "B", after: "C", allowsAppend: true),
            .conflict
        )
    }

    func testEmptyAfterWithNonEmptyCurrentIsAConflict() {
        XCTAssertEqual(
            UndoResolver.resolve(current: "text", before: "B", after: "", allowsAppend: true),
            .conflict
        )
    }

    func testEmptyBeforeDropsTheSeparatorOfTheAppendedSuffix() {
        XCTAssertEqual(
            UndoResolver.resolve(current: "C\n\nX", before: "", after: "C", allowsAppend: true),
            .restore("X")
        )
    }

    func testTwoStepChainUndoesBackThroughAppendedSegment() {
        // A -> B, B -> C, then a segment "X" was appended to C.
        let current = "C\n\nX"
        guard case .restore(let afterFirstUndo) = UndoResolver.resolve(
            current: current, before: "B", after: "C", allowsAppend: true
        ) else { return XCTFail("expected restore") }
        XCTAssertEqual(afterFirstUndo, "B\n\nX")

        XCTAssertEqual(
            UndoResolver.resolve(current: afterFirstUndo, before: "A", after: "B", allowsAppend: true),
            .restore("A\n\nX")
        )
    }
}
