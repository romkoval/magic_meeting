import Foundation
import SwiftData

/// A surname or term that helps Whisper and the LLM spell things right.
@Model
final class GlossaryTerm {
    @Attribute(.unique) var term: String
    /// Terms go to the proxy newest first: it cuts the Whisper prompt from the end.
    /// The default value lets SwiftData migrate stores made before this field.
    var createdAt: Date = Date.now

    init(term: String, createdAt: Date = .now) {
        self.term = term
        self.createdAt = createdAt
    }
}
