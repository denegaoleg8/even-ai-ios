import Foundation

/// Local bookkeeping for cloud sync and backup — persisted alongside the
/// local cache, never uploaded verbatim (the server keeps its own view).
/// Every error field is an **error type / short code only**, never a message
/// that could contain memory content.
struct PersonalSyncState: Codable, Hashable, Sendable {
    /// Opaque server watermark from the last successful pull. `nil` == never
    /// synced; the next pull is a full pull.
    var cursor: String?

    var lastSyncStartedAt: Date?
    var lastSyncSucceededAt: Date?
    /// Short code (`"offline"`, `"unauthorized"`, `"decode"`, `"server500"`)
    /// — never a raw message.
    var lastSyncErrorCode: String?

    /// How many local records are waiting to be pushed. Derived, cached here
    /// for a cheap UI read.
    var pendingMutationCount: Int

    /// The user's choice. When `false` the sync engine does nothing and all
    /// local data is retained untouched.
    var cloudSyncEnabled: Bool

    // Backup tracking (§15)
    var lastBackupStartedAt: Date?
    var lastBackupSucceededAt: Date?
    var lastBackupVersion: Int
    var lastBackupChecksum: String?
    var lastBackupErrorCode: String?
    var lastBackupRecordCounts: [String: Int]

    /// Set when a device has authenticated but its local cache is empty and
    /// a cloud restore has not yet completed — drives the automatic
    /// "restore from cloud on first open" path.
    var needsCloudRestore: Bool

    // The style profile is a per-user singleton with no revision field of
    // its own; its sync bookkeeping lives here.
    var styleRevision: Int
    var styleRemoteID: String?
    var lastSyncedStyleUpdatedAt: Date?

    /// The last **server** revision seen for each record, keyed
    /// `"<kind>:<uuid>"`. The push `baseRevision` comes from here — never
    /// from a record's own `revision` (a local edit counter), so local
    /// edits can't accidentally collide with a server revision and clobber
    /// a concurrent change.
    var syncedRevisions: [String: Int]

    init(
        cursor: String? = nil,
        lastSyncStartedAt: Date? = nil,
        lastSyncSucceededAt: Date? = nil,
        lastSyncErrorCode: String? = nil,
        pendingMutationCount: Int = 0,
        cloudSyncEnabled: Bool = false,
        lastBackupStartedAt: Date? = nil,
        lastBackupSucceededAt: Date? = nil,
        lastBackupVersion: Int = 0,
        lastBackupChecksum: String? = nil,
        lastBackupErrorCode: String? = nil,
        lastBackupRecordCounts: [String: Int] = [:],
        needsCloudRestore: Bool = false,
        styleRevision: Int = 0,
        styleRemoteID: String? = nil,
        lastSyncedStyleUpdatedAt: Date? = nil,
        syncedRevisions: [String: Int] = [:]
    ) {
        self.cursor = cursor
        self.lastSyncStartedAt = lastSyncStartedAt
        self.lastSyncSucceededAt = lastSyncSucceededAt
        self.lastSyncErrorCode = lastSyncErrorCode
        self.pendingMutationCount = pendingMutationCount
        self.cloudSyncEnabled = cloudSyncEnabled
        self.lastBackupStartedAt = lastBackupStartedAt
        self.lastBackupSucceededAt = lastBackupSucceededAt
        self.lastBackupVersion = lastBackupVersion
        self.lastBackupChecksum = lastBackupChecksum
        self.lastBackupErrorCode = lastBackupErrorCode
        self.lastBackupRecordCounts = lastBackupRecordCounts
        self.needsCloudRestore = needsCloudRestore
        self.styleRevision = styleRevision
        self.styleRemoteID = styleRemoteID
        self.lastSyncedStyleUpdatedAt = lastSyncedStyleUpdatedAt
        self.syncedRevisions = syncedRevisions
    }

    static let empty = PersonalSyncState()

    // Back-compat: a Phase 1 `PersonalMemoryDocument` has no sync-state key.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cursor = try c.decodeIfPresent(String.self, forKey: .cursor)
        lastSyncStartedAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncStartedAt)
        lastSyncSucceededAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncSucceededAt)
        lastSyncErrorCode = try c.decodeIfPresent(String.self, forKey: .lastSyncErrorCode)
        pendingMutationCount = try c.decodeIfPresent(Int.self, forKey: .pendingMutationCount) ?? 0
        cloudSyncEnabled = try c.decodeIfPresent(Bool.self, forKey: .cloudSyncEnabled) ?? false
        lastBackupStartedAt = try c.decodeIfPresent(Date.self, forKey: .lastBackupStartedAt)
        lastBackupSucceededAt = try c.decodeIfPresent(Date.self, forKey: .lastBackupSucceededAt)
        lastBackupVersion = try c.decodeIfPresent(Int.self, forKey: .lastBackupVersion) ?? 0
        lastBackupChecksum = try c.decodeIfPresent(String.self, forKey: .lastBackupChecksum)
        lastBackupErrorCode = try c.decodeIfPresent(String.self, forKey: .lastBackupErrorCode)
        lastBackupRecordCounts = try c.decodeIfPresent([String: Int].self, forKey: .lastBackupRecordCounts) ?? [:]
        needsCloudRestore = try c.decodeIfPresent(Bool.self, forKey: .needsCloudRestore) ?? false
        styleRevision = try c.decodeIfPresent(Int.self, forKey: .styleRevision) ?? 0
        styleRemoteID = try c.decodeIfPresent(String.self, forKey: .styleRemoteID)
        lastSyncedStyleUpdatedAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncedStyleUpdatedAt)
        syncedRevisions = try c.decodeIfPresent([String: Int].self, forKey: .syncedRevisions) ?? [:]
    }

    static func revisionKey(_ kind: PersonalRecordKind, _ id: UUID) -> String {
        "\(kind.rawValue):\(id.uuidString)"
    }
}
