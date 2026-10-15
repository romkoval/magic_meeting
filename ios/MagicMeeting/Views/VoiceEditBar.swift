import SwiftUI

/// Bottom bar of voice edit mode: one big hold-or-tap button.
/// Hold: speak while pressing, release to apply. Tap: tap to start, tap again to apply.
struct VoiceEditBar: View {
    let editor: VoiceEditor
    /// False when the open tab has nothing to edit or is busy.
    let canStart: Bool
    /// Parent checks consent and calls `editor.start(recording:target:service:)` in a Task.
    let onStart: () -> Void

    /// Releasing after this long finishes a command started by the same press.
    private static let holdThreshold: TimeInterval = 0.4

    @State private var pressStart: Date?
    @State private var startedByThisPress = false
    /// Resets on its own when the system cancels the touch, which `onEnded` does not report.
    @GestureState private var isTouching = false

    var body: some View {
        VStack(spacing: 12) {
            micButton
            caption
                .font(.footnote)
                .frame(minHeight: 28)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.bar)
    }

    // MARK: Button

    private var isListening: Bool { editor.phase == .listening }

    private var isBusy: Bool { editor.phase == .transcribing || editor.phase == .applying }

    private var isActive: Bool { isListening || (editor.phase == .idle && canStart) }

    private var fill: Color {
        switch editor.phase {
        case .idle: Color.accentColor
        case .listening: Color.red
        case .transcribing, .applying: Color.gray
        }
    }

    private var micButton: some View {
        ZStack {
            Circle().fill(fill)
            if isBusy {
                ProgressView()
                    .tint(.white)
            } else {
                Image(systemName: isListening ? "stop.fill" : "mic.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 88, height: 88)
        .opacity(isActive || isBusy ? 1 : 0.4)
        .scaleEffect(isListening ? 1.08 : 1)
        .animation(.easeOut(duration: 0.15), value: editor.phase)
        .contentShape(Circle())
        .gesture(press)
        .onChange(of: isTouching) { _, touching in
            if !touching { pressStart = nil }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityAction { toggle() }
        .sensoryFeedback(.start, trigger: editor.phase) { _, new in new == .listening }
    }

    private var accessibilityTitle: Text {
        switch editor.phase {
        case .idle: Text("Speak a command")
        case .listening: Text("Stop and apply")
        case .transcribing, .applying: Text("Applying…")
        }
    }

    @ViewBuilder
    private var caption: some View {
        switch editor.phase {
        case .idle:
            Text("Hold or tap and speak a command")
                .foregroundStyle(.secondary)
        case .listening:
            Text("Tap to finish")
                .foregroundStyle(.secondary)
        case .transcribing, .applying:
            Button("Cancel") { editor.cancel() }
        }
    }

    // MARK: Gesture

    private var press: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isTouching) { _, state, _ in state = true }
            .onChanged { _ in
                if pressStart == nil { pressBegan() }
            }
            .onEnded { _ in pressEnded() }
    }

    private func pressBegan() {
        pressStart = .now
        startedByThisPress = editor.phase == .idle && canStart
        if startedByThisPress { onStart() }
    }

    private func pressEnded() {
        let held = pressStart.map { Date.now.timeIntervalSince($0) } ?? 0
        pressStart = nil
        guard isListening else { return }
        if !startedByThisPress {
            editor.finish()            // second tap of tap mode
        } else if held >= Self.holdThreshold {
            editor.finish()            // release after a hold
        }
        // Otherwise it was the first tap of tap mode: keep listening.
    }

    /// VoiceOver cannot hold, so its activation toggles start and finish.
    private func toggle() {
        switch editor.phase {
        case .idle where canStart: onStart()
        case .listening: editor.finish()
        default: break
        }
    }
}
