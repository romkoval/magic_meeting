import Foundation
import SwiftData

/// A surname or term that helps Whisper and the LLM spell things right.
@Model
final class GlossaryTerm {
    @Attribute(.unique) var term: String

    init(term: String) {
        self.term = term
    }
}
