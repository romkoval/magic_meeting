import Foundation
import Observation

enum VoiceEditError: LocalizedError, Equatable {
    case needsConsent
    case emptyCommand
    case nothingToChange
    case textChanged
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .needsConsent:
            String(localized: "Allow sending data to the AI service to edit by voice.")
        case .emptyCommand:
            String(localized: "Didn't catch that. Try again.")
        case .nothingToChange:
            String(localized: "Nothing to change for this command.")
        case .textChanged:
            String(localized: "The text changed while the command was being applied. Try again.")
        case .saveFailed:
            String(localized: "Couldn't save the change. Try again.")
        }
    }
}

struct VoiceEditResult {
    /// Nil when the changes are not marked: too many of them, or a text too long to diff.
    let highlight: ChangeHighlight?
    /// Replacements applied (transcript); nil for full-text edits.
    let changeCount: Int?

    var notice: VoiceEditNotice {
        if let changeCount { return .applied(count: changeCount) }
        // With neither a count nor a highlight, nothing would show what the edit did.
        return highlight == nil ? .appliedUnhighlighted : .applied(count: nil)
    }
}

enum VoiceEditNotice: Equatable {
    /// "Changes: %lld" / "Applied".
    case applied(count: Int?)
    /// A full-text edit whose changes could not be highlighted.
    case appliedUnhighlighted
    case undone
    /// A call or Siri took the microphone while listening.
    case interrupted
    /// The status line offers "Open Settings".
    case microphoneDenied
    /// Already localized: VoiceEditError, ProxyError, AudioRecorderError, undo conflict.
    case message(String)

    var text: String {
        switch self {
        case .applied(let count):
            if let count {
                return String(localized: "Changes: \(count)")
            }
            return String(localized: "Applied")
        case .appliedUnhighlighted:
            return String(localized: "Applied. Changes aren't highlighted in long texts, so check it before sharing.")
        case .undone:
            return String(localized: "Undone")
        case .interrupted:
            return String(localized: "Recording was interrupted.")
        case .microphoneDenied:
            return String(localized: "Allow microphone access in Settings to edit by voice.")
        case .message(let text):
            return text
        }
    }
}

/// Edit mode of the recording card: records a short spoken command, recognizes it and
/// applies it to the open tab through `RecordingService`. Commands and texts are never logged.
@MainActor
@Observable
final class VoiceEditor {
    enum Phase: Equatable {
        case idle
        case listening
        case transcribing
        case applying
    }

    private typealias Job = (recording: Recording, target: EditTarget, service: RecordingService)

    static let maxCommandDuration: TimeInterval = 30
    static let minCommandDuration: TimeInterval = 0.5

    private(set) var phase: Phase = .idle
    /// Recognized command, shown while it is applied.
    private(set) var command: String?
    private(set) var notice: VoiceEditNotice?
    private(set) var highlight: ChangeHighlight?
    /// Input level while listening, 0...1. Read only by VoiceEditStatusView.
    var level: Float { recorder.level }

    /// A separate instance from the meeting recorder, which is idle while the card is visible.
    private let recorder = AudioRecorder()
    /// Transcription and application of the recorded command.
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Watches the recorder while listening: interruptions and the duration limit.
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var fileURL: URL?
    @ObservationIgnored private var job: Job?
    /// Bumped by `cancel()` so a `start` waiting on the permission prompt does not begin
    /// listening after the card was left.
    @ObservationIgnored private var generation = 0

    init() {}

    func start(recording: Recording, target: EditTarget, service: RecordingService) async {
        guard phase == .idle else { return }
        highlight = nil
        notice = nil
        command = nil
        let startGeneration = generation
        guard await recorder.requestPermission() else {
            if startGeneration == generation {
                notice = .microphoneDenied
            }
            return
        }
        // The permission prompt may have overlapped another start or a cancel.
        guard phase == .idle, startGeneration == generation else { return }

        let url = AudioStorage.temporaryFileURL(prefix: AudioStorage.voiceCommandPrefix)
        do {
            try recorder.start(url: url)
        } catch {
            Self.removeFile(url)
            notice = .message(error.localizedDescription)
            return
        }
        job = (recording, target, service)
        fileURL = url
        phase = .listening
        startMonitor()
    }

    func finish() {
        guard phase == .listening, let url = fileURL, let job else { return }
        monitorTask?.cancel()
        monitorTask = nil
        let duration = recorder.stop()
        fileURL = nil
        self.job = nil
        phase = .transcribing
        // Uses only the captured locals: by the time it runs, `fileURL` and `job` may
        // already belong to the next command.
        task = Task {
            defer { VoiceEditor.removeFile(url) }
            await self.process(url: url, duration: duration, job: job)
        }
    }

    func cancel() {
        generation += 1
        switch phase {
        case .idle:
            return
        case .listening:
            monitorTask?.cancel()
            monitorTask = nil
            recorder.stop()
            if let fileURL {
                Self.removeFile(fileURL)
            }
            fileURL = nil
            job = nil
        case .transcribing, .applying:
            // The task deletes its file and drops its late result; `applyCommand` checks for
            // cancellation before it mutates, so the edit lands whole or not at all.
            task?.cancel()
            task = nil
        }
        command = nil
        phase = .idle
    }

    func undo(recording: Recording, target: EditTarget, service: RecordingService) {
        guard phase == .idle else { return }
        highlight = nil
        switch service.undoLastEdit(of: recording, target: target) {
        case .undone:
            notice = .undone
        case .nothingToUndo:
            notice = nil
        case .conflict:
            notice = .message(String(localized: "The text has changed since this edit, so it can't be undone."))
        case .saveFailed:
            notice = .message(VoiceEditError.saveFailed.localizedDescription)
        }
    }

    func clearHighlight() {
        highlight = nil
    }

    func dismissNotice() {
        notice = nil
    }

    // MARK: Private

    private func startMonitor() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, !Task.isCancelled, self.phase == .listening else { return }
                if self.recorder.state != .recording {
                    // A call or Siri took the microphone. Unlike the user's own cancel, this says so.
                    self.cancel()
                    self.notice = .interrupted
                } else if self.recorder.elapsed >= VoiceEditor.maxCommandDuration {
                    self.finish()
                }
            }
        }
    }

    /// Runs inside `task`. After every await it checks for cancellation before touching
    /// state: `cancel()` has already returned the editor to idle, maybe for a new command.
    private func process(url: URL, duration: TimeInterval, job: Job) async {
        do {
            guard duration >= Self.minCommandDuration else { throw VoiceEditError.emptyCommand }
            let text = try await job.service.transcribeCommand(fileURL: url)
            try Task.checkCancellation()
            guard !text.isEmpty else { throw VoiceEditError.emptyCommand }
            command = text
            phase = .applying
            let result = try await job.service.applyCommand(text, to: job.recording, target: job.target)
            try Task.checkCancellation()
            highlight = result.highlight
            notice = result.notice
            phase = .idle
        } catch {
            guard !Task.isCancelled else { return }
            // Cancelled from outside our task (e.g. by the system): silent, but the
            // editor still has to leave the busy phase.
            if !Self.isCancellation(error) {
                notice = .message(error.localizedDescription)
            }
            command = nil
            phase = .idle
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    /// The file may not exist (the recorder failed before creating it); nothing to report then.
    private static func removeFile(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
