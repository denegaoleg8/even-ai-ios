import CloudKit
import CryptoKit

/// `PersonalCloudService` backed by an Apple CloudKit **private** database —
/// the one and only cloud provider adapter. Everything above
/// `PersonalCloudService` (the sync engine, conflict resolver, restore
/// coordinator, data store, exporter) is provider-agnostic and untouched.
///
/// Design (`PHASE2_CLOUDKIT_STEP1_PLAN.md`):
/// - two custom zones (`CloudKitSchema`), private database only
/// - record-per-canonical-entity; the entity JSON in one encrypted field
/// - stable record names = canonical UUIDs; CloudKit never mints an identity
///   the app depends on
/// - the engine's `Int` `baseRevision` is bridged to CloudKit change tags by
///   a local side-table (`CloudKitAdapterState`)
/// - the canonical portable identity stays `PersonalAIUserID`; the iCloud
///   account is bound to it as *infrastructure* identity only
///
/// **Invariant:** every failure path surfaces as a thrown
/// `PersonalCloudTransportError`, which the engine turns into
/// `.failedRetryable` — pending changes stay queued, the cursor is untouched,
/// **no local authoritative memory is ever cleared.**
struct CloudKitPersonalCloudService: PersonalCloudService {

    let database: any CloudKitDatabaseFacade
    let stateStore: any CloudKitAdapterStateStore
    let zones: CloudKitZoneManager
    let personalAIUserIDProvider: @Sendable () -> String?
    let pageLimit: Int

    /// Direct construction. `stateStore` defaults to **in-memory** — fine for
    /// tests and explicit control, but a **real** wiring must use
    /// `makePersisted(...)` so the account binding and sync cursor survive an
    /// app relaunch.
    init(
        database: any CloudKitDatabaseFacade,
        stateStore: any CloudKitAdapterStateStore = InMemoryCloudKitAdapterStateStore(),
        personalAIUserID: @escaping @Sendable () -> String?,
        pageLimit: Int = 200
    ) {
        self.database = database
        self.stateStore = stateStore
        self.zones = CloudKitZoneManager(database: database)
        self.personalAIUserIDProvider = personalAIUserID
        self.pageLimit = pageLimit
    }

    /// The composition a real (future) `.connected` wiring uses: a
    /// **file-backed, sealed, atomic-write** side-table so the
    /// `PersonalAIUserID ↔ iCloud account` binding and the per-zone sync
    /// cursor survive an app relaunch / process restart. A missing / corrupt /
    /// too-new state file resets **adapter metadata only** — never canonical
    /// Personal AI memory.
    ///
    /// This does **not** enable real CloudKit: the caller still supplies the
    /// database facade (a `LiveCloudKitDatabaseFacade` only once the container
    /// exists). `PersonalAIContainer.live` is unchanged.
    static func makePersisted(
        database: any CloudKitDatabaseFacade,
        stateDirectory: URL,
        documentFile: any DocumentFileStoring,
        personalAIUserID: @escaping @Sendable () -> String?,
        pageLimit: Int = 200
    ) -> CloudKitPersonalCloudService {
        try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let url = stateDirectory.appendingPathComponent("cloudkit-adapter-state.eap", isDirectory: false)
        return CloudKitPersonalCloudService(
            database: database,
            stateStore: FileCloudKitAdapterStateStore(url: url, file: documentFile),
            personalAIUserID: personalAIUserID,
            pageLimit: pageLimit
        )
    }

    // MARK: - Account gate

    /// Read-only account state for the UI / diagnostics. Never mutates the
    /// binding.
    func currentAccountState() async -> CloudKitAccountState {
        let status = await database.accountStatus()
        let iCloudUser = status == .available ? try? await database.currentUserRecordName() : nil
        let state = await stateStore.load()
        return CloudKitAccountEvaluator.evaluate(
            status: status,
            currentICloudUserRecordName: iCloudUser,
            binding: state.binding,
            personalAIUserID: personalAIUserIDProvider()
        )
    }

