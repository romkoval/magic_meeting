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

    init(context: ModelContext, settings: AppSettings) {
        self.context = context
        self.settings = settings
    }

    /// Call once at launch: repairs recordings cut off by a crash and starts the offline queue.
    func start() {
        guard !started else { return }
        started = true
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
                let text = try await transcribe(segment, of: recording, client: client)
                guard isAlive(recording) else { return }
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

    private func transcribe(_ segment: AudioSegment, of recording: Recording, client: ProxyClient) async throws -> String {
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
        for chunk in chunks {
            let result = try await client.transcribe(fileURL: chunk, glossary: glossary, language: language)
            text = TranscriptMerger.merge(text, result.text)
            if let detected = LanguageCode.normalize(result.language), isAlive(recording) {
                recording.language = detected
            }
        }
        return text
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
        if let urlError = error as? URLError { return ProxyError.offlineCodes.contains(urlError.code) }
        return false
    }

    private func isAlive(_ recording: Recording) -> Bool {
        !recording.isDeleted && recording.modelContext != nil
    }

    private func makeClient() -> ProxyClient? {
        ProxyConfiguration.fromBundle().map { ProxyClient(configuration: $0, deviceID: settings.deviceID) }
    }

    private func glossaryTerms() -> [String] {
        let descriptor = FetchDescriptor<GlossaryTerm>(sortBy: [SortDescriptor(\.term)])
        return ((try? context.fetch(descriptor)) ?? []).map(\.term)
    }

    func save() {
        do {
            try context.save()
        } catch {
            assertionFailure("SwiftData save failed: \(error)")
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
