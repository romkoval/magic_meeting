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
}
