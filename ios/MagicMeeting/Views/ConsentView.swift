import SwiftUI

/// Explicit consent before the first upload to a third-party AI service (TZ §8).
struct ConsentView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings
    @Environment(RecordingService.self) private var service

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Before you record")
                        .font(.largeTitle.bold())
                    ConsentPoint(
                        systemImage: "waveform",
                        title: "What is sent",
                        text: "The audio of your recordings and the texts made from it: transcripts, summaries, minutes and your voice commands."
                    )
                    ConsentPoint(
                        systemImage: "server.rack",
                        title: "Where it goes",
                        text: "To our server, which passes it to Groq, an AI service that processes it on our behalf. Our server does not store the content of your meetings."
                    )
                    ConsentPoint(
                        systemImage: "text.badge.checkmark",
                        title: "Why",
                        text: "To turn speech into text with punctuation and to write summaries and minutes."
                    )
                    ConsentPoint(
                        systemImage: "person.2.wave.2",
                        title: "Tell the participants",
                        text: "Let everyone in the meeting know that you are recording it."
                    )
                    Text("Without consent you can still record, and nothing leaves your iPhone, but recordings will not be transcribed. You can change this in Settings.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let url = settings.privacyPolicyURL {
                        Link("Privacy Policy", destination: url)
                            .font(.footnote)
                    }
                }
                .padding()
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Button {
                        settings.hasAIConsent = true
                        settings.consentPromptShown = true
                        service.processPending()
                        dismiss()
                    } label: {
                        Text("I agree")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Not now") {
                        settings.consentPromptShown = true
                        dismiss()
                    }
                }
                .controlSize(.large)
                .padding()
                .background(.bar)
            }
        }
    }
}

private struct ConsentPoint: View {
    let systemImage: String
    let title: LocalizedStringKey
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary)
            }
        }
    }
}
