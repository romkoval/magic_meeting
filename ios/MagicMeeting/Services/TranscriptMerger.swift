import Foundation

/// Glues transcripts of overlapping audio chunks, dropping the words the overlap repeats.
enum TranscriptMerger {
    static let maxOverlapWords = 40
    static let minOverlapWords = 3
    /// Words at a chunk edge are often cut in half and misrecognized.
    static let edgeSlack = 2

    static func merge(_ head: String, _ tail: String) -> String {
        let headWords = head.split(whereSeparator: \.isWhitespace)
        let tailWords = tail.split(whereSeparator: \.isWhitespace)
        guard !headWords.isEmpty else { return tail.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !tailWords.isEmpty else { return head.trimmingCharacters(in: .whitespacesAndNewlines) }

        let headKeys = headWords.map(normalize)
        let tailKeys = tailWords.map(normalize)
        let maxK = min(maxOverlapWords, headKeys.count, tailKeys.count)

        if maxK >= minOverlapWords {
            for k in stride(from: maxK, through: minOverlapWords, by: -1) {
                for dropHead in 0...edgeSlack {
                    let headEnd = headKeys.count - dropHead
                    guard headEnd - k >= 0 else { continue }
                    let headSlice = headKeys[(headEnd - k)..<headEnd]
                    for skipTail in 0...edgeSlack where skipTail + k <= tailKeys.count {
                        guard headSlice.elementsEqual(tailKeys[skipTail..<(skipTail + k)]) else { continue }
                        // The overlap itself is taken from the tail: there it has
                        // the following context, so its punctuation is more reliable.
                        let kept = headWords[..<(headEnd - k)] + tailWords[skipTail...]
                        return kept.joined(separator: " ")
                    }
                }
            }
        }
        return (headWords + tailWords).joined(separator: " ")
    }

    static func normalize(_ word: Substring) -> String {
        String(word.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}
