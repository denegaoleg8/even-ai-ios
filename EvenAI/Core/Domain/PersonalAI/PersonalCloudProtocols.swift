import Foundation

// MARK: - Cloud service

/// The authenticated network face of the Personal AI Cloud — **the one seam
/// iOS talks to**. It knows nothing about whether the backend is CloudKit,
/// Supabase, a self-hosted Postgres API, or a test double. Supersedes the
/// Phase 1 `CloudMemoryStore` placeholder (which is left in place but
/// unused).
///
/// Every method is `ownerID`-scoped and the implementation MUST enforce that
/// server-side — a caller can never reach another user's data.
protocol PersonalCloudService: Sendable {
    /// Records changed on the server since `cursor` (nil == full pull).
    func pull(ownerID: String, since cursor: String?) async throws -> SyncPullResult
    /// Push local pending changes. Returns server-authoritative versions and
    /// any conflicts. Idempotent on `request.idempotencyKey`.
    func push(_ request: SyncPushRequest) async throws -> SyncPushResult
    /// A full point-in-time snapshot for new-device / disaster recovery.
    func snapshot(ownerID: String) async throws -> PersonalDataBundle
    /// Permanently delete every server-side record for this user (§26).
    /// Returns when the primary store is cleared; provider backup retention
    /// is documented separately, not claimed here.
    func deleteAllData(ownerID: String) async throws
}

// MARK: - Backup storage

/// Object storage for independent backups — deliberately a **separate**
/// dependency from `PersonalCloudService` so a bug or outage in one cannot
/// take the other down. Phase 2 ships `LocalDirectoryBackupStore`; a real
/// S3 / R2 / GCS conformer is an additive drop-in.
protocol BackupStore: Sendable {
    func putBackup(_ sealed: Data, handle: BackupHandle, ownerID: String) async throws
    func listBackups(ownerID: String) async throws -> [BackupHandle]
    func getBackup(_ handle: BackupHandle, ownerID: String) async throws -> Data
    func deleteBackup(_ handle: BackupHandle, ownerID: String) async throws
}

struct BackupHandle: Codable, Hashable, Sendable {
    var id: String
    var createdAt: Date
    var bundleVersion: Int
    var sizeBytes: Int
    var checksum: String
    /// `"incremental"` | `"daily"` | `"weekly"` | `"monthly"` — drives
    /// retention pruning.
    var tier: String
}

// MARK: - Embeddings (derived data only)

/// Optional semantic-retrieval support. Vectors are **derived** — if the
/// index or the vendor is lost, canonical memories are untouched and the
/// index can be rebuilt. Phase 2 ships `NoEmbeddingProvider`; retrieval
/// stays lexical (`TextSimilarity`).
protocol EmbeddingProviding: Sendable {
    /// Stable identifier for the model + version, stored as metadata so a
    /// re-embed can detect a model change. `"none"` for the no-op provider.
    var modelIdentifier: String { get }
    func embed(_ texts: [String]) async throws -> [[Float]]
}

// MARK: - Local data facade

/// One facade over everything the sync engine, exporter and backup
/// coordinator need: the memory store, the conversation store, the revision
/// log, and the sync-state record. Keeps those callers from having to know
/// there are two underlying Phase 1 stores.
protocol PersonalDataStore: Sendable {
    /// Full current state as a bundle (for snapshot / export / backup).
    func exportBundle(selection: ExportSelection, bundleVersion: Int) async -> PersonalDataBundle
    /// Apply a bundle. `.replaceAll` wipes and takes the bundle (new
    /// iPhone); `.merge` reconciles into current data.
    func importBundle(_ bundle: PersonalDataBundle, strategy: ImportStrategy) async -> ImportResult

    /// Local records that still need pushing — the offline queue. Excludes
    /// Do-Not-Remember conversations and their messages.
    func pendingChanges() async -> [SyncRecordEnvelope]
    /// Apply server-authoritative records. Returns revisions written for
    /// anything that was replaced. When `asConflictResolution` is true the
    /// incoming versions override even a locally-pending record — that is
    /// the whole point of resolving a conflict.
    func applyRemote(_ envelopes: [SyncRecordEnvelope], asConflictResolution: Bool) async -> [RecordRevision]
    /// Mark the given ids synced with their server `remoteID` / `revision`.
    func markSynced(_ accepted: [SyncRecordEnvelope]) async

    func syncState() async -> PersonalSyncState
    func updateSyncState(_ mutate: @Sendable @escaping (inout PersonalSyncState) -> Void) async
    func revisions(recordID: UUID) async -> [RecordRevision]
    /// Persist a revision produced by conflict resolution.
    func appendResolvedRevision(_ revision: RecordRevision) async
    /// Restore a record to a prior revision (user-facing undo).
    func restoreRevision(_ revisionID: UUID) async -> Bool
}

extension PersonalDataStore {
    func applyRemote(_ envelopes: [SyncRecordEnvelope]) async -> [RecordRevision] {
        await applyRemote(envelopes, asConflictResolution: false)
    }
}
