import Foundation
import SwiftData

/// One continuous piece of audio: the first recording or a later append.
@Model
final class AudioSegment {
    @Attribute(.unique) var id: UUID
    var order: Int
    /// File name inside the recording's folder, see `AudioStorage`.
    var fileName: String
    var duration: TimeInterval
    /// nil until the segment is transcribed.
    var transcript: String?
    /// JSON-encoded `[TranscriptTiming]`; read through `timings`.
    var timingsData: Data?
    var recording: Recording?

    init(id: UUID, order: Int, fileName: String, duration: TimeInterval) {
        self.id = id
        self.order = order
        self.fileName = fileName
        self.duration = duration
    }

    var timings: [TranscriptTiming] {
        get { timingsData.flatMap { try? JSONDecoder().decode([TranscriptTiming].self, from: $0) } ?? [] }
        set { timingsData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }
}
