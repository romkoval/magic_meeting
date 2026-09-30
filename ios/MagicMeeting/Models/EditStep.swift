import Foundation
import SwiftData

enum EditTarget: String, Codable, Sendable {
    case transcript
    case summary
    case protocolText = "protocol"
}

/// One undoable change. The last `EditHistory.limit` steps are kept per recording.
@Model
final class EditStep {
    @Attribute(.unique) var id: UUID
    var targetRaw: String
    var before: String
    var after: String
    /// Voice command that caused the change; nil for manual edits and regenerations.
    var command: String?
    var createdAt: Date
    var recording: Recording?

    init(id: UUID = UUID(), target: EditTarget, before: String, after: String, command: String?, createdAt: Date = .now) {
        self.id = id
        self.targetRaw = target.rawValue
        self.before = before
        self.after = after
        self.command = command
        self.createdAt = createdAt
    }

    var target: EditTarget? { EditTarget(rawValue: targetRaw) }
}
