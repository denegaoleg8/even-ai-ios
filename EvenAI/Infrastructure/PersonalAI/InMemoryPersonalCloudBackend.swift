import Foundation

/// **TEST / DEVELOPMENT ONLY.** A faithful in-process simulation of the
/// Personal AI Cloud server — the thing Phase 3 will implement for real
/// against CloudKit / Postgres. Its entire state is in-memory: it does not
/// persist across process launches and is never wired into a shipping build
/// (only `PersonalAIContainer.simulated()` uses it). It exists so every
/// sync / conflict / tombstone / isolation behaviour is tested
/// deterministically with **no network, no ports, no paid infra**.
///
/// What it simulates that a naive stub would not:
/// - **Per-user isolation** — every record is filed under an `ownerID`; a
///   call for owner A can never observe owner B's data.
/// - **Server-assigned monotonic revisions** and an opaque cursor.
/// - **Optimistic-concurrency conflicts** — a push based on a stale
///   `baseRevision` is rejected, never silently overwritten.
/// - **Idempotent push** — a retried batch (same `idempotencyKey`) replays
///   its original result instead of double-applying.
/// - **Tombstones win** — a delete is accepted unconditionally and
///   propagated.
/// - **Pagination** — pulls are capped so `hasMore` is exercised.
actor InMemoryPersonalCloudBackend {

    struct StoredRecord: Sendable {
        var kind: PersonalRecordKind
        var id: UUID
        var remoteID: String
        var revision: Int          // server revision == the global cursor value when last written
        var payloadJSON: String
        var deletedAt: Date?
        var updatedAt: Date
    }

    private struct OwnerStore {
        var records: [UUID: StoredRecord] = [:]
        var cursor: Int = 0
        var seenIdempotencyKeys: [String: SyncPushResult] = [:]
    }

    private var owners: [String: OwnerStore] = [:]
    private let pageSize: Int

    init(pageSize: Int = 50) {
        self.pageSize = pageSize
    }

    // MARK: - Pull

    func pull(ownerID: String, since cursor: String?) -> SyncPullResult {
        var store = owners[ownerID] ?? OwnerStore()
        let sinceValue = cursor.flatMap(Int.init) ?? 0
        let changed = store.records.values
            .filter { $0.revision > sinceValue }
            .sorted { $0.revision < $1.revision }
        let page = Array(changed.prefix(pageSize))
        let hasMore = changed.count > pageSize
        let newCursor = page.last?.revision ?? sinceValue
        owners[ownerID] = store
        return SyncPullResult(
            cursor: String(newCursor),
            records: page.map { envelope(from: $0) },
            hasMore: hasMore
        )
    }

    // MARK: - Push

    func push(_ request: SyncPushRequest) -> SyncPushResult {
        var store = owners[request.ownerID] ?? OwnerStore()

        // Idempotent replay — a retried batch never double-applies.
        if let prior = store.seenIdempotencyKeys[request.idempotencyKey] {
            owners[request.ownerID] = store
            return prior
        }

        var accepted: [SyncRecordEnvelope] = []
        var conflicts: [SyncConflict] = []

        for envelope in request.records {
            let existing = store.records[envelope.id]

            if let existing {
                // Tombstone always wins.
                if envelope.deletedAt != nil {
                    store.cursor += 1
                    var updated = existing
                    updated.deletedAt = envelope.deletedAt
                    updated.revision = store.cursor
                    updated.updatedAt = Date()
                    updated.payloadJSON = envelope.payloadJSON.isEmpty ? existing.payloadJSON : envelope.payloadJSON
                    store.records[envelope.id] = updated
                    accepted.append(self.envelope(from: updated))
                    continue
                }
                // Stale base → conflict, no overwrite.
                guard envelope.baseRevision >= existing.revision else {
                    conflicts.append(SyncConflict(
                        id: envelope.id,
                        kind: envelope.kind,
                        clientPayloadJSON: envelope.payloadJSON,
                        serverPayloadJSON: existing.payloadJSON,
                        serverRevision: existing.revision,
                        serverRemoteID: existing.remoteID,
                        serverDeletedAt: existing.deletedAt
                    ))
                    continue
                }
                store.cursor += 1
                var updated = existing
                updated.payloadJSON = envelope.payloadJSON
                updated.deletedAt = envelope.deletedAt
                updated.revision = store.cursor
                updated.updatedAt = Date()
                store.records[envelope.id] = updated
                accepted.append(self.envelope(from: updated))
            } else {
                store.cursor += 1
                let record = StoredRecord(
                    kind: envelope.kind,
                    id: envelope.id,
                    remoteID: envelope.remoteID ?? "srv_\(envelope.id.uuidString.prefix(12))",
                    revision: store.cursor,
                    payloadJSON: envelope.payloadJSON,
                    deletedAt: envelope.deletedAt,
                    updatedAt: Date()
                )
                store.records[envelope.id] = record
                accepted.append(self.envelope(from: record))
            }
        }

        let result = SyncPushResult(cursor: String(store.cursor), accepted: accepted, conflicts: conflicts)
        store.seenIdempotencyKeys[request.idempotencyKey] = result
        owners[request.ownerID] = store
        return result
    }

    // MARK: - Snapshot / delete

    func snapshotEnvelopes(ownerID: String) -> (cursor: String, records: [SyncRecordEnvelope]) {
        let store = owners[ownerID] ?? OwnerStore()
        let all = store.records.values.sorted { $0.revision < $1.revision }.map { envelope(from: $0) }
        return (String(store.cursor), all)
    }

    func deleteAllData(ownerID: String) {
        owners[ownerID] = OwnerStore()
    }

    // MARK: - Test introspection

    func recordCount(ownerID: String) -> Int {
        (owners[ownerID]?.records.values.filter { $0.deletedAt == nil }.count) ?? 0
    }

    func rawRecord(ownerID: String, id: UUID) -> StoredRecord? {
        owners[ownerID]?.records[id]
    }

    func knownOwnerIDs() -> Set<String> { Set(owners.keys) }

    // MARK: - Helpers

    private func envelope(from record: StoredRecord) -> SyncRecordEnvelope {
        SyncRecordEnvelope(
            kind: record.kind,
            id: record.id,
            remoteID: record.remoteID,
            baseRevision: record.revision,
            payloadJSON: record.payloadJSON,
            deletedAt: record.deletedAt,
            serverRevision: record.revision
        )
    }
}