    /// Require a syncable account. Returns the active binding, or throws the
    /// right transport error (→ `.failedRetryable`, all local data retained).
    /// On first use for a `PersonalAIUserID` it creates the binding.
    @discardableResult
    private func requireBoundAccount() async throws -> CloudKitAccountBinding {
        let status = await database.accountStatus()
        let iCloudUser = status == .available ? try? await database.currentUserRecordName() : nil
        var state = await stateStore.load()
        let accountState = CloudKitAccountEvaluator.evaluate(
            status: status,
            currentICloudUserRecordName: iCloudUser,
            binding: state.binding,
            personalAIUserID: personalAIUserIDProvider()
        )

        switch accountState {
        case .bound:
            return state.binding!

        case .unbound:
            guard let personalAIUserID = personalAIUserIDProvider(), let iCloudUser else {
                throw PersonalCloudTransportError.offline
            }
            let binding = CloudKitAccountBinding(
                personalAIUserID: personalAIUserID,
                ckUserRecordName: iCloudUser,
                boundAt: Date()
            )
            state.binding = binding
            await stateStore.save(state)
            DiagnosticTrace.log("PERSONAL_AI_CLOUDKIT", "ACCOUNT_BOUND user=\(shortHash(personalAIUserID))")
            return binding

        case .noAccount, .restricted:
            DiagnosticTrace.log("PERSONAL_AI_CLOUDKIT", "ACCOUNT_UNAVAILABLE state=\(accountState)")
            throw PersonalCloudTransportError.unauthorized

        case .indeterminate:
            throw PersonalCloudTransportError.offline

        case .reconciliationRequired(let reason):
            DiagnosticTrace.log(
                "PERSONAL_AI_CLOUDKIT",
                "ACCOUNT_MISMATCH expected=\(shortHash(reason.expectedICloudUser)) actual=\(shortHash(reason.actualICloudUser)) — sync frozen, local data retained"
            )
            // Freeze — never auto-upload A's data into B, never merge, never
            // rebind. The engine keeps all pending changes and all local data.
            throw PersonalCloudTransportError.unauthorized
        }
    }

    // MARK: - Push

    func push(_ request: SyncPushRequest) async throws -> SyncPushResult {
        try await requireBoundAccount()
        try await zones.ensureZones()

        var state = await stateStore.load()
        var accepted: [SyncRecordEnvelope] = []
        var conflicts: [SyncConflict] = []

        // Group by zone; chunk within a zone to the batch limit.
        let byZone = Dictionary(grouping: request.records) { CloudKitSchema.Zone.containing($0.kind) }

        for (zone, envelopes) in byZone {
            for chunk in envelopes.chunked(into: pageLimit) {
                let saves: [CloudKitSaveRequest] = chunk.map { envelope in
                    let key = CloudKitAdapterState.key(zone: zone, recordName: envelope.id.uuidString)
                    let known = state.records[key]
                    return CloudKitSaveRequest(
                        record: CloudKitRecordMapper.makeRecord(from: envelope, systemFieldsArchive: known?.systemFieldsArchive),
                        expectedChangeTag: known?.changeTag,
                        systemFieldsArchive: known?.systemFieldsArchive
                    )
                }

                let results: [CloudKitSaveResult]
                do {
                    results = try await database.modify(saves, deleting: [])
                } catch {
                    // Whole-batch failure — persist nothing new, everything
                    // stays pending, cursor untouched.
                    await stateStore.save(state)
                    let mapped = CloudKitErrorMapper.map(error)
                    DiagnosticTrace.log("PERSONAL_AI_CLOUDKIT", "PUSH_FAIL code=\(mapped.code)")
                    throw mapped.transport
                }

                let envelopeByName = Dictionary(uniqueKeysWithValues: chunk.map { ($0.id.uuidString, $0) })

                for result in results {
                    switch result {
                    case let .saved(recordName, changeTag, systemFields):
                        guard let envelope = envelopeByName[recordName] else { continue }
                        let key = CloudKitAdapterState.key(zone: zone, recordName: recordName)
                        let revision = state.takeSyntheticRevision()
                        state.records[key] = .init(changeTag: changeTag, syntheticRevision: revision, systemFieldsArchive: systemFields)
                        var acceptedEnvelope = envelope
                        acceptedEnvelope.remoteID = recordName
                        acceptedEnvelope.serverRevision = revision
                        accepted.append(acceptedEnvelope)

                    case let .conflict(recordName, serverRecord, serverChangeTag):
                        guard let clientEnvelope = envelopeByName[recordName],
                              let serverEnvelope = CloudKitRecordMapper.makeEnvelope(from: serverRecord, syntheticRevision: 0)
                        else { continue }
                        let key = CloudKitAdapterState.key(zone: zone, recordName: recordName)
                        let revision = state.takeSyntheticRevision()
                        state.records[key] = .init(
                            changeTag: serverChangeTag,
                            syntheticRevision: revision,
                            systemFieldsArchive: CloudKitRecordMapper.archiveSystemFields(of: serverRecord)
                        )
                        conflicts.append(SyncConflict(
                            id: clientEnvelope.id,
                            kind: clientEnvelope.kind,
                            clientPayloadJSON: clientEnvelope.payloadJSON,
                            serverPayloadJSON: serverEnvelope.payloadJSON,
                            serverRevision: revision,
                            serverRemoteID: recordName,
                            serverDeletedAt: serverEnvelope.deletedAt
                        ))

                    case let .transient(recordName, code):
                        // Leave it pending — the engine retries next round.
                        DiagnosticTrace.log("PERSONAL_AI_CLOUDKIT", "PUSH_RECORD_TRANSIENT name=\(recordName) code=\(code)")

                    case let .unknownItem(recordName):
                        // Record/zone gone — drop local sync state so the next
                        // push re-creates it.
                        let key = CloudKitAdapterState.key(zone: zone, recordName: recordName)
                        state.records[key] = nil
                    }
                }
            }
        }

        await stateStore.save(state)
        DiagnosticTrace.log("PERSONAL_AI_CLOUDKIT", "PUSH_OK accepted=\(accepted.count) conflicts=\(conflicts.count)")
        return SyncPushResult(cursor: state.cursor.encoded(), accepted: accepted, conflicts: conflicts)
    }

