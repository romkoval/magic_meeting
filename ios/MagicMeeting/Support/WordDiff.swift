import Foundation

/// Word-level diff used to highlight what a full-text edit (summary, minutes) changed.
enum WordDiff {
    /// Above this many tokens on either side no ranges are returned (keeps the main actor responsive).
    static let maxTokens = 3_000

    /// Ranges in `new` covering words inserted or changed relative to `old`.
    static func changedRanges(from old: String, to new: String) -> [Range<String.Index>] {
        let oldTokens = tokens(in: old)
        let newTokens = tokens(in: new)
        guard oldTokens.count <= maxTokens, newTokens.count <= maxTokens else { return [] }

        let oldWords = oldTokens.map { String(old[$0]) }
        let newWords = newTokens.map { String(new[$0]) }
        var changed = [Bool](repeating: false, count: newWords.count)
        // Removals are ignored: there is nothing left in `new` to mark for them.
        for change in newWords.difference(from: oldWords) {
            if case .insert(let offset, _, _) = change { changed[offset] = true }
        }
        return groups(of: changed, in: newTokens)
    }

    /// A token is a maximal run of non-whitespace characters, so whitespace-only edits
    /// change no token.
    private static func tokens(in text: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            if text[index].isWhitespace {
                if let tokenStart = start {
                    result.append(tokenStart..<index)
                    start = nil
                }
            } else if start == nil {
                start = index
            }
            index = text.index(after: index)
        }
        if let tokenStart = start { result.append(tokenStart..<text.endIndex) }
        return result
    }

    /// Consecutive changed tokens become one range, spaces between them included.
    private static func groups(of changed: [Bool], in tokens: [Range<String.Index>]) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var runStart: Int?
        for (index, isChanged) in changed.enumerated() {
            if isChanged {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                result.append(tokens[start].lowerBound..<tokens[index - 1].upperBound)
                runStart = nil
            }
        }
        if let start = runStart { result.append(tokens[start].lowerBound..<tokens[changed.count - 1].upperBound) }
        return result
    }
}
