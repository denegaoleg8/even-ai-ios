import Foundation

/// Lifecycle state of a memory record. Deliberately soft — a record is never
/// hard-deleted from the document in Phase 1 (a tombstone is kept), because
/// the Phase 2 cloud sync needs the history to reconcile revisions and offer
/// "restore a corrected memory".
enum MemoryStatus: String, Codable, Hashable, Sendable {
    /// Live and eligible for retrieval (subject to `enabled` / expiry).
    case active
    /// Replaced by a newer, contradictory record — see `supersededByID`.
    /// Retained for provenance / undo, never retrieved.
    case superseded
    /// Aged out (expired working context, or user-archived). Not retrieved.
    case archived
    /// User-deleted. Tombstone only; `deletedAt` is set.
    case deleted
}

/// How a memory or rule came to exist. Drives trust: an `explicitCommand`
/// starts at high confidence and `userConfirmed = true`; an
/// `inferredFromConversation` starts lower and unconfirmed, and the user can
/// confirm it in the Memory Center.
enum MemorySource: String, Codable, Hashable, Sendable {
    case explicitCommand
    case inferredFromConversation
    case manualEntry
    case imported
}

/// Sync bookkeeping carried by every record from day one so the Phase 2
/// sync engine is a drop-in, not a schema migration. In Phase 1 every record
/// is `localOnly`.
enum MemorySyncState: String, Codable, Hashable, Sendable {
    case localOnly
    case synced
    case pendingPush
    case pendingPull
    case conflict
}

/// Precedence ladder from the product brief §3, highest first. Lower
/// `rawValue` == higher precedence, so a plain sort ascending puts the most
/// authoritative first.
enum PersonalAIPriority: Int, Codable, CaseIterable, Hashable, Sendable, Comparable {
    case explicitCurrentInstruction = 0
    case activeRule = 1
    case retrievedMemory = 2
    case learnedStyle = 3
    case defaultBehavior = 4

    static func < (lhs: PersonalAIPriority, rhs: PersonalAIPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var displayName: String {
        switch self {
        case .explicitCurrentInstruction: return "Current instruction"
        case .activeRule: return "Active rule"
        case .retrievedMemory: return "Retrieved memory"
        case .learnedStyle: return "Learned style"
        case .defaultBehavior: return "Default behavior"
        }
    }
}
