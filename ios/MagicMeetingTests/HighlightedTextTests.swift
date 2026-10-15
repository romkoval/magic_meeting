import SwiftUI
import XCTest
@testable import MagicMeeting

final class HighlightedTextTests: XCTestCase {
    private typealias Background = AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute

    /// Substrings of `attributed` that carry a background color.
    private func highlighted(_ attributed: AttributedString) -> [String] {
        attributed.runs.compactMap { run in
            run.attributes[Background.self] == nil ? nil : String(attributed[run.range].characters)
        }
    }

    func testMarksExactlyTheGivenRange() {
        let text = "Обсудили 🚀 сроки с Курбатским и бюджет"
        let range = text.range(of: "Курбатским")!
        let attributed = HighlightedText.attributed(text, ranges: [range])
        XCTAssertEqual(highlighted(attributed), ["Курбатским"])
        XCTAssertEqual(String(attributed.characters), text)
    }

    func testSkipsRangeFromAnotherString() {
        let other = "a much longer string that is not the displayed one"
        let foreign = other.range(of: "displayed")!
        let attributed = HighlightedText.attributed("short", ranges: [foreign])
        XCTAssertEqual(highlighted(attributed), [])
        XCTAssertEqual(String(attributed.characters), "short")
    }
}

final class ChangeHighlightTests: XCTestCase {
    private func ranges(_ count: Int, in text: String) -> [Range<String.Index>] {
        Array(repeating: text.startIndex..<text.index(after: text.startIndex), count: count)
    }

    func testHighlightIsDroppedAboveMaxRanges() {
        let text = "text"
        XCTAssertNotNil(ChangeHighlight(target: .summary, text: text, ranges: ranges(ChangeHighlight.maxRanges, in: text)))
        XCTAssertNil(ChangeHighlight(target: .summary, text: text, ranges: ranges(ChangeHighlight.maxRanges + 1, in: text)))
    }

    func testNoticeSaysWhenAFullTextEditIsNotHighlighted() {
        let highlight = ChangeHighlight(target: .summary, text: "text", ranges: [])
        XCTAssertEqual(VoiceEditResult(highlight: highlight, changeCount: nil).notice, .applied(count: nil))
        XCTAssertEqual(VoiceEditResult(highlight: nil, changeCount: nil).notice, .appliedUnhighlighted)
        // A transcript edit still reports its count when its marks are dropped.
        XCTAssertEqual(VoiceEditResult(highlight: nil, changeCount: 600).notice, .applied(count: 600))
    }
}
