import CloudKit

/// Opaque per-zone change position. Live: an archived `CKServerChangeToken`.
/// Test double: arbitrary bytes. Never interpreted above the facade.
struct CloudKitZoneToken: Codable, Hashable, Sendable {
    var raw: Data
    init(raw: Data) { self.raw = raw }
}

/// One record changed on the server, with its server-assigned version.
struct CloudKitRemoteChange: Sendable {
    var record: CKRecord
    var changeTag: String
}

/// One record deleted on the server.
struct CloudKitRemoteDeletion: Sendable {
    var recordName: String
    var recordType: String
}

/// The outcome of fetching one zone's changes for one page.
struct CloudKitZoneChanges: Sendable {
    var changed: [CloudKitRemoteChange] = []
    var deleted: [CloudKitRemoteDeletion] = []
    var newToken: CloudKitZoneToken?
    var moreComing: Bool = false
    /// The supplied token was rejected — caller should re-fetch from `nil`.
    var tokenExpired: Bool = false
    /// The zone does not exist yet — treat as empty; it is created on push.
    var zoneNotFound: Bool = false
}

/// One record to save. `expectedChangeTag == nil` ⇒ create; otherwise
/// update-only-if the server still holds that version.
struct CloudKitSaveRequest: Sendable {
    var record: CKRecord
    var expectedChangeTag: String?
    /// Archived `CKRecord` system fields for the live path's
    /// `.ifServerRecordUnchanged` save policy (nil for a create, or when the
    /// local side-table has been lost — the live path then fetches first).
    var systemFieldsArchive: Data?
}

/// Per-record outcome of a modify batch.
enum CloudKitSaveResult: Sendable {
    case saved(recordName: String, changeTag: String, systemFieldsArchive: Data?)
    case conflict(recordName: String, serverRecord: CKRecord, serverChangeTag: String)
    /// A retryable per-record failure — the caller leaves the record pending.
    case transient(recordName: String, code: String)
    /// The record or its zone is gone — the caller drops local sync state for
    /// it so the next push re-creates it.
    case unknownItem(recordName: String)
}

/// The narrow surface the CloudKit adapter needs from a **private** database.
///
/// A live implementation wraps `CKContainer(identifier:).privateCloudDatabase`
/// (`LiveCloudKitDatabaseFacade`). The deterministic test double is fully
/// in-memory and **never touches a real `CKContainer`**.
protocol CloudKitDatabaseFacade: Sendable {
    func accountStatus() async -> CKAccountStatus
    /// The signed-in iCloud user's record name — infrastructure identity only,
    /// used for the `PersonalAIUserID ↔ iCloud account` binding.
    func currentUserRecordName() async throws -> String

    func ensureZones(_ zoneIDs: [CKRecordZone.ID]) async throws
    func deleteZones(_ zoneIDs: [CKRecordZone.ID]) async throws

    func modify(_ saves: [CloudKitSaveRequest], deleting: [CKRecord.ID]) async throws -> [CloudKitSaveResult]

    func fetchChanges(zoneID: CKRecordZone.ID, since token: CloudKitZoneToken?, resultLimit: Int) async throws -> CloudKitZoneChanges
}
