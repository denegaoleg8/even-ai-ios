import Foundation

/// The one shared taxonomy for everything the Personal AI remembers — used
/// identically by Personal AI Chat and (later) G2 personalization. There is
/// exactly one memory model in this app; this enum is its spine.
///
/// Ordering here is deliberately the "identity → behaviour → knowledge →
/// history" progression the Memory Center presents them in, not alphabetical.
enum MemoryCategory: String, Codable, CaseIterable, Hashable, Sendable {
    /// Persistent instructions from the user ("keep business replies short").
    /// Modelled as first-class `Rule` records, but the category exists so a
    /// rule is still a memory in the unified store.
    case rules

    /// Stable user-provided facts about themselves ("my name is …", "I'm
    /// based in Kyiv").
    case profile

    /// Communication / response-style preferences ("be direct", "use
    /// Ukrainian when talking to me").
    case style

    /// Likes / dislikes / behavioural preferences ("I prefer Swift over
    /// Kotlin", "don't suggest meetings before 10am").
    case preferences

    /// Long-running projects, goals, decisions and project context
    /// ("building EvenAI for G2 glasses", "launch moved to October").
    case projects

    /// Useful context about repeatedly referenced people / entities
    /// ("Andrii is my co-founder", "the reviewer prefers small PRs").
    case people

    /// Information the user explicitly asked to be remembered that isn't
    /// about them, a project, or a person ("the office wifi password rotates
    /// monthly" — note: the *value* of a secret is never stored, see
    /// `SecretDetector`).
    case knowledge

    /// Important past conversations / events, summarised ("we debugged the
    /// STT reconnect bug together on 2026-08-20").
    case episodes

    /// Temporary information with an expiry ("I'm in Berlin this week").
    /// Never silently promoted to `profile`.
    case workingContext

    /// Searchable historical conversation turns / messages — the raw
    /// archive retrieval can pull excerpts from.
    case conversationArchive

    var displayName: String {
        switch self {
        case .rules: return "Rules"
        case .profile: return "Profile"
        case .style: return "Style"
        case .preferences: return "Preferences"
        case .projects: return "Projects"
        case .people: return "People"
        case .knowledge: return "Knowledge"
        case .episodes: return "Episodes"
        case .workingContext: return "Working Context"
        case .conversationArchive: return "Conversation Archive"
        }
    }

    /// Categories a user directly curates in the Memory Center list. The
    /// archive is browsable but not hand-authored, so it's excluded from the
    /// default filter set.
    static var userFacing: [MemoryCategory] {
        [.rules, .profile, .style, .preferences, .projects, .people, .knowledge, .episodes, .workingContext]
    }
}
