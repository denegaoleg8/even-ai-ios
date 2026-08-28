import CloudKit
import Foundation
@testable import EvenAI

/// Deterministic in-memory `CloudKitDatabaseFacade`. **No real `CKContainer`,
/// no network.** Models the CloudKit behaviours the adapter depends on:
///
/// - **Per-iCloud-account partitions** — each iCloud user has its own private
///   database (its own zones + records). Switching accounts swaps partition;
///   switching back restores it. This is how a real private database behaves.
/// - server-assigned monotonic change tags + an opaque per-zone token
/// - optimistic-concurrency conflicts (stale `expectedChangeTag`)
/// - pagination (`resultLimit` / `moreComing`)
/// - injectable failures: account status, transient errors, token expiry
final class FakeCloudKitDatabase: CloudKitDatabaseFacade, @unchecked Sendable {

    private struct Stored {
        var record: CKRecord
        var changeTag: String
        var seq: Int
    }

    private struct Partition {
        var storesByZone: [String: [String: Stored]] = [:]
        var existingZones: Set<String> = []
        var seq = 0
    }

    private let lock = NSLock()
    private var partitions: [String: Partition] = [:]
    private var currentUser = "icloud-user-A"

    // MARK: Injectable state

    var accountStatusValue: CKAccountStatus = .available
    var userRecordNameError: Error?
    /// Thrown once by the next modify/fetch, then cleared.
    var failNextOperation: Error?
    /// Thrown by every modify/fetch until cleared.
    var alwaysFail: Error?
    /// These record names return `.transient` on modify instead of saving.
    var transientRecordNames: Set<String> = []
    /// The next `fetchChanges` with a non-nil token reports `tokenExpired`.
    var forceTokenExpiredOnce = false
    var pageSize = 50

    var userRecordNameValue: String {
        get { lock.withLock { currentUser } }
        set { lock.withLock { currentUser = newValue } }
    }

    /// Model an iCloud account switch: a different private database (a fresh,
    /// empty partition on first visit; the prior one on return).
    func simulateICloudAccountSwitch(to newUserRecordName: String) {
        lock.withLock { currentUser = newUserRecordName }
    }

    // MARK: CloudKitDatabaseFacade

    func accountStatus() async -> CKAccountStatus { lock.withLock { accountStatusValue } }

    func currentUserRecordName() async throws -> String {
        try lock.withLock {
            if let error = userRecordNameError { throw error }
            return currentUser
        }
    }

    func ensureZones(_ zoneIDs: [CKRecordZone.ID]) async throws {
        try throwIfConfigured()
        lock.withLock {
            var p = partitions[currentUser] ?? Partition()
            for zoneID in zoneIDs {
                p.existingZones.insert(zoneID.zoneName)
                if p.storesByZone[zoneID.zoneName] == nil { p.storesByZone[zoneID.zoneName] = [:] }
            }
            partitions[currentUser] = p
        }
    }

    func deleteZones(_ zoneIDs: [CKRecordZone.ID]) async throws {
        try throwIfConfigured()
        lock.withLock {
            var p = partitions[currentUser] ?? Partition()
            for zoneID in zoneIDs {
                p.existingZones.remove(zoneID.zoneName)
                p.storesByZone[zoneID.zoneName] = nil
            }
            partitions[currentUser] = p
        }
    }

    func modify(_ saves: [CloudKitSaveRequest], deleting: [CKRecord.ID]) async throws -> [CloudKitSaveResult] {
        try throwIfConfigured()
        return lock.withLock {
            var p = partitions[currentUser] ?? Partition()
            var results: [CloudKitSaveResult] = []

            for save in saves {
                let zoneName = save.record.recordID.zoneID.zoneName
                let name = save.record.recordID.recordName

                if transientRecordNames.contains(name) {
                    results.append(.transient(recordName: name, code: "networkUnavailable"))
                    continue
                }

                var store = p.storesByZone[zoneName] ?? [:]
                let existing = store[name]

                if let expected = save.expectedChangeTag {
                    guard let existing else { results.append(.unknownItem(recordName: name)); continue }
                    guard existing.changeTag == expected else {
                        results.append(.conflict(recordName: name, serverRecord: existing.record, serverChangeTag: existing.changeTag))
                        continue
                    }
                } else if let existing {
                    results.append(.conflict(recordName: name, serverRecord: existing.record, serverChangeTag: existing.changeTag))
                    continue
                }

                p.seq += 1
                let tag = "t\(p.seq)"
                store[name] = Stored(record: save.record, changeTag: tag, seq: p.seq)
                p.storesByZone[zoneName] = store
                results.append(.saved(recordName: name, changeTag: tag, systemFieldsArchive: nil))
            }

            partitions[currentUser] = p
            return results
        }
    }

