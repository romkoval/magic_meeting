import AVFoundation

enum AudioChunkerError: LocalizedError {
    case exportFailed

    var errorDescription: String? {
        String(localized: "Could not prepare the audio for sending.")
    }
}

/// Cuts long audio into ~10-minute pieces with a few seconds of overlap so each
/// request stays under the upload limits (TZ §3.2, §10).
enum AudioChunker {
    static let chunkLength: TimeInterval = 600
    static let overlap: TimeInterval = 5
    /// A little slack so a 10:20 segment is not split into 10:00 + 0:20.
    static let tolerance: TimeInterval = 60

    static func ranges(duration: TimeInterval) -> [ClosedRange<TimeInterval>] {
        guard duration > chunkLength + tolerance else { return [0...max(duration, 0)] }
        var result: [ClosedRange<TimeInterval>] = []
        var start: TimeInterval = 0
        while start < duration {
            var end = min(start + chunkLength, duration)
            // Fold a short tail into the last chunk instead of sending a sliver.
            if duration - end < tolerance {
                end = duration
            }
            result.append(max(0, start - (start > 0 ? overlap : 0))...end)
            start = end
        }
        return result
    }

    /// Exports each range to a temporary m4a file. The caller removes them with `remove(_:)`.
    static func export(_ url: URL, ranges: [ClosedRange<TimeInterval>]) async throws -> [URL] {
        let asset = AVURLAsset(url: url)
        var outputs: [URL] = []
        do {
            for range in ranges {
                let output = FileManager.default.temporaryDirectory
                    .appending(path: "chunk-\(UUID().uuidString).m4a", directoryHint: .notDirectory)
                let timeRange = CMTimeRange(
                    start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
                    end: CMTime(seconds: range.upperBound, preferredTimescale: 600)
                )
                // Passthrough keeps the original ~32 kbit/s; re-encode only as a fallback.
                let copied = try await exportRange(of: asset, timeRange: timeRange, to: output, preset: AVAssetExportPresetPassthrough)
                if !copied {
                    try? FileManager.default.removeItem(at: output)
                    let reencoded = try await exportRange(of: asset, timeRange: timeRange, to: output, preset: AVAssetExportPresetAppleM4A)
                    guard reencoded else { throw AudioChunkerError.exportFailed }
                }
                outputs.append(output)
            }
        } catch {
            remove(outputs)
            throw error
        }
        return outputs
    }

    static func remove(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func exportRange(of asset: AVURLAsset, timeRange: CMTimeRange, to output: URL, preset: String) async throws -> Bool {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { return false }
        session.outputURL = output
        session.outputFileType = .m4a
        session.timeRange = timeRange
        await session.export()
        try Task.checkCancellation()
        return session.status == .completed
    }
}
