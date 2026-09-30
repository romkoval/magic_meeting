import XCTest
@testable import MagicMeeting

final class TranscriptMergerTests: XCTestCase {
    func testDropsExactOverlap() {
        let head = "Обсудили сроки поставки. Курбатский сказал, что оборудование придёт в мае"
        let tail = "что оборудование придёт в мае. Дальше перешли к бюджету."
        XCTAssertEqual(
            TranscriptMerger.merge(head, tail),
            "Обсудили сроки поставки. Курбатский сказал, что оборудование придёт в мае. Дальше перешли к бюджету."
        )
    }

    func testToleratesClippedWordsAtChunkEdges() {
        // The head ends with a half-word, the tail starts with one.
        let head = "we agree to ship the first batch on Monday and then rev"
        let tail = "ly ship the first batch on Monday and then review the numbers"
        XCTAssertEqual(
            TranscriptMerger.merge(head, tail),
            "we agree to ship the first batch on Monday and then review the numbers"
        )
    }

    func testJoinsWhenThereIsNoOverlap() {
        XCTAssertEqual(TranscriptMerger.merge("First part.", "Second part."), "First part. Second part.")
    }

    func testEmptySides() {
        XCTAssertEqual(TranscriptMerger.merge("", " Text "), "Text")
        XCTAssertEqual(TranscriptMerger.merge("Text", ""), "Text")
    }
}

final class AudioChunkerTests: XCTestCase {
    func testShortAudioIsNotSplit() {
        XCTAssertEqual(AudioChunker.ranges(duration: 300), [0...300])
        XCTAssertEqual(AudioChunker.ranges(duration: 650), [0...650])
    }

    func testLongAudioIsSplitWithOverlap() {
        XCTAssertEqual(AudioChunker.ranges(duration: 1500), [0...600, 595...1200, 1195...1500])
    }

    func testShortTailIsFoldedIntoLastChunk() {
        XCTAssertEqual(AudioChunker.ranges(duration: 1230), [0...600, 595...1230])
    }
}

final class FormattersTests: XCTestCase {
    func testDuration() {
        XCTAssertEqual(Formatters.duration(0), "00:00")
        XCTAssertEqual(Formatters.duration(307.9), "05:07")
        XCTAssertEqual(Formatters.duration(3723), "1:02:03")
    }
}