    func fetchChanges(zoneID: CKRecordZone.ID, since token: CloudKitZoneToken?, resultLimit: Int) async throws -> CloudKitZoneChanges {
        try throwIfConfigured()
        return lock.withLock {
            var changes = CloudKitZoneChanges()

            if forceTokenExpiredOnce, token != nil {
                forceTokenExpiredOnce = false
                changes.tokenExpired = true
                return changes
            }

            let p = partitions[currentUser] ?? Partition()
            guard p.existingZones.contains(zoneID.zoneName) else {
                changes.zoneNotFound = true
                return changes
            }

            let since = token.flatMap { Int(String(data: $0.raw, encoding: .utf8) ?? "") } ?? 0
            let store = p.storesByZone[zoneID.zoneName] ?? [:]
            let newer = store.values.filter { $0.seq > since }.sorted { $0.seq < $1.seq }
            let limit = Swift.min(resultLimit, pageSize)
            let page = Array(newer.prefix(limit))

            for stored in page {
                changes.changed.append(.init(record: stored.record, changeTag: stored.changeTag))
            }
            let lastSeq = page.last?.seq ?? since
            changes.newToken = CloudKitZoneToken(raw: Data("\(lastSeq)".utf8))
            changes.moreComing = newer.count > page.count
            return changes
        }
    }

    // MARK: Test introspection

    func liveRecordCount(zone: CloudKitSchema.Zone, user: String? = nil) -> Int {
        lock.withLock { (partitions[user ?? currentUser]?.storesByZone[zone.zoneName] ?? [:]).count }
    }

    func totalRecordCount(user: String? = nil) -> Int {
        lock.withLock {
            (partitions[user ?? currentUser]?.storesByZone.values ?? [:].values)
                .reduce(0) { $0 + $1.count }
        }
    }

    func rawRecord(zone: CloudKitSchema.Zone, recordName: String) -> CKRecord? {
        lock.withLock { partitions[currentUser]?.storesByZone[zone.zoneName]?[recordName]?.record }
    }

    /// Inject a record directly (e.g. a malformed one, or one "written by
    /// another device").
    func inject(_ record: CKRecord, zone: CloudKitSchema.Zone) {
        lock.withLock {
            var p = partitions[currentUser] ?? Partition()
            p.existingZones.insert(zone.zoneName)
            var store = p.storesByZone[zone.zoneName] ?? [:]
            p.seq += 1
            store[record.recordID.recordName] = Stored(record: record, changeTag: "t\(p.seq)", seq: p.seq)
            p.storesByZone[zone.zoneName] = store
            partitions[currentUser] = p
        }
    }

    private func throwIfConfigured() throws {
        try lock.withLock {
            if let error = alwaysFail { throw error }
            if let error = failNextOperation { failNextOperation = nil; throw error }
        }
    }
}

extension NSLock {
    fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}

// MARK: - CKError fixtures

enum CKErrorFixture {
    static func make(_ code: CKError.Code, userInfo: [String: Any] = [:]) -> NSError {
        NSError(domain: CKErrorDomain, code: code.rawValue, userInfo: userInfo)
    }
    static var networkUnavailable: NSError { make(.networkUnavailable) }
    static var networkFailure: NSError { make(.networkFailure) }
    static var serviceUnavailable: NSError { make(.serviceUnavailable) }
    static var requestRateLimited: NSError { make(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: NSNumber(value: 7.0)]) }
    static var notAuthenticated: NSError { make(.notAuthenticated) }
    static var quotaExceeded: NSError { make(.quotaExceeded) }
    static var zoneBusy: NSError { make(.zoneBusy) }
    static var changeTokenExpired: NSError { make(.changeTokenExpired) }
    static var operationCancelled: NSError { make(.operationCancelled) }
    static var unknownItem: NSError { make(.unknownItem) }
    static var permissionFailure: NSError { make(.permissionFailure) }
    static var partialFailure: NSError { make(.partialFailure) }
}
