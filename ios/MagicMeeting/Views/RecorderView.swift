import SwiftData
import SwiftUI
import UIKit

/// Recording mode: everything said here is meeting content (TZ §2).
struct RecorderView: View {
    let target: RecorderTarget
    var onFinish: (Recording) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @Environment(AudioRecorder.self) private var recorder
    @Environment(RecordingService.self) private var service

    @State private var recording: Recording?
    @State private var previousStatus: RecordingStatus?
    @State private var segmentID = UUID()
    @State private var permissionDenied = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()
                Text(statusTitle)
                    .font(.headline)
                    .foregroundStyle(recorder.state == .recording ? Color.red : Color.secondary)
                Text(Formatters.duration(recorder.elapsed))
                    .font(.system(size: 64, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                LevelMeterView(level: recorder.state == .recording ? recorder.level : 0)
                    .tint(.red)
                    .padding(.horizontal, 48)
                if recorder.wasInterrupted {
                    interruptionBanner
                }
                Spacer()
                controls
                    .padding(.bottom, 24)
            }
            .padding()
            .navigationTitle(isAppending ? "Append to recording" : "New recording")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if recorder.state == .idle {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
            .alert("Microphone access is off", isPresented: $permissionDenied) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    dismiss()
                }
                Button("Close", role: .cancel) { dismiss() }
            } message: {
                Text("Allow microphone access in Settings to record meetings.")
            }
            .alert("Recording failed", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil; dismiss() } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .interactiveDismissDisabled()
        .task { await start() }
    }

    private var isAppending: Bool {
        if case .append = target { return true }
        return false
    }

    private var statusTitle: LocalizedStringKey {
        switch recorder.state {
        case .idle: "Preparing…"
        case .recording: "Recording"
        case .paused: "Paused"
        }
    }

    private var interruptionBanner: some View {
        VStack(spacing: 12) {
            Text("Recording was paused by a call or Siri.")
                .multilineTextAlignment(.center)
            Button("Continue recording") { recorder.resume() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
    }

    private var controls: some View {
        HStack(spacing: 56) {
            Button {
                recorder.state == .recording ? recorder.pause() : recorder.resume()
            } label: {
                Image(systemName: recorder.state == .recording ? "pause.fill" : "play.fill")
                    .font(.title)
                    .frame(width: 72, height: 72)
                    .background(.quaternary, in: Circle())
            }
            .accessibilityLabel(recorder.state == .recording ? Text("Pause") : Text("Continue"))

            Button(action: stop) {
                Image(systemName: "stop.fill")
                    .font(.title)
                    .foregroundStyle(.white)
                    .frame(width: 88, height: 88)
                    .background(.red, in: Circle())
            }
            .accessibilityLabel(Text("Stop"))
        }
        .buttonStyle(.plain)
        .disabled(recorder.state == .idle)
    }

    private func start() async {
        guard recording == nil, recorder.state == .idle else { return }
        guard await recorder.requestPermission() else {
            permissionDenied = true
            return
        }

        let destination: Recording
        switch target {
        case .new:
            destination = Recording()
            context.insert(destination)
        case .append(let existing):
            destination = existing
            previousStatus = existing.status
        }

        do {
            let url = try AudioStorage.prepareSegmentFile(recordingID: destination.id, segmentID: segmentID)
            try recorder.start(url: url)
            destination.status = .recording
            recording = destination
            service.save()
        } catch {
            rollBack(destination)
            errorMessage = error.localizedDescription
        }
    }

    private func stop() {
        guard let recording else {
            dismiss()
            return
        }
        let duration = recorder.stop()
        let fileName = AudioStorage.fileName(for: segmentID)

        // A tap on stop right after start leaves nothing worth sending.
        guard duration >= 0.5 else {
            AudioStorage.deleteFile(recordingID: recording.id, fileName: fileName)
            rollBack(recording)
            dismiss()
            return
        }

        let segment = AudioSegment(id: segmentID, order: recording.nextSegmentOrder, fileName: fileName, duration: duration)
        context.insert(segment)
        recording.segments.append(segment)
        recording.duration += duration
        recording.status = .pending
        service.save()

        Task { await service.process(recording) }
        onFinish(recording)
        dismiss()
    }

    /// Undo whatever `start` did to the model when no audio was kept.
    private func rollBack(_ recording: Recording) {
        if recording.segments.isEmpty {
            AudioStorage.deleteFiles(recordingID: recording.id)
            context.delete(recording)
        } else {
            recording.status = previousStatus ?? .pending
        }
        service.save()
    }
}
