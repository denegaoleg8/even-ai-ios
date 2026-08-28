import Foundation

/// The complete serialisable state of a user's Personal AI memory: records,
/// rules, style profile, the exclusion/disable switches, and (Phase 2) the
/// version-history log and local sync state. One value type that is
/// simultaneously:
///
/// - the on-disk format for `LocalPersonalMemoryStore`,
/// - the `memory` slice of a `PersonalDataBundle` (export / backup / snapshot),
/// - the per-record sync payload `PersonalAISyncEngine` reconciles.
///
/// `schemaVersion` is checked on load; an unknown newer version is surfaced
/// rather than silently truncated. Tombstoned records are retained so sync /
/// undo has the history. Phase 2 fields (`revisions`, `syncState`) decode
/// with `decodeIfPresent`, so a Phase 1 document still loads unchanged.
struct PersonalMemoryDocument: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var records: [MemoryRecord]
    var rules: [Rule]
    var styleProfile: PersonalAIStyleProfile
    var doNotRememberConversationIDs: Set<UUID>
    var memoryEnabledGlobally: Bool
    /// When this document was last mutated locally.
    var updatedAt: Date

    // MARK: Phase 2 (back-compat: absent in Phase 1 documents)
    /// Append-only version history for every syncable record.
    var revisions: [RecordRevision]
    /// Local cloud-sync / backup bookkeeping.
    var syncState: PersonalSyncState

    init(
        schemaVersion: Int = PersonalMemoryDocument.currentSchemaVersion,
        records: [MemoryRecord] = [],
        rules: [Rule] = [],
        styleProfile: PersonalAIStyleProfile = .empty,
        doNotRememberConversationIDs: Set<UUID> = [],
        memoryEnabledGlobally: Bool = true,
        updatedAt: Date = .now,
        revisions: [RecordRevision] = [],
        syncState: PersonalSyncState = .empty
    ) {
        self.schemaVersion = schemaVersion
        self.records = records
        self.rules = rules
        self.styleProfile = styleProfile
        self.doNotRememberConversationIDs = doNotRememberConversationIDs
        self.memoryEnabledGlobally = memoryEnabledGlobally
        self.updatedAt = updatedAt
        self.revisions = revisions
        self.syncState = syncState
    }

    static let empty = PersonalMemoryDocument()

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, records, rules, styleProfile
        case doNotRememberConversationIDs, memoryEnabledGlobally, updatedAt
        case revisions, syncState
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        records = try c.decode([MemoryRecord].self, forKey: .records)
        rules = try c.decode([Rule].self, forKey: .rules)
        styleProfile = try c.decode(PersonalAIStyleProfile.self, forKey: .styleProfile)
        doNotRememberConversationIDs = try c.decode(Set<UUID>.self, forKey: .doNotRememberConversationIDs)
        memoryEnabledGlobally = try c.decode(Bool.self, forKey: .memoryEnabledGlobally)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        revisions = try c.decodeIfPresent([RecordRevision].self, forKey: .revisions) ?? []
        syncState = try c.decodeIfPresent(PersonalSyncState.self, forKey: .syncState) ?? .empty
    }
}
