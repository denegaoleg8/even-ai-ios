import Foundation
import CryptoKit

/// Produces independent, encrypted backups of the full `PersonalDataBundle`
/// and prunes them per a retention schedule. Independent of
/// `PersonalCloudService` by design (§14): the primary store failing, or the
/// sync engine misbehaving, cannot take backups down with it.
///
/// **Application-level encryption** (§16): every bundle is AES-GCM sealed
/// with the local `SymmetricKeyStore` key *before* it reaches `BackupStore`.
/// The report documents this as client-side sealing — provider-managed
/// encryption (S3 SSE etc.) would be an additional, additive layer, not a
/// replacement, and is not claimed here.
actor PersonalAIBackupCoordinator {

    enum Tier: String, Sendable, CaseIterable {
        case incremental, daily, weekly, monthly
    }

    struct Outcome: Equatable, Sendable {
        var tier: Tier
        var bundleVersion: Int
        var checksum: String
        var recordCounts: [String: Int]
        var succeeded: Bool
        var errorCode: String?
    }

    private let dataStore: any PersonalDataStore
    private let backupStore: any BackupStore
    private let keyStore: SymmetricKeyStore
    private let ownerIDProvider: @Sendable () -> String?
    private let clock: @Sendable () -> Date

    // Schedule (§15) — justified in the report.
    private let incrementalInterval: TimeInterval = 6 * 3600
    private let dailyInterval: TimeInterval = 24 * 3600
    private let retention: [Tier: Int] = [.incremental: 3, .daily: 7, .weekly: 4, .monthly: 3]

    init(
        dataStore: any PersonalDataStore,
        backupStore: any BackupStore,
        keyStore: SymmetricKeyStore,
        ownerID: @escaping @Sendable () -> String?,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.dataStore = dataStore
        self.backupStore = backupStore
        self.keyStore = keyStore
        self.ownerIDProvider = ownerID
        self.clock = clock
    }

    /// Run a backup only if one is due for `tier`, using `lastBackupAt` from
    /// sync state. Returns `nil` when nothing was due.
    func runIfDue() async -> Outcome? {
        let state = await dataStore.syncState()
        let now = clock()
        let sinceLast = state.lastBackupSucceededAt.map { now.timeIntervalSince($0) } ?? .infinity
        let tier: Tier
        if sinceLast >= dailyInterval {
            tier = .daily
        } else if sinceLast >= incrementalInterval {
            tier = .incremental
        } else {
            return nil
        }
        return await backup(tier: tier)
    }

    /// Force a backup now (user-initiated "Download Backup" / test).
    func backup(tier: Tier = .daily) async -> Outcome {
        guard let ownerID = ownerIDProvider(), !ownerID.isEmpty else {
            return Outcome(tier: tier, bundleVersion: 0, checksum: "", recordCounts: [:], succeeded: false, errorCode: "notAuthenticated")
        }

        await dataStore.updateSyncState { $0.lastBackupStartedAt = self.clock() }
        DiagnosticTrace.log("PERSONAL_AI_BACKUP", "BACKUP_START tier=\(tier.rawValue)")

        let state = await dataStore.syncState()
        let version = state.lastBackupVersion + 1
        let bundle = await dataStore.exportBundle(selection: .everything, bundleVersion: version)

        let sealed: Data
        do {
            let plaintext = try PersonalDataExporter.data(for: bundle)
            let box = try AES.GCM.seal(plaintext, using: keyStore.key())
            guard let combined = box.combined else { throw CocoaError(.fileWriteUnknown) }
            sealed = combined
        } catch {
            let code = "seal"
            await dataStore.updateSyncState { $0.lastBackupErrorCode = code }
            DiagnosticTrace.log("PERSONAL_AI_BACKUP", "BACKUP_FAILURE code=\(code)")
            return Outcome(tier: tier, bundleVersion: version, checksum: bundle.manifest.checksum, recordCounts: bundle.manifest.counts, succeeded: false, errorCode: code)
        }

        let handle = BackupHandle(
            id: UUID().uuidString,
            createdAt: clock(),
            bundleVersion: version,
            sizeBytes: sealed.count,
            checksum: bundle.manifest.checksum,
            tier: tier.rawValue
        )

        do {
            try await backupStore.putBackup(sealed, handle: handle, ownerID: ownerID)
        } catch {
            let code = "put"
            await dataStore.updateSyncState { $0.lastBackupErrorCode = code }
            DiagnosticTrace.log("PERSONAL_AI_BACKUP", "BACKUP_FAILURE code=\(code)")
            return Outcome(tier: tier, bundleVersion: version, checksum: handle.checksum, recordCounts: bundle.manifest.counts, succeeded: false, errorCode: code)
        }

        await prune(ownerID: ownerID)

        await dataStore.updateSyncState {
            $0.lastBackupSucceededAt = self.clock()
            $0.lastBackupVersion = version
            $0.lastBackupChecksum = handle.checksum
            $0.lastBackupErrorCode = nil
            $0.lastBackupRecordCounts = bundle.manifest.counts
        }
        DiagnosticTrace.log("PERSONAL_AI_BACKUP", "BACKUP_SUCCESS tier=\(tier.rawValue) version=\(version) counts=\(bundle.manifest.counts)")
        return Outcome(tier: tier, bundleVersion: version, checksum: handle.checksum, recordCounts: bundle.manifest.counts, succeeded: true, errorCode: nil)
    }

    /// Fetch + decrypt + validate the most recent backup (for "Restore from
    /// Backup"). Returns the bundle only if it passes every import check.
    func loadLatestBackupBundle() async -> Result<PersonalDataBundle, ImportError> {
        guard let ownerID = ownerIDProvider(), !ownerID.isEmpty else { return .failure(.unreadable) }
        guard let handles = try? await backupStore.listBackups(ownerID: ownerID), let latest = handles.first else {
            return .failure(.notAFile)
        }
        guard let sealed = try? await backupStore.getBackup(latest, ownerID: ownerID) else { return .failure(.unreadable) }
        guard
            let box = try? AES.GCM.SealedBox(combined: sealed),
            let plaintext = try? AES.GCM.open(box, using: keyStore.key())
        else { return .failure(.corrupt("backup will not decrypt")) }
        return PersonalDataImporter.validate(plaintext)
    }

    // MARK: - Retention

    private func prune(ownerID: String) async {
        guard let handles = try? await backupStore.listBackups(ownerID: ownerID) else { return }
        for tier in Tier.allCases {
            let keep = retention[tier] ?? 3
            let ofTier = handles.filter { $0.tier == tier.rawValue }.sorted { $0.createdAt > $1.createdAt }
            for stale in ofTier.dropFirst(keep) {
                try? await backupStore.deleteBackup(stale, ownerID: ownerID)
            }
        }
    }
}
