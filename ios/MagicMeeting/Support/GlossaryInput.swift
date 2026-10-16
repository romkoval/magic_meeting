import Foundation

/// Turns typed or pasted text into glossary terms and estimates how many of them reach Whisper.
enum GlossaryInput {
    /// Names and terms are short; anything longer is a pasted sentence.
    static let maxTermLength = 60
    /// Mirrors proxy `whisperPromptMaxRunes`.
    static let whisperBudget = 700

    /// Splits on new lines, commas and semicolons so a list can be pasted in one go.
    /// Returns new terms in the order they appear, without case-insensitive repeats
    /// of each other or of `existing`.
    static func parse(_ input: String, existing: [String]) -> [String] {
        var seen = Set(existing.map { $0.lowercased() })
        var terms: [String] = []
        for piece in input.split(whereSeparator: { $0.isNewline || $0 == "," || $0 == ";" }) {
            let term = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, term.count <= maxTermLength else { continue }
            if seen.insert(term.lowercased()).inserted {
                terms.append(term)
            }
        }
        return terms
    }

    /// Mirrors proxy `whisperPrompt`: terms count in runes plus two for ", ", and the
    /// first term that does not fit ends the prompt, even if shorter ones follow.
    static func whisperUsage(_ termsInSendOrder: [String]) -> (used: Int, included: Int) {
        var used = 0
        var included = 0
        for raw in termsInSendOrder {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { continue }
            let cost = term.unicodeScalars.count + 2
            if used + cost > whisperBudget { break }
            used += cost
            included += 1
        }
        return (used, included)
    }
}
