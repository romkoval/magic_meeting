import Foundation
import Network
import Observation
import SwiftData

enum RecordingServiceError: LocalizedError {
    case audioMissing

    var errorDescription: String? {
        String(localized: "The audio file of this recording is missing.")
    }
}

/// Sends recordings to the proxy and keeps their state in SwiftData:
/// transcription after stop, summary after transcription, the offline queue,
/// retries and deletion.
@MainActor
@Observable
final class RecordingService {
    private(set) var transcribingIDs: Set<UUID> = []
    private(set) var summarizingIDs: Set<UUID> = []
    private(set) var summaryErrors: [UUID: String] = [:]

    private let context: ModelContext
    private let settings: AppSettings
    private let monitor = NWPathMonitor()
    @ObservationIgnored private var started = false
    /// Temporary audio created before this is left over from an earlier run.
    private let launchDate = Date.now

    init(context: ModelContext, settings: AppSettings) {
        self.context = context
        self.settings = settings
    }

    /// Call once at launch: repairs recordings cut off by a crash, removes their temporary
    /// audio and starts the offline queue.
    func start() {
        guard !started else { return }
        started = true
        AudioStorage.deleteTemporaryFiles(createdBefore: launchDate)
        recoverInterrupted()
        monitor.pathUpdateHandler = { @Sendable [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.processPending() }
        }
        monitor.start(queue: DispatchQueue(label: "app.magicmeeting.network-monitor"))
        processPending()
    }

    // MARK: Queue

    func processPending() {
        guard settings.hasAIConsent else { return }
        let pending = RecordingStatus.pending.rawValue
        let descriptor = FetchDescriptor<Recording>(
            predicate: #Predicate<Recording> { $0.statusRaw == pending },
            sortBy: [SortDescriptor(\.startedAt)]
        )
        for recording in (try? context.fetch(descriptor)) ?? [] {
            Task { await process(recording) }
        }
    }

    /// Transcribes every segment that has no transcript yet, then rebuilds the summary.
    func process(_ recording: Recording) async {
        let id = recording.id
        guard !transcribingIDs.contains(id), recording.status != .recording else { return }
        guard settings.hasAIConsent else {
            recording.status = .pending
            save()
            return
        }
        guard let client = makeClient() else {
            markFailed(recording, error: ProxyError.notConfigured)
            return
        }

        transcribingIDs.insert(id)
        defer { transcribingIDs.remove(id) }
        recording.status = .transcribing
        recording.lastError = nil
        save()

        do {
            while let segment = recording.orderedSegments.first(where: { $0.transcript == nil }) {
                let (text, timings) = try await transcribe(segment, of: recording, client: client)
                guard isAlive(recording) else { return }
                segment.timings = timings
                segment.transcript = text
                recording.applySegmentTranscript(text)
                save()
            }
            recording.status = .ready
            save()
        } catch {
            guard isAlive(recording) else { return }
            if isOffline(error) {
                // Stays queued; the network monitor picks it up when the connection returns.
                recording.status = .pending
                recording.lastError = ProxyError.offline.localizedDescription
                save()
            } else {
                markFailed(recording, error: error)
            }
            return
        }
        await summarize(recording)
    }

    func retry(_ recording: Recording) {
        Task { await process(recording) }
    }

    private func transcribe(_ segment: AudioSegment, of recording: Recording, client: ProxyClient) async throws -> (String, [TranscriptTiming]) {
        let url = AudioStorage.fileURL(recordingID: recording.id, fileName: segment.fileName)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw RecordingServiceError.audioMissing
        }
        let ranges = AudioChunker.ranges(duration: segment.duration)
        let chunks = ranges.count > 1 ? try await AudioChunker.export(url, ranges: ranges) : [url]
        defer {
            if ranges.count > 1 { AudioChunker.remove(chunks) }
        }

