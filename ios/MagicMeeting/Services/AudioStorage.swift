import Foundation

/// Audio files live in Application Support/Recordings/<recording id>/<segment id>.m4a.
/// Default file protection (until first unlock) lets recording continue on a locked screen.
enum AudioStorage {
    static var rootURL: URL {
        URL.applicationSupportDirectory.appending(path: "Recordings", directoryHint: .isDirectory)
    }

    static func directory(for recordingID: UUID) -> URL {
        rootURL.appending(path: recordingID.uuidString, directoryHint: .isDirectory)
    }

    static func fileURL(recordingID: UUID, fileName: String) -> URL {
        directory(for: recordingID).appending(path: fileName, directoryHint: .notDirectory)
    }

    static func fileName(for segmentID: UUID) -> String {
        segmentID.uuidString + ".m4a"
    }

    /// Returns the URL for a new segment file, creating the folder if needed.
    static func prepareSegmentFile(recordingID: UUID, segmentID: UUID) throws -> URL {
        let directory = directory(for: recordingID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return fileURL(recordingID: recordingID, fileName: fileName(for: segmentID))
    }

    static func deleteFile(recordingID: UUID, fileName: String) {
        try? FileManager.default.removeItem(at: fileURL(recordingID: recordingID, fileName: fileName))
    }

    static func deleteFiles(recordingID: UUID) {
        try? FileManager.default.removeItem(at: directory(for: recordingID))
    }

    static func deleteAll() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    // MARK: Temporary files

    /// Prefixes of the short-lived m4a files in the temporary directory.
    static let voiceCommandPrefix = "voice-command-"
    static let chunkPrefix = "chunk-"

    static func temporaryFileURL(prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "\(prefix)\(UUID().uuidString).m4a", directoryHint: .notDirectory)
    }

    /// Removes command and chunk files that a crash or kill left behind. Files created at
    /// or after `date` are kept: this launch may already be using them.
    static func deleteTemporaryFiles(createdBefore date: Date) {
        let manager = FileManager.default
        let prefixes = [voiceCommandPrefix, chunkPrefix]
        guard let urls = try? manager.contentsOfDirectory(
            at: manager.temporaryDirectory,
            includingPropertiesForKeys: [.creationDateKey]
        ) else { return }
        for url in urls where url.pathExtension == "m4a" {
            let name = url.lastPathComponent
            guard prefixes.contains(where: { name.hasPrefix($0) }),
                  let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate,
                  created < date
            else { continue }
            try? manager.removeItem(at: url)
        }
    }
}
