import Foundation

/// Where a memory or rule applies. `global` is the common case (one Personal
/// AI identity shared by every surface); the narrower scopes exist so a user
/// can say "only when talking to me directly" (`personalChat`) or "only for
/// G2 suggested replies" (`g2Replies`) without that leaking everywhere.
///
/// `project(id:)` carries a `MemoryRecord.id` string of a `projects` memory —
/// not a free-form name — so a project rename never orphans its scoped rules.
enum MemoryScope: Codable, Hashable, Sendable {
    case global
    case personalChat
    case g2Replies
    case project(id: String)

    /// Whether a memory/rule with this scope is eligible for a request on
    /// `surface`. `global` always is; `project` scopes are eligible on any
    /// surface (the project hint, not the surface, gates them in retrieval).
    func appliesTo(surface: PersonalAISurface) -> Bool {
        switch self {
        case .global, .project:
            return true
        case .personalChat:
            return surface == .personalChat
        case .g2Replies:
            return surface == .g2Replies
        }
    }

    var displayName: String {
        switch self {
        case .global: return "Everywhere"
        case .personalChat: return "Personal AI Chat"
        case .g2Replies: return "G2 Replies"
        case .project(let id): return "Project \(id.prefix(8))"
        }
    }
}
