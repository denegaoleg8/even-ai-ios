import Foundation

/// Produces independent, encrypted backups of the full `PersonalDataBundle`
/// and prunes them per a retention schedule. Independent of
/// `PersonalCloudService` by design (§14): the primary store failing, or the
/// sync engine misbehaving, cannot take backups down with it. This *is* the
/// "PersonalAIBackupService" of the R2 design doc.
///
/// **Application-level encryption** (§16): every bundle is sealed by
/// `BackupEncryptionProviding` (AES-256-GCM, Keychain key) *before* it reaches
/// `BackupStore`. Nothing that reaches the store — local dir or R2 — is
/// plaintext.
///
/// **Verify-before-publish**: after upload the object is read back, decrypted,
/// re-validated, and owner-checked. Only then is `lastBackupSucceededAt`
/// advanced. A corrupt or interrupted upload is deleted and the previous
/// verified backup stays the one a restore would pick.
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
    private let encryption: any BackupEncryptionProviding
    private let ownerIDProvider: @Sendable () -> String?
    private let clock: @Sendable () -> Date
    private let verifyAfterUpload: Bool

    // Schedule (§15) — justified in the report.
    private let incrementalInterval: TimeInterval = 6 * 3600
    private let dailyInterval: TimeInterval = 24 * 3600
    private let retention: [Tier: Int] = [.incremental: 3, .daily: 7, .weekly: 4, .monthly: 3]

    init(
        dataStore: any PersonalDataStore,
        backupStore: any BackupStore,
        keyStore: SymmetricKeyStore,
        ownerID: @escaping @Sendable () -> String?,
        encryption: (any BackupEncryptionProviding)? = nil,
        verifyAfterUpload: Bool = true,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.dataStore = dataStore
        self.backupStore = backupStore
        self.keyStore = keyStore
        self.encryption = encryption ?? AESGCMBackupEncryption(keyStore: keyStore, ownerID: ownerID, clock: clock)
        self.ownerIDProvider = ownerID
        self.verifyAfterUpload = verifyAfterUpload
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

    /// Force a backup now (user-initiated "Create recovery backup" / test).
    func backup(tier: Tier = .daily) async -> Outcome {
        guard let ownerID = ownerIDProvider(), !ownerID.isEmpty else {
            return Outcome(tier: tier, bundleVersion: 0, checksum: "", recordCounts: [:], succeeded: false, errorCode: "notAuthenticated")
        }

        await dataStore.updateSyncState { $0.lastBackupStartedAt = self.clock() }
        DiagnosticTrace.log("PERSONAL_AI_BACKUP", "BACKUP_START tier=\(tier.rawValue)")

        let state = await dataStore.syncState()
        let version = state.lastBackupVersion + 1
        let bundle = await dataStore.exportBundle(selection: .everything, bundleVersion: version)

        func fail(_ code: String) async -> Outcome {
            await dataStore.updateSyncState { $0.lastBackupErrorCode = code }
            DiagnosticTrace.log("PERSONAL_AI_BACKUP", "BACKUP_FAILURE code=\(code)")
            return Outcome(tier: tier, bundleVersion: version, checksum: bundle.manifest.checksum, recordCounts: bundle.manifest.counts, succeeded: false, errorCode: code)
        }

        // 1. Seal.
        let sealed: Data
        do {
            sealed = try encryption.seal(try PersonalDataExporter.data(for: bundle))
        } catch {
            return await fail("seal")
        }

        let handle = BackupHandle(
            id: UUID().uuidString,
            createdAt: clock(),
            bundleVersion: version,
            sizeBytes: sealed.count,
            checksum: bundle.manifest.checksum,
            tier: tier.rawValue
        )

        // 2. Upload. A throw here leaves every prior backup untouched.
        do {
            try await backupStore.putBackup(sealed, handle: handle, ownerID: ownerID)
        } catch {
            return await fail(Self.storeCode(for: error, fallback: "put"))
        }

        // 3. Verify-before-publish: read back, decrypt, re-validate, owner-check.
        if verifyAfterUpload {
            let verified = await verify(handle: handle, ownerID: ownerID, expectedChecksum: bundle.manifest.checksum)
            if !verified {
                try? await backupStore.deleteBackup(handle, ownerID: ownerID)
                return await fail("verify")
            }
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

    private func verify(handle: BackupHandle, ownerID: String, expectedChecksum: String) async -> Bool {
        guard let sealed = try? await backupStore.getBackup(handle, ownerID: ownerID),
              let plaintext = try? encryption.open(sealed),
              case .success(let bundle) = PersonalDataImporter.validate(plaintext),
              bundle.manifest.checksum == expectedChecksum,
              Self.ownerMatches(bundle: bundle, ownerID: ownerID)
        else { return false }
        return true
    }

    /// Fetch + decrypt + validate the most recent **recoverable** backup — the
    /// newest handle that decrypts, passes every import check, and belongs to
    /// this user. Skips a corrupt/foreign newest object and falls through to
    /// the previous good one.
    func loadLatestBackupBundle() async -> Result<PersonalDataBundle, ImportError> {
        guard let ownerID = ownerIDProvider(), !ownerID.isEmpty else { return .failure(.unreadable) }
        guard let handles = try? await backupStore.listBackups(ownerID: ownerID), !handles.isEmpty else {
            return .failure(.notAFile)
        }

        var lastError: ImportError = .notAFile
        for handle in handles.sorted(by: { $0.createdAt > $1.createdAt }) {
            guard let sealed = try? await backupStore.getBackup(handle, ownerID: ownerID) else {
                lastError = .unreadable; continue
            }
            guard let plaintext = try? encryption.open(sealed) else {
                lastError = .corrupt("backup will not decrypt"); continue
            }
            switch PersonalDataImporter.validate(plaintext) {
            case .failure(let error):
                lastError = error; continue
            case .success(let bundle):
                guard Self.ownerMatches(bundle: bundle, ownerID: ownerID) else {
                    lastError = .ownerMismatch; continue
                }
                return .success(bundle)
            }
        }
        return .failure(lastError)
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

    // MARK: - Helpers

    /// A backup with no recorded owner is accepted (Phase-1 / local-only
    /// backups predate authenticated ownership); a backup that names a
    /// *different* owner is rejected.
    private static func ownerMatches(bundle: PersonalDataBundle, ownerID: String) -> Bool {
        guard let bundleOwner = bundle.manifest.ownerID, !bundleOwner.isEmpty else { return true }
        return bundleOwner == ownerID
    }

    private static func storeCode(for error: Error, fallback: String) -> String {
        if let t = error as? BackupTransportError { return t.code }
        if let c = error as? BackupCredentialError { return c.code }
        return fallback
    }
}
