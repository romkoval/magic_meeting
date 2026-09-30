import Foundation

/// What the recorder screen writes to: a new recording or the end of an existing one.
enum RecorderTarget: Identifiable {
    case new
    case append(Recording)

    var id: String {
        switch self {
        case .new: "new"
        case .append(let recording): recording.id.uuidString
        }
    }
}
