import Foundation

/// The complete serialisable state of a user's Personal AI memory: records,
/// rules, style profile, and the exclusion/disable switches. One value type
/// that is simultaneously:
///
/// - the on-disk format for `LocalPersonalMemoryStore` (Phase 1),
/// - the export / backup / restore unit (Phase 2 backup design),
/// - the sync payload shape a Phase 2 `CloudMemoryStore` reconciles.
///
/// `schemaVersion` is checked on load; an unknown newer version is surfaced
/// rather than silently truncated. Tombstoned (`status == .deleted`) records
/// are retained in `records` so a Phase 2 sync/undo has the history.
struct PersonalMemoryDocument: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var records: [MemoryRecord]
    var rules: [Rule]
    var styleProfile: PersonalAIStyleProfile
    var doNotRememberConversationIDs: Set<UUID>
    var memoryEnabledGlobally: Bool
    /// When this document was last mutated locally — Phase 2 sync uses it
    /// as a coarse "is the local copy newer" hint before per-record checks.
    var updatedAt: Date

    init(
        schemaVersion: Int = PersonalMemoryDocument.currentSchemaVersion,
        records: [MemoryRecord] = [],
        rules: [Rule] = [],
        styleProfile: PersonalAIStyleProfile = .empty,
        doNotRememberConversationIDs: Set<UUID> = [],
        memoryEnabledGlobally: Bool = true,
        updatedAt: Date = .now
    ) {
        self.schemaVersion = schemaVersion
        self.records = records
        self.rules = rules
        self.styleProfile = styleProfile
        self.doNotRememberConversationIDs = doNotRememberConversationIDs
        self.memoryEnabledGlobally = memoryEnabledGlobally
        self.updatedAt = updatedAt
    }

    static let empty = PersonalMemoryDocument()
}