    // MARK: - Pull

    func pull(ownerID: String, since cursor: String?) async throws -> SyncPullResult {
        try await requireBoundAccount()

        var state = await stateStore.load()
        // A cursor we recognise wins; otherwise fall back to our persisted
        // tokens (e.g. right after a snapshot restore, where the coordinator
        // passes a value it computed for the mock backend).
        let startCursor = CloudKitSyncCursor.decode(cursor) ?? state.cursor

        var envelopes: [SyncRecordEnvelope] = []
        var newCursor = startCursor
        var anyMore = false

        for zone in CloudKitSchema.Zone.allCases {
            let (zoneEnvelopes, zoneToken, moreComing) = try await fetchZonePage(
                zone: zone,
                since: startCursor.token(for: zone),
                state: &state
            )
            envelopes.append(contentsOf: zoneEnvelopes)
            newCursor = newCursor.setting(zone, zoneToken)
            anyMore = anyMore || moreComing
        }

        state.cursor = newCursor
        await stateStore.save(state)
        DiagnosticTrace.log("PERSONAL_AI_CLOUDKIT", "PULL_OK records=\(envelopes.count) more=\(anyMore)")
        return SyncPullResult(cursor: newCursor.encoded(), records: envelopes, hasMore: anyMore)
    }

    /// Fetch one page from one zone. On `changeTokenExpired`, retry once from
    /// `nil`. A malformed record throws a `decode` error **without** advancing
    /// the token or touching local data.
    private func fetchZonePage(
        zone: CloudKitSchema.Zone,
        since token: CloudKitZoneToken?,
        state: inout CloudKitAdapterState
    ) async throws -> ([SyncRecordEnvelope], CloudKitZoneToken?, Bool) {

        var effectiveToken = token
        var attempts = 0

        while true {
            attempts += 1
            let changes: CloudKitZoneChanges
            do {
                changes = try await database.fetchChanges(zoneID: zone.zoneID, since: effectiveToken, resultLimit: pageLimit)
            } catch {
                let mapped = CloudKitErrorMapper.map(error)
                if mapped.code == "changeTokenExpired", attempts == 1 {
                    effectiveToken = nil
                    continue
                }
                DiagnosticTrace.log("PERSONAL_AI_CLOUDKIT", "PULL_FAIL zone=\(zone.zoneName) code=\(mapped.code)")
                throw mapped.transport
            }

            if changes.tokenExpired, attempts == 1 {
                effectiveToken = nil
                continue
            }
            if changes.zoneNotFound {
                await zones.invalidate()
                return ([], effectiveToken, false)
            }

            var pageEnvelopes: [SyncRecordEnvelope] = []

            for change in changes.changed {
                let revision = state.takeSyntheticRevision()
                guard let envelope = CloudKitRecordMapper.makeEnvelope(from: change.record, syntheticRevision: revision) else {
                    // Malformed payload — abandon this pull without advancing.
                    throw PersonalCloudTransportError.decode
                }
                let key = CloudKitAdapterState.key(zone: zone, recordName: change.record.recordID.recordName)
                state.records[key] = .init(
                    changeTag: change.changeTag,
                    syntheticRevision: revision,
                    systemFieldsArchive: CloudKitRecordMapper.archiveSystemFields(of: change.record)
                )
                pageEnvelopes.append(envelope)
            }

            for deletion in changes.deleted {
                let revision = state.takeSyntheticRevision()
                if let envelope = CloudKitRecordMapper.makeTombstoneEnvelope(
                    recordName: deletion.recordName,
                    recordType: deletion.recordType,
                    syntheticRevision: revision
                ) {
                    pageEnvelopes.append(envelope)
                }
                let key = CloudKitAdapterState.key(zone: zone, recordName: deletion.recordName)
                state.records[key] = nil
            }

            return (pageEnvelopes, changes.newToken ?? effectiveToken, changes.moreComing)
        }
    }

