import Foundation

/// A persistent behavioural instruction from the user — "keep business
/// replies short", "use Ukrainian when speaking directly to me", "never open
/// with 'thanks for sharing'". First-class Personal AI memory: stored in the
/// same `PersonalMemoryDocument` as `MemoryRecord`, carrying the same
/// identity/sync/provenance fields, so this is *one* memory architecture with
/// two record shapes — not a separate rules system.
///
/// A `Rule` is distinct from a `MemoryRecord(category: .rules)` only in that
/// it is imperative and always evaluated (not retrieval-gated): every enabled,
/// in-scope, unexpired rule is injected into every request for that surface.
/// Retrieval decides which *facts* are relevant; rules are always on.
struct Rule: Identifiable, Codable, Hashable, Sendable {
    // MARK: Identity & sync (mirrors MemoryRecord)
    let id: UUID
    var remoteID: String?
    var revision: Int
    var syncState: MemorySyncState
    var deletedAt: Date?
    var ownerID: String?

    // MARK: Content
    /// The instruction, normalised to an imperative sentence
    /// ("Keep business replies short.").
    var text: String
    var createdAt: Date
    var updatedAt: Date
    var enabled: Bool
    /// Almost always `.activeRule`. `.explicitCurrentInstruction` is used
    /// transiently by the context builder for a command detected in the
    /// *current* message; such rules are not persisted with that priority.
    var priority: PersonalAIPriority
    var scope: MemoryScope
    var source: MemorySource
    /// Optional expiry ("for the next week, keep answers very brief").
    var expiresAt: Date?

    // MARK: Provenance
    var sourceConversationIDs: [UUID]
    var sourceMessageIDs: [UUID]

    init(
        id: UUID = UUID(),
        remoteID: String? = nil,
        revision: Int = 0,
        syncState: MemorySyncState = .localOnly,
        deletedAt: Date? = nil,
        ownerID: String? = nil,
        text: String,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        enabled: Bool = true,
        priority: PersonalAIPriority = .activeRule,
        scope: MemoryScope = .global,
        source: MemorySource = .explicitCommand,
        expiresAt: Date? = nil,
        sourceConversationIDs: [UUID] = [],
        sourceMessageIDs: [UUID] = []
    ) {
        self.id = id
        self.remoteID = remoteID
        self.revision = revision
        self.syncState = syncState
        self.deletedAt = deletedAt
        self.ownerID = ownerID
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.enabled = enabled
        self.priority = priority
        self.scope = scope
        self.source = source
        self.expiresAt = expiresAt
        self.sourceConversationIDs = sourceConversationIDs
        self.sourceMessageIDs = sourceMessageIDs
    }
}

extension Rule: PersonalCloudSyncable {
    static var recordKind: PersonalRecordKind { .rule }
}

extension Rule {
    func isActive(now: Date = .now, surface: PersonalAISurface) -> Bool {
        guard enabled, deletedAt == nil, scope.appliesTo(surface: surface) else { return false }
        if let expiresAt, expiresAt <= now { return false }
        return true
    }

    func isExpired(now: Date = .now) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }

    func touched(now: Date = .now) -> Rule {
        var copy = self
        copy.updatedAt = now
        copy.revision += 1
        if copy.syncState == .synced { copy.syncState = .pendingPush }
        return copy
    }

    var approximateTokenCount: Int {
        max(1, text.count / 4)
    }
}
