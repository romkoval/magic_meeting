import SwiftData
import SwiftUI

@main
struct MagicMeetingApp: App {
    private let container: ModelContainer
    @State private var settings: AppSettings
    @State private var recorder: AudioRecorder
    @State private var service: RecordingService

    init() {
        let container: ModelContainer
        do {
            // SwiftData puts its store here but does not create the folder on first launch.
            try FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
            container = try ModelContainer(for: Recording.self, AudioSegment.self, Highlight.self,
                                           ProtocolTemplate.self, EditStep.self, GlossaryTerm.self)
        } catch {
            fatalError("Could not open the local store: \(error)")
        }
        let settings = AppSettings()
        self.container = container
        _settings = State(initialValue: settings)
        _recorder = State(initialValue: AudioRecorder())
        _service = State(initialValue: RecordingService(context: container.mainContext, settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(recorder)
                .environment(service)
        }
        .modelContainer(container)
    }
}

private struct RootView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(RecordingService.self) private var service
    @Environment(\.scenePhase) private var scenePhase
    @State private var showConsent = false

    var body: some View {
        HistoryView()
            .task {
                service.start()
                showConsent = !settings.consentPromptShown
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { service.processPending() }
            }
            .sheet(isPresented: $showConsent) {
                ConsentView()
                    .interactiveDismissDisabled()
            }
    }
}
