import Foundation

/// Transient: which fragments the last voice edit changed. Never persisted.
struct ChangeHighlight: Equatable {
    let target: EditTarget
    /// The exact text the ranges index into.
    let text: String
    let ranges: [Range<String.Index>]
}
