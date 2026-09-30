import Foundation
import SwiftData

@Model
final class Highlight {
    @Attribute(.unique) var id: UUID
    /// Character offsets in the full transcript.
    var rangeStart: Int
    var rangeEnd: Int
    /// Guards against offsets drifting after transcript edits.
    var quote: String
    var createdAt: Date
    var recording: Recording?

    init(id: UUID = UUID(), rangeStart: Int, rangeEnd: Int, quote: String, createdAt: Date = .now) {
        self.id = id
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.quote = quote
        self.createdAt = createdAt
    }
}
