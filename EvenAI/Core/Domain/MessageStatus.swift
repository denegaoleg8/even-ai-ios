import Foundation

enum MessageStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case complete
    case streaming
    case failed
}
