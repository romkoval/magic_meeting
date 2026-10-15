import SwiftData
import XCTest
@testable import MagicMeeting

@MainActor
final class EditHistoryTests: XCTestCase {
    /// Kept for the whole test: a context must not outlive its container.
    private var container: ModelContainer?

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Recording.self, AudioSegment.self, Highlight.self, EditStep.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        self.container = container
        return container.mainContext
    }

    private func makeRecording(in context: ModelContext) -> Recording {
        let recording = Recording()
        context.insert(recording)
        return recording
    }

    /// Explicit timestamps keep the order deterministic; `Date.now` twice in a row may tie.
    @discardableResult
    private func addStep(
        _ recording: Recording, _ target: EditTarget, _ before: String, _ after: String,
        at second: TimeInterval, in context: ModelContext
    ) -> EditStep {
        let step = EditStep(
            target: target, before: before, after: after, command: nil,
            createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000 + second)
        )
        context.insert(step)
        recording.editSteps.append(step)
        return step
    }

    func testSummaryStepsUndoInReverseOrder() throws {
        let context = try makeContext()
        let recording = makeRecording(in: context)
        addStep(recording, .summary, "A", "B", at: 1, in: context)
        addStep(recording, .summary, "B", "C", at: 2, in: context)
        recording.summary = "C"
        try context.save()

        XCTAssertEqual(EditHistory.undo(recording, target: .summary, in: context), .undone)
        XCTAssertEqual(recording.summary, "B")
        XCTAssertEqual(recording.editSteps.count, 1)

        XCTAssertEqual(EditHistory.undo(recording, target: .summary, in: context), .undone)
        XCTAssertEqual(recording.summary, "A")
        XCTAssertTrue(recording.editSteps.isEmpty)

        try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<EditStep>()), 0)
        XCTAssertEqual(EditHistory.undo(recording, target: .summary, in: context), .nothingToUndo)
    }

    func testTranscriptUndoKeepsSummaryStepAndEditedFlag() throws {
        let context = try makeContext()
        let recording = makeRecording(in: context)
        let summaryStep = addStep(recording, .summary, "S1", "S2", at: 1, in: context)
        addStep(recording, .transcript, "old text", "new text", at: 2, in: context)
        recording.summary = "S2"
        recording.setText("new text", for: .transcript)

        XCTAssertEqual(EditHistory.undo(recording, target: .transcript, in: context), .undone)
        XCTAssertEqual(recording.transcript, "old text")
        XCTAssertTrue(recording.isTranscriptEdited)
        XCTAssertEqual(recording.summary, "S2")
        XCTAssertEqual(recording.editSteps.map(\.id), [summaryStep.id])
        XCTAssertEqual(EditHistory.latestStep(of: recording, target: .summary)?.id, summaryStep.id)
    }

    func testTranscriptUndoKeepsAppendedSegment() throws {
        let context = try makeContext()
        let recording = makeRecording(in: context)
        addStep(recording, .transcript, "Курбацкий", "Курбатский", at: 1, in: context)
        recording.setText("Курбатский", for: .transcript)
        recording.applySegmentTranscript("Next part")

        XCTAssertEqual(EditHistory.undo(recording, target: .transcript, in: context), .undone)
        XCTAssertEqual(recording.transcript, "Курбацкий\n\nNext part")
    }

    func testConflictKeepsStepAndText() throws {
        let context = try makeContext()
        let recording = makeRecording(in: context)
        let step = addStep(recording, .summary, "A", "B", at: 1, in: context)
        recording.summary = "Regenerated"

        XCTAssertEqual(EditHistory.undo(recording, target: .summary, in: context), .conflict)
        XCTAssertEqual(recording.summary, "Regenerated")
        XCTAssertEqual(recording.editSteps.map(\.id), [step.id])
        XCTAssertFalse(step.isDeleted)
    }

    func testNothingToUndoWithoutSteps() throws {
        let context = try makeContext()
        let recording = makeRecording(in: context)
        recording.protocolText = "Minutes"

        XCTAssertEqual(EditHistory.undo(recording, target: .protocolText, in: context), .nothingToUndo)
        XCTAssertEqual(recording.protocolText, "Minutes")
    }

    func testLatestStepPicksNewestForTarget() throws {
        let context = try makeContext()
        let recording = makeRecording(in: context)
        // Inserted out of order on purpose: the relationship array order means nothing.
        let newest = addStep(recording, .summary, "B", "C", at: 5, in: context)
        addStep(recording, .summary, "A", "B", at: 1, in: context)
        addStep(recording, .transcript, "x", "y", at: 9, in: context)

        XCTAssertEqual(EditHistory.latestStep(of: recording, target: .summary)?.id, newest.id)
        XCTAssertEqual(EditHistory.latestStep(of: recording, target: .transcript)?.after, "y")
        XCTAssertNil(EditHistory.latestStep(of: recording, target: .protocolText))
    }

    func testRecordedVoiceStepCanBeUndone() throws {
        let context = try makeContext()
        let recording = makeRecording(in: context)
        recording.protocolText = "Draft"
        EditHistory.record(recording, target: .protocolText, before: "Draft", after: "Final", command: "make it final", in: context)
        recording.setText("Final", for: .protocolText)

        XCTAssertEqual(EditHistory.latestStep(of: recording, target: .protocolText)?.command, "make it final")
        XCTAssertEqual(EditHistory.undo(recording, target: .protocolText, in: context), .undone)
        XCTAssertEqual(recording.protocolText, "Draft")
        XCTAssertFalse(recording.isTranscriptEdited)
    }

    func testSetTextMarksOnlyTranscriptEdited() throws {
        let context = try makeContext()
        let recording = makeRecording(in: context)

        recording.setText("Summary", for: .summary)
        recording.setText("Minutes", for: .protocolText)
        XCTAssertFalse(recording.isTranscriptEdited)
        XCTAssertEqual(recording.text(for: .summary), "Summary")
        XCTAssertEqual(recording.text(for: .protocolText), "Minutes")

        recording.setText("Transcript", for: .transcript)
        XCTAssertTrue(recording.isTranscriptEdited)
        XCTAssertEqual(recording.text(for: .transcript), "Transcript")
    }
}

final class ReplacementsResultDecodingTests: XCTestCase {
    func testDecodesReplacements() throws {
        let json = Data(#"{"replacements":[{"find":"a","replace":"b","all":true}]}"#.utf8)
        let result = try JSONDecoder().decode(ReplacementsResult.self, from: json)
        XCTAssertEqual(result.replacements, [TextReplacement(find: "a", replace: "b", all: true)])
    }

    func testDecodesEmptyList() throws {
        let json = Data(#"{"replacements":[]}"#.utf8)
        let result = try JSONDecoder().decode(ReplacementsResult.self, from: json)
        XCTAssertTrue(result.replacements.isEmpty)
    }
}
