import Foundation

/// The syncable record types in the one Personal AI data model. Projects,
/// people and episodes are `MemoryRecord`s distinguished by
/// `MemoryCategory`, so they are all `.memory` here — there is no separate
/// storage or sync path for them. The style profile is a per-user singleton.
enum PersonalRecordKind: String, Codable, CaseIterable, Hashable, Sendable {
    case memory
    case rule
    case conversation
    case message
    case styleProfile

    var displayName: String {
        switch self {
        case .memory: return "Memory"
        case .rule: return "Rule"
        case .conversation: return "Conversation"
        case .message: return "Message"
        case .styleProfile: return "Style Profile"
        }
    }
}
