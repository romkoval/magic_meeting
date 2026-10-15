import XCTest
@testable import MagicMeeting

final class AudioStorageTests: XCTestCase {
    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    func testDeletesOnlyLeftoverCommandAndChunkFiles() {
        let manager = FileManager.default
        let command = AudioStorage.temporaryFileURL(prefix: AudioStorage.voiceCommandPrefix)
        let chunk = AudioStorage.temporaryFileURL(prefix: AudioStorage.chunkPrefix)
        let other = manager.temporaryDirectory
            .appending(path: "other-\(UUID().uuidString).m4a", directoryHint: .notDirectory)
        for url in [command, chunk, other] {
            XCTAssertTrue(manager.createFile(atPath: url.path(percentEncoded: false), contents: Data()))
        }
        defer {
            for url in [command, chunk, other] { try? manager.removeItem(at: url) }
        }

        // Files created after the cutoff belong to the current launch.
        AudioStorage.deleteTemporaryFiles(createdBefore: .distantPast)
        XCTAssertTrue(exists(command))
        XCTAssertTrue(exists(chunk))

        AudioStorage.deleteTemporaryFiles(createdBefore: .distantFuture)
        XCTAssertFalse(exists(command))
        XCTAssertFalse(exists(chunk))
        XCTAssertTrue(exists(other))
    }
}
