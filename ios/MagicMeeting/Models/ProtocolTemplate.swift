import Foundation
import SwiftData

/// `Template` in the spec: a Markdown description of the minutes structure.
@Model
final class ProtocolTemplate {
    @Attribute(.unique) var id: UUID
    var name: String
    var body: String
    var isDefault: Bool
    var createdAt: Date

    init(id: UUID = UUID(), name: String, body: String, isDefault: Bool = false, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.body = body
        self.isDefault = isDefault
        self.createdAt = createdAt
    }
}
