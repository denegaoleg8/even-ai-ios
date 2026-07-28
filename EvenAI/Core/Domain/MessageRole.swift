import Foundation

enum MessageRole: String, Codable, CaseIterable, Hashable, Sendable {
    case user
    case assistant
    case system
}
