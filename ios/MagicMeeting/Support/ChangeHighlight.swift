import Foundation

/// Transient: which fragments the last voice edit changed. Never persisted.
struct ChangeHighlight: Equatable {
    /// Past this many marks the text reads as one big highlight, and every range costs
    /// AttributedString work on the main actor.
    static let maxRanges = 500

    let target: EditTarget
    /// The exact text the ranges index into.
    let text: String
    let ranges: [Range<String.Index>]

    /// Nil above `maxRanges` ranges: the edit is kept, just not marked.
    init?(target: EditTarget, text: String, ranges: [Range<String.Index>]) {
        guard ranges.count <= Self.maxRanges else { return nil }
        self.target = target
        self.text = text
        self.ranges = ranges
    }
}
