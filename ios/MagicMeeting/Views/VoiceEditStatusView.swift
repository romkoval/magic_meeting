import SwiftUI
import UIKit

/// Status line above the text in voice edit mode. The only view that reads
/// `editor.level`, so its 10 Hz updates do not rebuild the text below.
struct VoiceEditStatusView: View {
    let editor: VoiceEditor

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                row
            }
            if isBusy, let command = editor.command {
                Text(command)
                    .font(.footnote)
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var isBusy: Bool { editor.phase == .transcribing || editor.phase == .applying }

    @ViewBuilder
    private var row: some View {
        switch editor.phase {
        case .listening:
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
            Text("Listening…")
            LevelMeterView(level: editor.level)
                .tint(.red)
        case .transcribing, .applying:
            ProgressView()
            Text("Applying…")
        case .idle:
            if let notice = editor.notice {
                Text(notice.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if notice == .microphoneDenied {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    .buttonStyle(.borderless)
                }
                Button {
                    editor.dismissNotice()
                } label: {
                    Label("Close", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
    }
}
