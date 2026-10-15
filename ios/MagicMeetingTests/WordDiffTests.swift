import XCTest
@testable import MagicMeeting

final class WordDiffTests: XCTestCase {
    // Words in these fixtures are unique on purpose: with repeated words the same
    // diff can be drawn in more than one equally short way.
    private func changed(from old: String, to new: String) -> [String]? {
        WordDiff.changedRanges(from: old, to: new)?.map { String(new[$0]) }
    }

    func testIdenticalTextHasNoChanges() {
        XCTAssertEqual(changed(from: "один два три", to: "один два три"), [])
    }

    func testChangedWordIsMarked() {
        XCTAssertEqual(changed(from: "alpha beta gamma", to: "alpha delta gamma"), ["delta"])
    }

    func testInsertedWordsFormOneRangeIncludingInnerSpaces() {
        XCTAssertEqual(changed(from: "start end", to: "start one two three end"), ["one two three"])
    }

    func testSeparateChangesGiveSeparateRanges() {
        XCTAssertEqual(changed(from: "a b c d e", to: "a X c Y Z e"), ["X", "Y Z"])
    }

    func testAppendedAndFullyNewText() {
        XCTAssertEqual(changed(from: "alpha", to: "alpha beta"), ["beta"])
        XCTAssertEqual(changed(from: "", to: "alpha beta"), ["alpha beta"])
    }

    func testDeletionOnlyHasNoChanges() {
        XCTAssertEqual(changed(from: "alpha beta gamma", to: "alpha gamma"), [])
        XCTAssertEqual(changed(from: "alpha", to: ""), [])
    }

    func testWhitespaceOnlyChangeHasNoChanges() {
        XCTAssertEqual(changed(from: "alpha beta\ngamma", to: "alpha   beta gamma"), [])
    }

    func testCyrillicText() {
        XCTAssertEqual(
            changed(from: "Встреча назначена на понедельник", to: "Встреча перенесена на вторник"),
            ["перенесена", "вторник"]
        )
    }

    func testRangesIndexIntoTheNewText() {
        let new = "😀 один два три"
        let ranges = WordDiff.changedRanges(from: "😀 один три", to: new) ?? []
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(new[ranges[0]], "два")
        XCTAssertEqual(new[..<ranges[0].lowerBound], "😀 один ")
    }

    func testAtMaxTokensStillDiffs() {
        var words = (0..<WordDiff.maxTokens).map { "w\($0)" }
        let old = words.joined(separator: " ")
        words[5] = "zz"
        XCTAssertEqual(changed(from: old, to: words.joined(separator: " ")), ["zz"])
    }

    func testAboveMaxTokensIsNotDiffed() {
        XCTAssertEqual(WordDiff.maxTokens, 1_500)
        let old = (0..<WordDiff.maxTokens).map { "w\($0)" }.joined(separator: " ")
        // One token over the limit on the new side, then on the old side.
        XCTAssertNil(changed(from: old, to: old + " extra"))
        XCTAssertNil(changed(from: old + " extra", to: old + " other"))
    }
}
