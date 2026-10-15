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

enum UndoOutcome: Equatable {
    case undone
    case nothingToUndo
    case conflict
}

extension EditHistory {
    /// Most recent step (by createdAt) for `target`.
    @MainActor
    static func latestStep(of recording: Recording, target: EditTarget) -> EditStep? {
        // Steps trimmed by `record` stay in the relationship until the next save.
        recording.editSteps
            .filter { !$0.isDeleted && $0.targetRaw == target.rawValue }
            .max { $0.createdAt < $1.createdAt }
    }

    /// Reverts the latest step of `target`. On a conflict nothing changes and the step
    /// is kept rather than losing text written after it. The caller saves.
    @MainActor
    static func undo(_ recording: Recording, target: EditTarget, in context: ModelContext) -> UndoOutcome {
        guard let step = latestStep(of: recording, target: target) else { return .nothingToUndo }
        let resolution = UndoResolver.resolve(
            current: recording.text(for: target),
            before: step.before,
            after: step.after,
            allowsAppend: target == .transcript
        )
        switch resolution {
        case .restore(let text):
            recording.setText(text, for: target)
            recording.editSteps.removeAll { $0.id == step.id }
            context.delete(step)
            return .undone
        case .conflict:
            return .conflict
        }
    }
}
