import CloudKit

/// The real `CloudKitDatabaseFacade` over `CKContainer(...).privateCloudDatabase`.
///
/// **Compiled, not yet exercised.** No CloudKit container / entitlement is
/// configured (see `PHASE2_CLOUDKIT_STEP1_PLAN.md` → pre-flight). This type is
/// wired only once the Apple Developer portal work is done and the container
/// exists; until then every deterministic test uses the in-memory double.
///
/// Uses the stable `CKOperation` classes (available since iOS 13) rather than
/// the newer one-shot async convenience methods, so the surface is
/// well-understood and unlikely to shift.
struct LiveCloudKitDatabaseFacade: CloudKitDatabaseFacade {

    let container: CKContainer
    var database: CKDatabase { container.privateCloudDatabase }

    init(containerIdentifier: String = CloudKitSchema.containerIdentifier) {
        self.container = CKContainer(identifier: containerIdentifier)
    }

    init(container: CKContainer) {
        self.container = container
    }

    // MARK: Account

    func accountStatus() async -> CKAccountStatus {
        (try? await container.accountStatus()) ?? .couldNotDetermine
    }

    func currentUserRecordName() async throws -> String {
        try await container.userRecordID().recordName
    }

    // MARK: Zones

    func ensureZones(_ zoneIDs: [CKRecordZone.ID]) async throws {
        let zones = zoneIDs.map { CKRecordZone(zoneID: $0) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let op = CKModifyRecordZonesOperation(recordZonesToSave: zones, recordZoneIDsToDelete: nil)
            op.modifyRecordZonesResultBlock = { result in
                switch result {
                case .success: continuation.resume()
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
            database.add(op)
        }
    }

    func deleteZones(_ zoneIDs: [CKRecordZone.ID]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let op = CKModifyRecordZonesOperation(recordZonesToSave: nil, recordZoneIDsToDelete: zoneIDs)
            op.modifyRecordZonesResultBlock = { result in
                switch result {
                case .success: continuation.resume()
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
            database.add(op)
        }
    }

    // MARK: Modify

    func modify(_ saves: [CloudKitSaveRequest], deleting: [CKRecord.ID]) async throws -> [CloudKitSaveResult] {
        let records = saves.map(\.record)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[CloudKitSaveResult], Error>) in
            let op = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: deleting)
            op.savePolicy = .ifServerRecordUnchanged
            op.isAtomic = false
            var results: [CloudKitSaveResult] = []
            let lock = NSLock()

            op.perRecordSaveBlock = { recordID, result in
                lock.lock(); defer { lock.unlock() }
                switch result {
                case .success(let record):
                    results.append(.saved(
                        recordName: recordID.recordName,
                        changeTag: record.recordChangeTag ?? "",
                        systemFieldsArchive: CloudKitRecordMapper.archiveSystemFields(of: record)
                    ))
                case .failure(let error):
                    results.append(Self.classifySave(recordID: recordID, error: error))
                }
            }

            op.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume(returning: results)
                case .failure(let error):
                    let ck = error as? CKError
                    if ck?.code == .partialFailure {
                        // Per-record blocks already recorded outcomes.
                        continuation.resume(returning: results)
                    } else {
                        continuation.resume(throwing: error)
                    }
                }
            }
            database.add(op)
        }
    }

    private static func classifySave(recordID: CKRecord.ID, error: Error) -> CloudKitSaveResult {
        let mapped = CloudKitErrorMapper.map(error)
        switch mapped.code {
        case "serverRecordChanged":
            if let ck = error as? CKError, let serverRecord = ck.serverRecord {
                return .conflict(
                    recordName: recordID.recordName,
                    serverRecord: serverRecord,
                    serverChangeTag: serverRecord.recordChangeTag ?? ""
                )
            }
            return .transient(recordName: recordID.recordName, code: mapped.code)
        case "unknownItem", "zoneNotFound":
            return .unknownItem(recordName: recordID.recordName)
        default:
            return .transient(recordName: recordID.recordName, code: mapped.code)
        }
    }

    // MARK: Fetch changes

    func fetchChanges(zoneID: CKRecordZone.ID, since token: CloudKitZoneToken?, resultLimit: Int) async throws -> CloudKitZoneChanges {
        let serverToken = try Self.decodeToken(token)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CloudKitZoneChanges, Error>) in
            let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
            config.previousServerChangeToken = serverToken
            config.resultsLimit = resultLimit

            let op = CKFetchRecordZoneChangesOperation(
                recordZoneIDs: [zoneID],
                configurationsByRecordZoneID: [zoneID: config]
            )
            op.fetchAllChanges = false

            var changes = CloudKitZoneChanges()
            let lock = NSLock()

            op.recordWasChangedBlock = { _, result in
                lock.lock(); defer { lock.unlock() }
                if case .success(let record) = result {
                    changes.changed.append(.init(record: record, changeTag: record.recordChangeTag ?? ""))
                }
            }
            op.recordWithIDWasDeletedBlock = { recordID, recordType in
                lock.lock(); defer { lock.unlock() }
                changes.deleted.append(.init(recordName: recordID.recordName, recordType: recordType))
            }
            op.recordZoneChangeTokensUpdatedBlock = { _, newToken, _ in
                lock.lock(); defer { lock.unlock() }
                if let newToken { changes.newToken = Self.encodeToken(newToken) }
            }
            op.recordZoneFetchResultBlock = { _, result in
                lock.lock(); defer { lock.unlock() }
                switch result {
                case .success(let fetch):
                    changes.newToken = Self.encodeToken(fetch.serverChangeToken)
                    changes.moreComing = fetch.moreComing
                case .failure(let error):
                    let ck = error as? CKError
                    if ck?.code == .changeTokenExpired { changes.tokenExpired = true }
                    else if ck?.code == .zoneNotFound || ck?.code == .userDeletedZone { changes.zoneNotFound = true }
                }
            }
            op.fetchRecordZoneChangesResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume(returning: changes)
                case .failure(let error):
                    let ck = error as? CKError
                    if ck?.code == .changeTokenExpired {
                        changes.tokenExpired = true
                        continuation.resume(returning: changes)
                    } else if ck?.code == .zoneNotFound || ck?.code == .userDeletedZone {
                        changes.zoneNotFound = true
                        continuation.resume(returning: changes)
                    } else {
                        continuation.resume(throwing: error)
                    }
                }
            }
            database.add(op)
        }
    }

    // MARK: Token coding

    private static func encodeToken(_ token: CKServerChangeToken) -> CloudKitZoneToken? {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) else { return nil }
        return CloudKitZoneToken(raw: data)
    }

    private static func decodeToken(_ token: CloudKitZoneToken?) throws -> CKServerChangeToken? {
        guard let token else { return nil }
        return try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: token.raw)
    }
}
