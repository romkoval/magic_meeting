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

    // MARK: Limits on model output

    func testSelfFeedingChainStopsAtTheGrowthLimit() {
        // Unbounded, 2000 doublings of the a's would never finish.
        let outcome = ReplacementApplier.apply(Array(repeating: replace("a", "aa", all: true), count: 2_000), to: "banana")
        let limit = 6 + ReplacementApplier.minGrowthAllowance
        XCTAssertLessThanOrEqual(outcome.text.utf8.count, limit)
        // 14 doublings fit (3 * 2^14 a's); the 15th would pass the limit and every later one is skipped.
        XCTAssertEqual(outcome.text.utf8.count, 3 + 3 * 16_384)
        XCTAssertEqual(outcome.appliedCount, 3 * (16_384 - 1))
        XCTAssertTrue(outcome.text.hasPrefix("baaaa"))
        XCTAssertTrue(outcome.text.hasSuffix("naaaa"))
    }

    func testOversizedFragmentsAreSkipped() {
        let huge = String(repeating: "x", count: 100_000)
        XCTAssertEqual(
            apply([replace("a", huge, all: true), replace(huge, "y"), replace("b", "B")], to: "banana"),
            Applied(text: "Banana", marked: ["B"], count: 1)
        )
        let largest = String(repeating: "x", count: ReplacementApplier.maxFragmentBytes)
        XCTAssertEqual(apply([replace("b", largest)], to: "banana").count, 1)
    }

    func testReplacementPastTheGrowthLimitIsSkippedButLaterOnesApply() {
        let fragment = String(repeating: "x", count: ReplacementApplier.maxFragmentBytes)
        // 32 a's grow to 64 000 bytes, within 32 + 64 KB; 33 a's and " end" would make
        // 66 004, past 37 + 64 KB.
        let fits = ReplacementApplier.apply([replace("a", fragment, all: true)], to: String(repeating: "a", count: 32))
        XCTAssertEqual(fits.text.utf8.count, 64_000)
        XCTAssertEqual(fits.appliedCount, 32)

        let text = String(repeating: "a", count: 33) + " end"
        XCTAssertEqual(
            apply([replace("a", fragment, all: true), replace("end", "END")], to: text),
            Applied(text: String(repeating: "a", count: 33) + " END", marked: ["END"], count: 1)
        )
    }

    func testLongTextMayDoubleButNoMore() {
        let text = String(repeating: "ab", count: 50_000)
        // The first exactly doubles the text; the second would go past that.
        let outcome = ReplacementApplier.apply([replace("a", "aaa", all: true), replace("b", "bb", all: true)], to: text)
        XCTAssertEqual(outcome.text.utf8.count, 200_000)
        XCTAssertEqual(outcome.appliedCount, 50_000)
        XCTAssertFalse(outcome.text.contains("bb"))
    }

    func testOnlyTheFirstReplacementsAreProcessed() {
        let words = (0..<10_000).map { "w" + String(format: "%04d", $0) }
        let replacements = words.map { replace($0, $0.uppercased()) }
        let outcome = ReplacementApplier.apply(replacements, to: words.joined(separator: " "))
        let result = outcome.text.split(separator: " ").map(String.init)
        XCTAssertEqual(outcome.appliedCount, ReplacementApplier.maxReplacements)
        XCTAssertEqual(outcome.text.utf8.count, words.joined(separator: " ").utf8.count)
        XCTAssertEqual(result[ReplacementApplier.maxReplacements - 1], "W0049")
        XCTAssertEqual(result[ReplacementApplier.maxReplacements], "w0050")
        XCTAssertEqual(result.last, "w9999")
    }
}