        let glossary = glossaryTerms()
        let language = settings.recognitionLanguage.isEmpty ? nil : settings.recognitionLanguage
        var text = ""
        var timings: [TranscriptTiming] = []
        for (chunk, range) in zip(chunks, ranges) {
            let result = try await client.transcribe(fileURL: chunk, glossary: glossary, language: language)
            text = TranscriptMerger.merge(text, result.text)
            timings = TimingMerger.append(result.segments ?? [], to: timings, offset: range.lowerBound)
            if let detected = LanguageCode.normalize(result.language), isAlive(recording) {
                recording.language = detected
            }
        }
        return (text, timings)
    }

    // MARK: Summary

    /// Generates the one-line description and the summary from the transcript.
    func summarize(_ recording: Recording) async {
        let id = recording.id
        let transcript = recording.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.hasAIConsent, !transcript.isEmpty, !summarizingIDs.contains(id) else { return }
        guard let client = makeClient() else {
            summaryErrors[id] = ProxyError.notConfigured.localizedDescription
            return
        }

        summarizingIDs.insert(id)
        defer { summarizingIDs.remove(id) }
        summaryErrors[id] = nil

        let input = LLMInput(
            transcript: transcript,
            glossary: glossaryTerms(),
            language: recording.language,
            uiLanguage: settings.interfaceLanguage
        )
        do {
            let result = try await client.llm(.summarize, input, as: SummaryResult.self)
            guard isAlive(recording) else { return }
            if !recording.summary.isEmpty {
                EditHistory.record(recording, target: .summary, before: recording.summary, after: result.summary, in: context)
            }
            recording.title = result.title
            recording.summary = result.summary
            save()
        } catch {
            summaryErrors[id] = error.localizedDescription
        }
    }

    // MARK: Voice editing

    /// Recognizes a short spoken command (glossary + settings.recognitionLanguage). Returns trimmed text, possibly empty.
    /// Throws VoiceEditError.needsConsent, ProxyError (incl. .notConfigured), CancellationError.
    func transcribeCommand(fileURL: URL) async throws -> String {
        guard settings.hasAIConsent else { throw VoiceEditError.needsConsent }
        guard let client = makeVoiceEditClient() else { throw ProxyError.notConfigured }
        let language = settings.recognitionLanguage.isEmpty ? nil : settings.recognitionLanguage
        let result = try await client.transcribe(fileURL: fileURL, glossary: glossaryTerms(), language: language)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sends the command with the target's text to the LLM, applies the result, records an
    /// EditStep (with `command`) and saves. Throws VoiceEditError.needsConsent / .nothingToChange /
    /// .textChanged / .saveFailed, ProxyError, CancellationError. Never mutates anything when it throws.
    func applyCommand(_ command: String, to recording: Recording, target: EditTarget) async throws -> VoiceEditResult {
        guard settings.hasAIConsent else { throw VoiceEditError.needsConsent }
        guard let client = makeVoiceEditClient() else { throw ProxyError.notConfigured }
        let before = recording.text(for: target)
        guard !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceEditError.nothingToChange
        }
        let glossary = glossaryTerms()
        switch target {
        case .transcript:
            let input = LLMInput(
                transcript: before,
                command: command,
                glossary: glossary,
                language: recording.language,
                uiLanguage: settings.interfaceLanguage
            )
            return try await applyReplacements(input, command: command, to: recording, client: client)
        case .summary, .protocolText:
            let input = LLMInput(
                text: before,
                command: command,
                glossary: glossary,
                language: recording.language,
                uiLanguage: settings.interfaceLanguage
            )
            return try await applyFullText(input, before: before, command: command, to: recording, target: target, client: client)
        }
    }

    /// EditHistory.undo + save. A failed save rolls the undo back and returns `.saveFailed`.
    func undoLastEdit(of recording: Recording, target: EditTarget) -> UndoOutcome {
        let outcome = EditHistory.undo(recording, target: target, in: context)
        guard outcome == .undone else { return outcome }
        do {
            try saveOrRollback()
        } catch {
            return .saveFailed
        }
        return .undone
    }

    private func applyReplacements(_ input: LLMInput, command: String, to recording: Recording, client: ProxyClient) async throws -> VoiceEditResult {
        let result = try await client.llm(.editTranscript, input, as: ReplacementsResult.self)
        try Task.checkCancellation()
        guard isAlive(recording) else { throw CancellationError() }
        // Applied to the current text, not the one sent: a segment may have been appended
        // meanwhile, and the replacements still find their fragments in it.
        let current = recording.transcript
        let outcome = ReplacementApplier.apply(result.replacements, to: current)
        guard outcome.appliedCount > 0, outcome.text != current else { throw VoiceEditError.nothingToChange }
        EditHistory.record(recording, target: .transcript, before: current, after: outcome.text, command: command, in: context)
        recording.setText(outcome.text, for: .transcript)
        try saveOrRollback()
        return VoiceEditResult(
            highlight: ChangeHighlight(target: .transcript, text: outcome.text, ranges: outcome.changedRanges),
            changeCount: outcome.appliedCount
        )
    }

    private func applyFullText(_ input: LLMInput, before: String, command: String, to recording: Recording, target: EditTarget, client: ProxyClient) async throws -> VoiceEditResult {
        let result = try await client.llm(.editText, input, as: TextResult.self)
        try Task.checkCancellation()
        guard isAlive(recording) else { throw CancellationError() }
        // A summary regenerated during the request must not be overwritten by an edit of the old one.
        guard recording.text(for: target) == before else { throw VoiceEditError.textChanged }
        guard result.text != before else { throw VoiceEditError.nothingToChange }
        EditHistory.record(recording, target: target, before: before, after: result.text, command: command, in: context)
        recording.setText(result.text, for: target)
        try saveOrRollback()
        // No ranges when the text is too long to diff; the notice then says it is not highlighted.
        let ranges = WordDiff.changedRanges(from: before, to: result.text)
        return VoiceEditResult(
            highlight: ranges.flatMap { ChangeHighlight(target: target, text: result.text, ranges: $0) },
            changeCount: nil
        )
    }

    // MARK: Deletion

    func delete(_ recording: Recording) {
        AudioStorage.deleteFiles(recordingID: recording.id)
        summaryErrors[recording.id] = nil
        context.delete(recording)
        save()
    }

    /// "Delete all data" in Settings: recordings, audio, templates and glossary.
    func deleteAllData() {
        for recording in (try? context.fetch(FetchDescriptor<Recording>())) ?? [] {
            context.delete(recording)
        }
        try? context.delete(model: ProtocolTemplate.self)
        try? context.delete(model: GlossaryTerm.self)
        AudioStorage.deleteAll()
        summaryErrors = [:]
        save()
    }

    // MARK: Helpers

    /// A crash or kill during recording leaves an unfinished m4a that cannot be read.
    private func recoverInterrupted() {
        let recordingStatus = RecordingStatus.recording.rawValue
        let transcribingStatus = RecordingStatus.transcribing.rawValue
        let descriptor = FetchDescriptor<Recording>(
            predicate: #Predicate<Recording> { $0.statusRaw == recordingStatus || $0.statusRaw == transcribingStatus }
        )
        for recording in (try? context.fetch(descriptor)) ?? [] {
            if recording.segments.isEmpty {
                AudioStorage.deleteFiles(recordingID: recording.id)
                context.delete(recording)
            } else {
                recording.status = recording.segments.contains { $0.transcript == nil } ? .pending : .ready
            }
        }
        save()
    }

    private func markFailed(_ recording: Recording, error: Error) {
        recording.status = .failed
        recording.lastError = error.localizedDescription
        save()
    }

    private func isOffline(_ error: Error) -> Bool {
        if case ProxyError.offline = error { return true }
        // Queued like a lost connection, so the audio is sent again later.
        if case ProxyError.timedOut = error { return true }
        if let urlError = error as? URLError { return ProxyError.offlineCodes.contains(urlError.code) }
        return false
    }

    private func isAlive(_ recording: Recording) -> Bool {
        !recording.isDeleted && recording.modelContext != nil
    }

    private func makeClient() -> ProxyClient? {
        ProxyConfiguration.fromBundle().map { ProxyClient(configuration: $0, deviceID: settings.deviceID) }
    }

    /// Voice edits fail fast: the user is waiting on the card, and the text stays as it was.
    private func makeVoiceEditClient() -> ProxyClient? {
        guard var client = makeClient() else { return nil }
        client.maxAttempts = 2
        client.maxRetryDelay = 1
        client.requestTimeout = 20
        return client
    }

    /// Newest first: the proxy keeps only the head of the list that fits the Whisper prompt.
    private func glossaryTerms() -> [String] {
        let descriptor = FetchDescriptor<GlossaryTerm>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return ((try? context.fetch(descriptor)) ?? []).map(\.term)
    }

    func save() {
        do {
            try context.save()
        } catch {
            assertionFailure("SwiftData save failed: \(error)")
        }
    }

    /// For voice edits and undo, which report a failed save instead of showing a change that
    /// is not stored: the context goes back to its last saved state, dropping the change and its step.
    private func saveOrRollback() throws {
        do {
            try context.save()
        } catch {
            context.rollback()
            throw VoiceEditError.saveFailed
        }
    }
}

enum LanguageCode {
    /// Whisper's verbose_json reports full names ("russian"); we store ISO-639-1 codes.
    static func normalize(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces).lowercased(), !value.isEmpty else { return nil }
        switch value {
        case "russian": return "ru"
        case "english": return "en"
        default: return value
        }
    }
}
