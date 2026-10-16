import XCTest
@testable import MagicMeeting

final class GlossaryInputTests: XCTestCase {
    // MARK: parse

    func testSplitsOnNewlinesCommasAndSemicolons() {
        XCTAssertEqual(
            GlossaryInput.parse("Иванов, Петров;Сидоров\nKubernetes\r\nGroq", existing: []),
            ["Иванов", "Петров", "Сидоров", "Kubernetes", "Groq"]
        )
    }

    func testTrimsWhitespace() {
        XCTAssertEqual(
            GlossaryInput.parse("  Иванов  ,\t Петров \n  Анна Смирнова ", existing: []),
            ["Иванов", "Петров", "Анна Смирнова"]
        )
    }

    func testEmptyInputGivesNothing() {
        XCTAssertEqual(GlossaryInput.parse("", existing: []), [])
        XCTAssertEqual(GlossaryInput.parse("  , ;\n\n ;", existing: []), [])
    }

    func testDedupesWithinInputIgnoringCase() {
        XCTAssertEqual(
            GlossaryInput.parse("Курбатский, курбатский; КУРБАТСКИЙ\nGroq, groq", existing: []),
            ["Курбатский", "Groq"]
        )
    }

    func testDropsTermsAlreadyInGlossaryIgnoringCase() {
        XCTAssertEqual(
            GlossaryInput.parse("курбатский, Petrov", existing: ["Курбатский"]),
            ["Petrov"]
        )
        XCTAssertEqual(GlossaryInput.parse("КУРБАТСКИЙ", existing: ["Курбатский"]), [])
    }

    func testDropsOverlongTerms() {
        let longest = String(repeating: "я", count: GlossaryInput.maxTermLength)
        let tooLong = String(repeating: "я", count: GlossaryInput.maxTermLength + 1)
        XCTAssertEqual(
            GlossaryInput.parse("\(tooLong), Иванов, \(longest)", existing: []),
            ["Иванов", longest]
        )
    }

    // MARK: whisperUsage

    func testUsageOfNoTerms() {
        let usage = GlossaryInput.whisperUsage([])
        XCTAssertEqual(usage.used, 0)
        XCTAssertEqual(usage.included, 0)
    }

    func testUsageCountsTermPlusSeparator() {
        let usage = GlossaryInput.whisperUsage(["Groq", "Иванов"])
        XCTAssertEqual(usage.used, (4 + 2) + (6 + 2))
        XCTAssertEqual(usage.included, 2)
    }

    func testCyrillicCountsAsOneScalarPerLetter() {
        let usage = GlossaryInput.whisperUsage(["Курбатский"])
        XCTAssertEqual(usage.used, 12)
        XCTAssertEqual(usage.included, 1)
    }

    func testDecomposedLettersCountByScalars() {
        // "й" as "и" plus a combining breve: one Character, two runes on the proxy.
        let term = "И\u{0306}о"
        XCTAssertEqual(term.count, 2)
        XCTAssertEqual(GlossaryInput.whisperUsage([term]).used, 3 + 2)
    }

    func testTermsFillingTheBudgetExactlyAllFit() {
        // Each costs 100: seven make exactly 700.
        let terms = (0..<7).map { String(repeating: "a", count: 97) + String($0) }
        let usage = GlossaryInput.whisperUsage(terms)
        XCTAssertEqual(usage.used, 700)
        XCTAssertEqual(usage.included, 7)
    }

    func testFirstTermThatDoesNotFitEndsThePrompt() {
        let sixHundred = (0..<6).map { String(repeating: "a", count: 97) + String($0) }
        // Would bring the total to 701; the short term after it would fit but is dropped too.
        let crossing = String(repeating: "b", count: 99)
        let usage = GlossaryInput.whisperUsage(sixHundred + [crossing, "ab"])
        XCTAssertEqual(usage.used, 600)
        XCTAssertEqual(usage.included, 6)
    }
}
