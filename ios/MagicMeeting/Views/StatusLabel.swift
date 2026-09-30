import SwiftUI

extension RecordingStatus {
    var label: LocalizedStringKey {
        switch self {
        case .recording: "Recording…"
        case .pending: "Waiting to be sent"
        case .transcribing: "Transcribing…"
        case .ready: "Ready"
        case .failed: "Not recognized"
        }
    }
}
