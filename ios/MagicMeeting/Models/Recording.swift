import Foundation
import SwiftData

enum RecordingStatus: String, Codable, Sendable {
    case recording
    /// Recorded, waiting to be sent: no consent yet, offline, or queued.
    case pending
    case transcribing
    case ready
    case failed
}

@Model
final class Recording {
    @Attribute(.unique) var id: UUID
    var startedAt: Date
    var duration: TimeInterval
    /// One-line description for the history list, produced by `summarize`.
    var title: String
    /// Full transcript: segment transcripts joined in order, or the edited version.
    var transcript: String
    /// Set after a manual or voice edit. Segment transcripts are never touched,
    /// so later appends are glued to the end of the edited text.
    var isTranscriptEdited: Bool
    var summary: String
    /// `protocol` in the spec; renamed because it is a Swift keyword.
    var protocolText: String
    var templateId: UUID?
    var statusRaw: String
    /// ISO-639-1 code detected by Whisper for the latest segment.
    var language: String?
    var lastError: String?

    @Relationship(deleteRule: .cascade, inverse: \AudioSegment.recording)
    var segments: [AudioSegment] = []
    @Relationship(deleteRule: .cascade, inverse: \Highlight.recording)
    var highlights: [Highlight] = []
    @Relationship(deleteRule: .cascade, inverse: \EditStep.recording)
    var editSteps: [EditStep] = []

    init(id: UUID = UUID(), startedAt: Date = .now) {
        self.id = id
        self.startedAt = startedAt
        self.duration = 0
        self.title = ""
        self.transcript = ""
        self.isTranscriptEdited = false
        self.summary = ""
        self.protocolText = ""
        self.statusRaw = RecordingStatus.recording.rawValue
    }

    var status: RecordingStatus {
        get { RecordingStatus(rawValue: statusRaw) ?? .failed }
        set { statusRaw = newValue.rawValue }
    }

    var orderedSegments: [AudioSegment] {
        segments.sorted { $0.order < $1.order }
    }

    var nextSegmentOrder: Int {
        (segments.map(\.order).max() ?? -1) + 1
    }

    /// Adds a freshly transcribed segment to the full transcript.
    func applySegmentTranscript(_ text: String) {
        if isTranscriptEdited {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            transcript = transcript.isEmpty ? trimmed : transcript + "\n\n" + trimmed
        } else {
            transcript = orderedSegments
                .compactMap { $0.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
        }
    }
}
