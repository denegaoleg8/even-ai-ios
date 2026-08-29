import Foundation

/// Fans a backup out to more than one `BackupStore` and reads from the first
/// that has the object. The intended production shape once R2 is configured:
///
/// ```
/// CompositeBackupStore(
///   primary:   LocalDirectoryBackupStore(),   // always succeeds, on-device
///   secondary: [R2BackupStore(...)]            // best-effort, off-device DR
/// )
/// ```
///
/// **A secondary failure is never fatal.** `putBackup` succeeds as long as
/// `primary` succeeds; a throwing `R2BackupStore` (dormant, offline, quota)
/// only records `lastSecondaryError`. This is what keeps an R2 outage from
/// ever affecting local Personal AI data or the on-device recovery copy.
actor CompositeBackupStore: BackupStore {

    private let primary: any BackupStore
    private let secondaries: [any BackupStore]
    private(set) var lastSecondaryErrorCode: String?

    init(primary: any BackupStore, secondaries: [any BackupStore] = []) {
        self.primary = primary
        self.secondaries = secondaries
    }

    func putBackup(_ sealed: Data, handle: BackupHandle, ownerID: String) async throws {
        // Primary must succeed — its failure is the operation's failure.
        try await primary.putBackup(sealed, handle: handle, ownerID: ownerID)
        // Secondaries are best-effort.
        for store in secondaries {
            do {
                try await store.putBackup(sealed, handle: handle, ownerID: ownerID)
            } catch {
                lastSecondaryErrorCode = Self.code(for: error)
                DiagnosticTrace.log("PERSONAL_AI_BACKUP", "SECONDARY_PUT_FAILED code=\(lastSecondaryErrorCode ?? "unknown")")
            }
        }
    }

    func listBackups(ownerID: String) async throws -> [BackupHandle] {
        var byID: [String: BackupHandle] = [:]
        if let primaryList = try? await primary.listBackups(ownerID: ownerID) {
            for h in primaryList { byID[h.id] = h }
        }
        for store in secondaries {
            if let list = try? await store.listBackups(ownerID: ownerID) {
                for h in list where byID[h.id] == nil { byID[h.id] = h }
            }
        }
        return byID.values.sorted { $0.createdAt > $1.createdAt }
    }

    func getBackup(_ handle: BackupHandle, ownerID: String) async throws -> Data {
        if let data = try? await primary.getBackup(handle, ownerID: ownerID) { return data }
        for store in secondaries {
            if let data = try? await store.getBackup(handle, ownerID: ownerID) { return data }
        }
        throw BackupTransportError.notFound
    }

    func deleteBackup(_ handle: BackupHandle, ownerID: String) async throws {
        try? await primary.deleteBackup(handle, ownerID: ownerID)
        for store in secondaries {
            try? await store.deleteBackup(handle, ownerID: ownerID)
        }
    }

    private static func code(for error: Error) -> String {
        if let t = error as? BackupTransportError { return t.code }
        if let c = error as? BackupCredentialError { return c.code }
        return "unknown"
    }
}
