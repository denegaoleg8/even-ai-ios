import Foundation

/// A single record on the wire, kind-tagged, with its payload serialized to
/// JSON so `PersonalAISyncEngine` and the backend can move every record kind
/// through one code path. `baseRevision` is the revision the client last saw
/// for this id — the server uses it to detect a concurrent change.
struct SyncRecordEnvelope: Codable, Hashable, Sendable {
    var kind: PersonalRecordKind
    var id: UUID
    var remoteID: String?
    var baseRevision: Int
    /// The record's full serialized state. Empty string only for a pure
    /// tombstone with no prior push.
    var payloadJSON: String
    var deletedAt: Date?
    /// Server-assigned revision (set on `SyncPullResult` / accepted
    /// `SyncPushResult` envelopes; ignored on outbound push requests).
    var serverRevision: Int?

    init(kind: PersonalRecordKind, id: UUID, remoteID: String? = nil, baseRevision: Int, payloadJSON: String, deletedAt: Date? = nil, serverRevision: Int? = nil) {
        self.kind = kind
        self.id = id
        self.remoteID = remoteID
        self.baseRevision = baseRevision
        self.payloadJSON = payloadJSON
        self.deletedAt = deletedAt
        self.serverRevision = serverRevision
    }
}

/// A batch of local changes to push. `idempotencyKey` is derived
/// deterministically from the batch contents, so a retried push (after a
/// timeout with an unknown outcome) is recognised by the server and never
/// double-applies.
struct SyncPushRequest: Codable, Hashable, Sendable {
    var ownerID: String
    var records: [SyncRecordEnvelope]
    var idempotencyKey: String
}

struct SyncPullResult: Codable, Hashable, Sendable {
    /// New watermark to persist and pass to the next pull.
    var cursor: String
    var records: [SyncRecordEnvelope]
    /// The server capped the page; call `pull` again with the new cursor.
    var hasMore: Bool
}

struct SyncPushResult: Codable, Hashable, Sendable {
    var cursor: String
    /// Server-authoritative versions of accepted records (with `remoteID`
    /// and `serverRevision` filled in).
    var accepted: [SyncRecordEnvelope]
    /// Records the server refused because they were based on a stale
    /// revision — the client must resolve each per `ConflictPolicy`.
    var conflicts: [SyncConflict]
}

struct SyncConflict: Codable, Hashable, Sendable {
    var id: UUID
    var kind: PersonalRecordKind
    var clientPayloadJSON: String
    var serverPayloadJSON: String
    var serverRevision: Int
    var serverRemoteID: String?
    var serverDeletedAt: Date?
}

/// What one `PersonalAISyncEngine.sync()` call did. A failure never means
/// data was lost — `.failedRetryable` keeps every pending change queued.
enum SyncOutcome: Equatable, Sendable {
    case completed(pushed: Int, pulled: Int, conflictsResolved: Int)
    case skipped(reason: SkipReason)
    case failedRetryable(code: String)
    case failedFatal(code: String)

    enum SkipReason: String, Equatable, Sendable {
        case syncDisabled
        case notAuthenticated
        case noCloudService
        case alreadyRunning
        case cancelled
    }

    var isSuccess: Bool { if case .completed = self { return true } else { return false } }
}
