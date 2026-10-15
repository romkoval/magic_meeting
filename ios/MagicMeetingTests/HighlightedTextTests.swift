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