    // MARK: - Snapshot (new-device / disaster recovery)

    func snapshot(ownerID: String) async throws -> PersonalDataBundle {
        try await requireBoundAccount()
        try await zones.ensureZones()

        var state = await stateStore.load()
        var allEnvelopes: [SyncRecordEnvelope] = []
        var endCursor = CloudKitSyncCursor.empty

        for zone in CloudKitSchema.Zone.allCases {
            var token: CloudKitZoneToken? = nil
            var pages = 0
            while pages < 10_000 {
                pages += 1
                let changes = try await database.fetchChanges(zoneID: zone.zoneID, since: token, resultLimit: pageLimit)
                if changes.zoneNotFound { break }

                for change in changes.changed {
                    let revision = state.takeSyntheticRevision()
                    guard let envelope = CloudKitRecordMapper.makeEnvelope(from: change.record, syntheticRevision: revision) else {
                        throw PersonalCloudTransportError.decode
                    }
                    let key = CloudKitAdapterState.key(zone: zone, recordName: change.record.recordID.recordName)
                    state.records[key] = .init(
                        changeTag: change.changeTag,
                        syntheticRevision: revision,
                        systemFieldsArchive: CloudKitRecordMapper.archiveSystemFields(of: change.record)
                    )
                    allEnvelopes.append(envelope)
                }
                token = changes.newToken ?? token
                if !changes.moreComing { break }
            }
            endCursor = endCursor.setting(zone, token)
        }

        // Persist the ending tokens so the first incremental pull after a
        // restore continues cleanly even though the restore coordinator passes
        // a cursor it computed for a different backend shape.
        state.cursor = endCursor
        await stateStore.save(state)

        let bundle = PersonalBundleAssembler.assemble(
            from: allEnvelopes,
            bundleVersion: 0,
            ownerID: personalAIUserIDProvider()
        )
        DiagnosticTrace.log("PERSONAL_AI_CLOUDKIT", "SNAPSHOT_OK records=\(allEnvelopes.count)")
        return bundle
    }

    // MARK: - Delete everything

    func deleteAllData(ownerID: String) async throws {
        // Gate: if the account is mismatched, refuse — never delete another
        // iCloud account's data. The caller (`deletePersonalAIAccount`) has
        // already wiped local data unconditionally.
        try await requireBoundAccount()
        try await zones.deleteAllZones()
        await stateStore.save(.empty)
        DiagnosticTrace.log("PERSONAL_AI_CLOUDKIT", "DELETE_ALL_OK")
    }

    // MARK: - Helpers

    private func shortHash(_ value: String) -> String {
        String(SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8))
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
