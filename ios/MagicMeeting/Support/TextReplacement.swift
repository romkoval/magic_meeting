import Foundation

/// One point replacement from `edit_transcript`; mirrors proxy `Replacement`.
struct TextReplacement: Codable, Sendable, Equatable {
    let find: String
    let replace: String
    let all: Bool
}

struct ReplacementOutcome: Equatable {
    /// Text after all replacements.
    let text: String
    /// Ranges in `text` covering inserted replacement text: sorted, non-empty,
    /// non-overlapping, adjacent/overlapping ranges merged. Pure deletions leave no range.
    let changedRanges: [Range<String.Index>]
    /// Number of occurrences actually replaced.
    let appliedCount: Int
}

/// Applies `edit_transcript` replacements. The replacements come from a model, so the
/// work stays linear in the text size no matter how many matches a `find` has, and the
/// number, size and growth of replacements are capped.
enum ReplacementApplier {
    /// A spoken command names a few fixes; a longer list is model noise.
    static let maxReplacements = 50
    /// Longer than any fragment a spoken command can name.
    static let maxFragmentBytes = 2_000
    /// The text may grow to twice its size, or by this much if that is more, so a chain
    /// like "a" -> "aa" repeated cannot grow it exponentially on the main actor.
    static let minGrowthAllowance = 64 * 1_024

    /// One matched occurrence, in UTF-8 offsets of the text it was found in.
    private struct Edit {
        let lo: Int
        let hi: Int
        let newLength: Int
        var delta: Int { newLength - (hi - lo) }
    }

    static func apply(_ replacements: [TextReplacement], to text: String) -> ReplacementOutcome {
        var current = text
        var currentSize = text.utf8.count
        let maxSize = max(2 * currentSize, currentSize + minGrowthAllowance)
        // Offsets, not String.Index: mutating the string invalidates its indices.
        var marks: [Range<Int>] = []
        var applied = 0
        for replacement in replacements.prefix(maxReplacements) {
            guard !replacement.find.isEmpty, replacement.find != replacement.replace,
                  replacement.find.utf8.count <= maxFragmentBytes,
                  replacement.replace.utf8.count <= maxFragmentBytes
            else { continue }
            let found = edits(for: replacement, in: current)
            // A find consumed by an earlier replacement is skipped silently.
            guard !found.isEmpty else { continue }
            // Checked before anything is copied. Skipped rather than stopping: a later,
            // smaller replacement may still fit.
            let projectedSize = currentSize + found.reduce(0) { $0 + $1.delta }
            guard projectedSize <= maxSize else { continue }
            applied += found.count
            marks = merged(mapped(marks, through: found) + insertedMarks(of: found))
            current = rewritten(current, with: found, inserting: replacement.replace, size: projectedSize)
            currentSize = projectedSize
        }
        return ReplacementOutcome(
            text: current,
            changedRanges: indexRanges(marks, in: current),
            appliedCount: applied
        )
    }

    /// Matches are taken once on the current text, so a `replace` that contains its own
    /// `find` ("a" -> "aa") cannot loop.
    private static func edits(for replacement: TextReplacement, in text: String) -> [Edit] {
        let matches: [Range<String.Index>]
        if replacement.all {
            matches = text.ranges(of: replacement.find)
        } else if let first = text.firstRange(of: replacement.find) {
            matches = [first]
        } else {
            matches = []
        }
        let newLength = replacement.replace.utf8.count
        let utf8 = text.utf8
        return matches.map {
            Edit(
                lo: utf8.distance(from: utf8.startIndex, to: $0.lowerBound),
                hi: utf8.distance(from: utf8.startIndex, to: $0.upperBound),
                newLength: newLength
            )
        }
    }

    /// Rebuilds the text in one pass over its bytes. Matches sit on Character boundaries,
    /// so every copied piece is valid UTF-8 on its own. `size` is the checked result size.
    private static func rewritten(_ text: String, with edits: [Edit], inserting replacement: String, size: Int) -> String {
        let source = Array(text.utf8)
        let inserted = Array(replacement.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(size)
        var cursor = 0
        for edit in edits {
            output.append(contentsOf: source[cursor..<edit.lo])
            output.append(contentsOf: inserted)
            cursor = edit.hi
        }
        output.append(contentsOf: source[cursor...])
        return String(decoding: output, as: UTF8.self)
    }

    /// Moves existing marks through one replacement's edits. Same result as applying the
    /// edits last to first and mapping every mark through each one (an edit over `[lo, hi)`
    /// keeps a mark that ends before it, shifts one that starts after it, and clips or
    /// stretches one it overlaps), but in one sweep: marks and edits are both ascending.
    private static func mapped(_ marks: [Range<Int>], through edits: [Edit]) -> [Range<Int>] {
        // shifts[i] is the total length change made by edits[..<i].
        var shifts = [0]
        shifts.reserveCapacity(edits.count + 1)
        for edit in edits { shifts.append(shifts[shifts.count - 1] + edit.delta) }

        var result: [Range<Int>] = []
        var first = 0 // first edit that ends after the mark starts
        var end = 0 // first edit that starts at or after the mark ends
        for mark in marks {
            while first < edits.count, edits[first].hi <= mark.lowerBound { first += 1 }
            end = max(end, first)
            while end < edits.count, edits[end].lo < mark.upperBound { end += 1 }
            guard first < end else {
                result.append(mark.lowerBound + shifts[first]..<mark.upperBound + shifts[first])
                continue
            }
            let last = edits[end - 1]
            // A mark that ends inside the last overlapping edit ends with that edit's new text.
            let upper = (mark.upperBound >= last.hi ? mark.upperBound + last.delta : last.lo + last.newLength)
                + shifts[end - 1]
            result.append(min(mark.lowerBound, edits[first].lo) + shifts[first]..<upper)
        }
        return result
    }

    /// Where each edit's new text sits once all edits of the replacement are in.
    private static func insertedMarks(of edits: [Edit]) -> [Range<Int>] {
        var marks: [Range<Int>] = []
        var shift = 0
        for edit in edits {
            if edit.newLength > 0 {
                marks.append(edit.lo + shift..<edit.lo + shift + edit.newLength)
            }
            shift += edit.delta
        }
        return marks
    }

    private static func merged(_ marks: [Range<Int>]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for mark in marks.filter({ !$0.isEmpty }).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, mark.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, mark.upperBound)
            } else {
                result.append(mark)
            }
        }
        return result
    }

    private static func indexRanges(_ marks: [Range<Int>], in text: String) -> [Range<String.Index>] {
        let utf8 = text.utf8
        return marks.map {
            utf8.index(utf8.startIndex, offsetBy: $0.lowerBound)..<utf8.index(utf8.startIndex, offsetBy: $0.upperBound)
        }
    }
}
