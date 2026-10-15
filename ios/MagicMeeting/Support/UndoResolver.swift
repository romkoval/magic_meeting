import Foundation

enum UndoResolution: Equatable {
    case restore(String)
    /// The text changed after the step in a way we cannot reconcile; refuse rather than lose text.
    case conflict
}

enum UndoResolver {
    /// `allowsAppend` is true only for the transcript, the one target that grows by appended segments.
    static func resolve(current: String, before: String, after: String, allowsAppend: Bool) -> UndoResolution {
        if current == after { return .restore(before) }

        // Byte-exact on purpose: Character equality would also accept canonically
        // equivalent text, and then the byte count of `after` would cut `current` in the wrong place.
        if allowsAppend, !after.isEmpty, current.utf8.starts(with: after.utf8) {
            let suffix = String(decoding: current.utf8.dropFirst(after.utf8.count), as: UTF8.self)
            // Nothing to glue the suffix to, so the separator that was added with it goes too.
            if before.isEmpty { return .restore(String(suffix.drop(while: \.isWhitespace))) }
            return .restore(before + suffix)
        }
        return .conflict
    }
}
