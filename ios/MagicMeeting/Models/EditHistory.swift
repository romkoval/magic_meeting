import Foundation
import SwiftData

enum EditHistory {
    static let limit = 20

    /// Stores a step and trims the recording's history to `limit` entries.
    @MainActor
    static func record(_ recording: Recording, target: EditTarget, before: String, after: String, command: String? = nil, in context: ModelContext) {
        guard before != after else { return }
        let step = EditStep(target: target, before: before, after: after, command: command)
        context.insert(step)
        recording.editSteps.append(step)
        let excess = recording.editSteps.sorted { $0.createdAt > $1.createdAt }.dropFirst(limit)
        for old in excess {
            context.delete(old)
        }
    }
}
