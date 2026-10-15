import SwiftData
import SwiftUI
import UIKit

/// Recording card: transcript, summary and minutes tabs with copy, share,
/// append, manual editing and voice editing with highlights and undo.
struct RecordingDetailView: View {
    let recording: Recording

    @Environment(\.modelContext) private var context
    @Environment(AppSettings.self) private var settings
    @Environment(RecordingService.self) private var service

    @State private var tab: Tab = .transcript
    @State private var isEditing = false
    @State private var draft = ""
    @State private var recorderTarget: RecorderTarget?
    @State private var showConsent = false
    @State private var copyCount = 0
    @State private var voiceEditor = VoiceEditor()
    @State private var isVoiceEditing = false

    enum Tab: Hashable, CaseIterable {
        case transcript, summary, protocolText

        var title: LocalizedStringKey {
            switch self {
            case .transcript: "Transcript"
            case .summary: "Summary"
            case .protocolText: "Minutes"
            }
        }

        var editTarget: EditTarget {
            switch self {
            case .transcript: .transcript
            case .summary: .summary
            case .protocolText: .protocolText
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("Section", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)
            .disabled(isEditing || voiceEditor.phase != .idle)
            Divider()
            // The status view alone reads the input level; this body must not.
            if voiceEditor.phase != .idle || voiceEditor.notice != nil {
                VoiceEditStatusView(editor: voiceEditor)
                Divider()
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationTitle(recording.startedAt.formatted(date: .abbreviated, time: .omitted))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom) {
            if isEditing {
                EmptyView()
            } else if isVoiceEditing {
                VoiceEditBar(editor: voiceEditor, canStart: canVoiceEdit) { startVoiceCommand() }
            } else {
                actionBar
            }
        }
        .fullScreenCover(item: $recorderTarget) { RecorderView(target: $0) }
        .sheet(isPresented: $showConsent) { ConsentView() }
        .sensoryFeedback(.success, trigger: copyCount)
        .onChange(of: tab) { _, _ in
            isEditing = false
            voiceEditor.clearHighlight()
            voiceEditor.dismissNotice()
        }
        .onDisappear { voiceEditor.cancel() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(recording.startedAt, format: .dateTime.day().month().year().hour().minute())
                Text(verbatim: "·")
                Text(Formatters.duration(recording.duration)).monospacedDigit()
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            if !recording.title.isEmpty {
                Text(recording.title)
                    .font(.headline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if isEditing {
            TextEditor(text: $draft)
                .padding(.horizontal, 12)
        } else if tab == .transcript {
            transcriptContent
        } else if tab == .summary {
            summaryContent
        } else {
            protocolContent
        }
    }

    @ViewBuilder
    private var transcriptContent: some View {
        switch recording.status {
        case .recording:
            placeholder("Recording in progress", systemImage: "mic.fill", description: "The transcript will appear after you stop.")
        case .pending where !settings.hasAIConsent:
            ContentUnavailableView {
                Label("Not sent for recognition", systemImage: "hand.raised")
            } description: {
                Text("Allow sending audio to the AI service to get a transcript.")
            } actions: {
                Button("Review and allow") { showConsent = true }
                    .buttonStyle(.borderedProminent)
            }
        case .pending:
            ContentUnavailableView {
                Label("Waiting to be sent", systemImage: "clock")
            } description: {
                Text(recording.lastError ?? String(localized: "The recording will be sent as soon as there is a connection."))
            } actions: {
                Button("Send now") { service.retry(recording) }
            }
        case .transcribing:
            ProgressView("Transcribing…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            ContentUnavailableView {
                Label("Not recognized", systemImage: "exclamationmark.triangle")
            } description: {
                Text(recording.lastError ?? "")
            } actions: {
                Button("Retry") { service.retry(recording) }
                    .buttonStyle(.borderedProminent)
            }
        case .ready:
            if recording.transcript.isEmpty {
                placeholder("No speech recognized", systemImage: "waveform.slash")
            } else {
                textView(recording.transcript)
            }
        }
    }

    @ViewBuilder
    private var summaryContent: some View {
        if service.summarizingIDs.contains(recording.id) {
            ProgressView("Writing the summary…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !recording.summary.isEmpty {
            textView(recording.summary)
        } else if let error = service.summaryErrors[recording.id] {
            ContentUnavailableView {
                Label("Summary failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Retry") { rebuildSummary() }
                    .buttonStyle(.borderedProminent)
            }
        } else if recording.status == .ready && !recording.transcript.isEmpty {
            ContentUnavailableView {
                Label("No summary yet", systemImage: "text.alignleft")
            } actions: {
                Button("Make summary") { rebuildSummary() }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            placeholder("No summary yet", systemImage: "text.alignleft", description: "The summary is made after the transcript.")
        }
    }

    @ViewBuilder
    private var protocolContent: some View {
        if recording.protocolText.isEmpty {
            placeholder("No minutes yet", systemImage: "doc.text", description: "Minutes made from a template will appear here.")
        } else {
            textView(recording.protocolText)
        }
    }

    private func textView(_ text: String) -> some View {
        ScrollView {
            Group {
                // Drawn only over the exact string the ranges came from; any later change hides it.
                if let highlight = voiceEditor.highlight, highlight.target == tab.editTarget, highlight.text == text {
                    HighlightedText(text: highlight.text, ranges: highlight.ranges)
                } else {
                    Text(text)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }

    private func placeholder(_ title: LocalizedStringKey, systemImage: String, description: LocalizedStringKey? = nil) -> some View {
        ContentUnavailableView(title, systemImage: systemImage, description: description.map { Text($0) })
    }

    // MARK: Actions

    private var currentText: String {
        switch tab {
        case .transcript: recording.transcript
        case .summary: recording.summary
        case .protocolText: recording.protocolText
        }
    }

    private var canAppend: Bool {
        recording.status == .ready || recording.status == .failed || recording.status == .pending
    }

    private var isSummarizing: Bool {
        service.summarizingIDs.contains(recording.id)
    }

    private var canVoiceEdit: Bool {
        guard voiceEditor.phase == .idle, !currentText.isEmpty else { return false }
        switch tab {
        case .transcript: return recording.status == .ready
        case .summary: return !isSummarizing
        case .protocolText: return true
        }
    }

    private var showsUndo: Bool {
        !isEditing && EditHistory.latestStep(of: recording, target: tab.editTarget) != nil
    }

    private var canUndo: Bool {
        guard voiceEditor.phase == .idle else { return false }
        switch tab {
        case .transcript: return recording.status != .transcribing
        case .summary: return !isSummarizing
        case .protocolText: return true
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if showsUndo {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    voiceEditor.undo(recording: recording, target: tab.editTarget, service: service)
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(!canUndo)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if isEditing {
                Button("Done") { finishEditing() }
                    .fontWeight(.semibold)
            } else if isVoiceEditing {
                // Keeps the highlight so the result stays visible after leaving voice mode.
                Button("Done") {
                    isVoiceEditing = false
                    voiceEditor.dismissNotice()
                }
                .fontWeight(.semibold)
                .disabled(voiceEditor.phase != .idle)
            } else {
                Menu {
                    Button {
                        isVoiceEditing = false
                        voiceEditor.clearHighlight()
                        voiceEditor.dismissNotice()
                        draft = currentText
                        isEditing = true
                    } label: {
                        Label("Edit text", systemImage: "pencil")
                    }
                    .disabled(currentText.isEmpty || voiceEditor.phase != .idle)
                    if tab == .summary {
                        Button {
                            rebuildSummary()
                        } label: {
                            Label("Rebuild summary", systemImage: "arrow.clockwise")
                        }
                        .disabled(recording.transcript.isEmpty || isSummarizing)
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        if isEditing {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { isEditing = false }
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button {
                if settings.hasAIConsent {
                    isVoiceEditing = true
                } else {
                    showConsent = true
                }
            } label: {
                Label("Edit", systemImage: "waveform")
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!canVoiceEdit)

            Button {
                recorderTarget = .append(recording)
            } label: {
                Label("Append", systemImage: "mic.badge.plus")
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(!canAppend)

            Button {
                UIPasteboard.general.string = currentText
                copyCount += 1
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
                    .labelStyle(.iconOnly)
                    .frame(width: 44)
            }
            .buttonStyle(.bordered)
            .disabled(currentText.isEmpty)

            ShareLink(item: currentText) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .labelStyle(.iconOnly)
                    .frame(width: 44)
            }
            .buttonStyle(.bordered)
            .disabled(currentText.isEmpty)
        }
        .controlSize(.large)
        .padding()
        .background(.bar)
    }

    private func finishEditing() {
        let target = tab.editTarget
        let before = currentText
        let after = draft
        isEditing = false
        guard before != after else { return }
        EditHistory.record(recording, target: target, before: before, after: after, in: context)
        recording.setText(after, for: target)
        service.save()
    }

    /// Consent is checked here as well as in the service: nothing is recorded without it.
    private func startVoiceCommand() {
        guard settings.hasAIConsent else {
            showConsent = true
            return
        }
        let target = tab.editTarget
        Task { await voiceEditor.start(recording: recording, target: target, service: service) }
    }

    private func rebuildSummary() {
        Task { await service.summarize(recording) }
    }
}
