import Foundation

/// The common contract every syncable Personal AI record satisfies. Phase 1
/// already gave `MemoryRecord` and `Rule` every one of these fields; Phase 2
/// only adds the explicit conformance (and the same fields to
/// `PersonalAIChatMessage` / the new `PersonalAIConversation`).
///
/// This is what lets `PersonalAISyncEngine` treat every record kind through
/// one code path — pull, merge, push, tombstone — without a per-kind branch
/// except where `ConflictPolicy` deliberately differs.
protocol PersonalCloudSyncable: Identifiable, Codable, Sendable where ID == UUID {
    /// Stable client id, generated on device, never changes — the primary
    /// key the server upserts against.
    var id: UUID { get }
    /// Server-assigned id once the record has been pushed. `nil` until then.
    var remoteID: String? { get set }
    /// Monotonic per-record edit counter. The basis for conflict detection.
    var revision: Int { get set }
    var syncState: MemorySyncState { get set }
    /// Tombstone marker. Non-nil ⇒ the record is deleted; sync propagates
    /// this and it must never be resurrected by a stale copy.
    var deletedAt: Date? { get set }
    /// Owning user. `nil` == the local-only user; set once authenticated.
    var ownerID: String? { get set }
    var updatedAt: Date { get set }

    static var recordKind: PersonalRecordKind { get }
}

extension PersonalCloudSyncable {
    var isTombstoned: Bool { deletedAt != nil }

    /// Whether this record has local changes the sync engine still needs to
    /// push.
    var hasPendingPush: Bool {
        switch syncState {
        case .localOnly, .pendingPush, .conflict: return true
        case .synced, .pendingPull: return false
        }
    }
}
