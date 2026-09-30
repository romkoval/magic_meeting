import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings
    @Environment(RecordingService.self) private var service
    @State private var showConsent = false
    @State private var confirmDeleteAll = false

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section {
                    if settings.hasAIConsent {
                        LabeledContent("Sending to the AI service", value: String(localized: "Allowed"))
                        Button("Withdraw consent", role: .destructive) {
                            settings.hasAIConsent = false
                        }
                    } else {
                        LabeledContent("Sending to the AI service", value: String(localized: "Not allowed"))
                        Button("Review and allow") { showConsent = true }
                    }
                } header: {
                    Text("Transcription")
                } footer: {
                    Text("Recording works without consent; recordings are transcribed once you allow sending.")
                }

                Section {
                    Picker("Recognition language", selection: $settings.recognitionLanguage) {
                        Text("Automatic").tag("")
                        Text("English").tag("en")
                        Text("Russian").tag("ru")
                    }
                } footer: {
                    Text("Automatic detection works for most meetings. Pick a language if short recordings are recognized in the wrong one.")
                }

                Section {
                    if let url = settings.privacyPolicyURL {
                        Link("Privacy Policy", destination: url)
                    }
                    Button("Delete all data", role: .destructive) { confirmDeleteAll = true }
                } footer: {
                    Text("Deletes all recordings, audio and texts from this iPhone.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showConsent) { ConsentView() }
            .confirmationDialog("Delete all recordings and texts?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                Button("Delete all data", role: .destructive) { service.deleteAllData() }
            } message: {
                Text("This cannot be undone.")
            }
        }
    }
}
