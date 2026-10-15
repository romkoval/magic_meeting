import XCTest
@testable import MagicMeeting

final class ReplacementApplierTests: XCTestCase {
    private struct Applied: Equatable {
        let text: String
        let marked: [String]
        let count: Int
    }

    private func replace(_ find: String, _ replacement: String, all: Bool = false) -> TextReplacement {
        TextReplacement(find: find, replace: replacement, all: all)
    }

    /// Ranges are asserted through the substrings they cover, never as raw offsets.
    private func apply(_ replacements: [TextReplacement], to text: String) -> Applied {
        let outcome = ReplacementApplier.apply(replacements, to: text)
        return Applied(
            text: outcome.text,
            marked: outcome.changedRanges.map { String(outcome.text[$0]) },
            count: outcome.appliedCount
        )
    }

    func testReplacesOnlyFirstOccurrenceByDefault() {
        XCTAssertEqual(
            apply([replace("кот", "пёс")], to: "кот и кот и кот"),
            Applied(text: "пёс и кот и кот", marked: ["пёс"], count: 1)
        )
    }

    func testAllReplacesEveryOccurrence() {
        XCTAssertEqual(
            apply([replace("кот", "пёс", all: true)], to: "кот и кот и кот"),
            Applied(text: "пёс и пёс и пёс", marked: ["пёс", "пёс", "пёс"], count: 3)
        )
    }

    func testRangesSurviveEmojiAndCyrillicBeforeTheMatch() {
        XCTAssertEqual(
            apply([replace("Курбацкий", "Курбатский", all: true)], to: "😀 Курбацкий сказал. Курбацкий ушёл 🎉"),
            Applied(
                text: "😀 Курбатский сказал. Курбатский ушёл 🎉",
                marked: ["Курбатский", "Курбатский"],
                count: 2
            )
        )
    }

    func testRangesIndexIntoTheReturnedText() {
        let outcome = ReplacementApplier.apply([replace("мир", "Земля")], to: "👋 привет, мир!")
        XCTAssertEqual(outcome.text, "👋 привет, Земля!")
        XCTAssertEqual(outcome.changedRanges.count, 1)
        XCTAssertEqual(outcome.text[outcome.changedRanges[0]], "Земля")
        XCTAssertEqual(outcome.text[..<outcome.changedRanges[0].lowerBound], "👋 привет, ")
    }

    func testSecondReplacementShiftsTheFirstRange() {
        // The second replacement grows the text before the first one's mark.
        XCTAssertEqual(
            apply([replace("cat", "a big dog"), replace("Hello", "Oh hello there")], to: "Hello cat"),
            Applied(text: "Oh hello there a big dog", marked: ["Oh hello there", "a big dog"], count: 2)
        )
    }

    func testSecondReplacementInsideFirstInsertionMergesIntoOneRange() {
        XCTAssertEqual(
            apply([replace("a", "one two three"), replace("two", "2")], to: "x a y"),
            Applied(text: "x one 2 three y", marked: ["one 2 three"], count: 2)
        )
    }

    func testReplacementCuttingIntoAnEarlierMarkClipsIt() {
        XCTAssertEqual(
            apply([replace("cd", "XYZ"), replace("b XY", "!")], to: "ab cd"),
            Applied(text: "a!Z", marked: ["!Z"], count: 2)
        )
        XCTAssertEqual(
            apply([replace("one two", "ONE TWO"), replace("NE TW", "")], to: "x one two y"),
            Applied(text: "x OO y", marked: ["OO"], count: 2)
        )
    }

    func testDeletionCountsButLeavesNoRange() {
        XCTAssertEqual(
            apply([replace(" extra", "")], to: "text extra end"),
            Applied(text: "text end", marked: [], count: 1)
        )
    }

    func testDeletionBeforeAnEarlierMarkShiftsIt() {
        XCTAssertEqual(
            apply([replace("end", "END"), replace("zzz ", "")], to: "zzz old end"),
            Applied(text: "old END", marked: ["END"], count: 2)
        )
        XCTAssertEqual(
            apply([replace("a", "A", all: true), replace("zz ", "")], to: "zz a b a"),
            Applied(text: "A b A", marked: ["A", "A"], count: 3)
        )
    }

    func testDeletionAfterAnEarlierMarkKeepsIt() {
        XCTAssertEqual(
            apply([replace("old", "OLD"), replace(" zzz", "")], to: "old zzz end"),
            Applied(text: "OLD end", marked: ["OLD"], count: 2)
        )
    }

    func testMissingFindChangesNothing() {
        XCTAssertEqual(
            apply([replace("nope", "x", all: true)], to: "some text"),
            Applied(text: "some text", marked: [], count: 0)
        )
    }

    func testFindConsumedByAnEarlierReplacementIsSkipped() {
        XCTAssertEqual(
            apply([replace("foo", "bar"), replace("foo", "baz")], to: "foo"),
            Applied(text: "bar", marked: ["bar"], count: 1)
        )
    }

    func testEmptyFindAndNoOpReplacementsAreIgnored() {
        XCTAssertEqual(
            apply([replace("", "x", all: true), replace("same", "same")], to: "same text"),
            Applied(text: "same text", marked: [], count: 0)
        )
    }

    func testReplacementContainingItsFindTerminates() {
        XCTAssertEqual(
            apply([replace("a", "aa", all: true)], to: "banana"),
            Applied(text: "baanaanaa", marked: ["aa", "aa", "aa"], count: 3)
        )
    }

    func testAdjacentRangesMerge() {
        XCTAssertEqual(
            apply([replace("a", "X"), replace("b", "Y")], to: "abc"),
            Applied(text: "XYc", marked: ["XY"], count: 2)
        )
        XCTAssertEqual(
            apply([replace("ab", "XY", all: true)], to: "abab"),
            Applied(text: "XYXY", marked: ["XYXY"], count: 2)
        )
    }

    func testEmptyReplacementListAndEmptyText() {
        XCTAssertEqual(apply([], to: "text"), Applied(text: "text", marked: [], count: 0))
        XCTAssertEqual(apply([replace("a", "b")], to: ""), Applied(text: "", marked: [], count: 0))
    }
}
