import SwiftData
import SwiftUI

struct HistoryView: View {
    @Environment(RecordingService.self) private var service
    @Query(sort: \Recording.startedAt, order: .reverse) private var recordings: [Recording]
    @State private var path: [Recording] = []
    @State private var search = ""
    @State private var recorderTarget: RecorderTarget?
    @State private var showSettings = false

    private var filtered: [Recording] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return recordings }
        return recordings.filter {
            $0.title.localizedStandardContains(query) || $0.transcript.localizedStandardContains(query)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(filtered) { recording in
                    NavigationLink(value: recording) {
                        RecordingRow(recording: recording)
                    }
                    .deleteDisabled(recording.status == .recording)
                }
                .onDelete { offsets in
                    for recording in offsets.map({ filtered[$0] }) {
                        service.delete(recording)
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if recordings.isEmpty {
                    ContentUnavailableView {
                        Label("No recordings yet", systemImage: "waveform")
                    } description: {
                        Text("Tap the button below to record a meeting.")
                    }
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            .searchable(text: $search, prompt: Text("Search transcripts"))
            .navigationTitle("Recordings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                RecordButton { recorderTarget = .new }
                    .padding(.bottom, 8)
            }
            .navigationDestination(for: Recording.self) { recording in
                RecordingDetailView(recording: recording)
            }
            .fullScreenCover(item: $recorderTarget) { target in
                RecorderView(target: target) { recording in
                    path = [recording]
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
        }
    }
}

private struct RecordingRow: View {
    let recording: Recording
    @Environment(RecordingService.self) private var service

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(recording.startedAt, format: .dateTime.day().month().year().hour().minute())
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(Formatters.duration(recording.duration))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if !recording.title.isEmpty {
                Text(recording.title)
                    .lineLimit(2)
            } else if service.summarizingIDs.contains(recording.id) {
                Text("Writing a description…")
                    .foregroundStyle(.secondary)
            } else {
                Text(recording.status.label)
                    .foregroundStyle(recording.status == .failed ? Color.red : Color.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct RecordButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Record", systemImage: "mic.fill")
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .tint(.red)
        .controlSize(.large)
        .padding(.horizontal)
    }
}
