import Foundation

/// One Whisper segment with its timestamps, in seconds from the start of the
/// `AudioSegment` file. Speaker diarization will be aligned to these (TZ §12).
struct TranscriptTiming: Codable, Equatable, Sendable {
    var start: TimeInterval
    var end: TimeInterval
    var text: String
}

enum TimingMerger {
    /// Appends the timings of the next audio chunk. `offset` is where the chunk
    /// starts in the segment file. Chunks overlap by a few seconds, so timings
    /// that start before the end of what we already have are duplicates.
    static func append(_ timings: [TranscriptTiming], to existing: [TranscriptTiming], offset: TimeInterval) -> [TranscriptTiming] {
        let shifted = timings.map {
            TranscriptTiming(start: $0.start + offset, end: $0.end + offset, text: $0.text)
        }
        guard let lastEnd = existing.last?.end else { return shifted }
        let tolerance: TimeInterval = 0.5
        return existing + shifted.filter { $0.start >= lastEnd - tolerance }
    }
}
