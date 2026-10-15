import SwiftUI

/// Text with the fragments changed by the last voice edit marked.
/// Built only from `ChangeHighlight.text`, so the ranges index into the string they came from.
struct HighlightedText: View {
    let text: String
    let ranges: [Range<String.Index>]

    var body: some View { Text(Self.attributed(text, ranges: ranges)) }

    /// Ranges that do not map into `text` are skipped.
    nonisolated static func attributed(_ text: String, ranges: [Range<String.Index>]) -> AttributedString {
        // Named explicitly: UIKit's scope also has a `backgroundColor` attribute.
        typealias Background = AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute
        var result = AttributedString(text)
        for range in ranges {
            guard range.lowerBound >= text.startIndex,
                  range.upperBound <= text.endIndex,
                  range.lowerBound.samePosition(in: text.unicodeScalars) != nil,
                  range.upperBound.samePosition(in: text.unicodeScalars) != nil,
                  let mapped = Range<AttributedString.Index>(range, in: result)
            else { continue }
            result[mapped][Background.self] = Color.yellow.opacity(0.35)
        }
        return result
    }
}
