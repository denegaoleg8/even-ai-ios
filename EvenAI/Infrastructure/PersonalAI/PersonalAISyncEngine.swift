import Foundation
import CryptoKit

private struct SyncStepError: Error { var code: String }

/// Incremental, retryable, idempotent sync between the local
/// `PersonalDataStore` and a `PersonalCloudService`.
///
/// The one invariant above every feature: **a sync failure never deletes or
/// corrupts valid local data.** A failed push keeps every change queued; a
/// failed pull leaves the cursor untouched; a cancellation leaves a
/// consistent state.
///
/// Diagnostics (`SYNC_START` / `SYNC_SUCCESS` / `SYNC_FAILURE`) carry ids,
/// counts and error codes only — never memory content.
actor PersonalAISyncEngine {

    private let dataStore: any PersonalDataStore
    private let cloudService: (any PersonalCloudService)?
    private let ownerIDProvider: @Sendable () -> String?
    private let memoryEnabledProvider: @Sendable () async -> Bool
    private let resolver: PersonalConflictResolver
    private let maxPullPages: Int
    /// Stable per-install id, mixed into the idempotency key so two devices
    /// pushing the same record from the same base revision never collide on
    /// the server's dedupe table.
    private let deviceID: String

    private var running = false

    init(
        dataStore: any PersonalDataStore,
        cloudService: (any PersonalCloudService)?,
        ownerID: @escaping @Sendable () -> String?,
        memoryEnabled: @escaping @Sendable () async -> Bool = { true },
        resolver: PersonalConflictResolver = PersonalConflictResolver(),
        maxPullPages: Int = 100,
        deviceID: String = PersonalAISyncEngine.installDeviceID()
    ) {
        self.dataStore = dataStore
        self.cloudService = cloudService
        self.ownerIDProvider = ownerID
        self.memoryEnabledProvider = memoryEnabled
        self.resolver = resolver
        self.maxPullPages = maxPullPages
        self.deviceID = deviceID
    }

    /// A stable id for this install, persisted in `UserDefaults`. Distinct
    /// from the Keychain device identity — this one is non-secret sync
    /// plumbing.
    static func installDeviceID(defaults: UserDefaults = .standard) -> String {
        let key = "com.evenai.personalai.syncDeviceID"
        if let existing = defaults.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: key)
        return fresh
    }

    var isRunning: Bool { running }

    /// One full sync pass. Safe to call concurrently — a second call while
    /// one is in flight returns `.skipped(.alreadyRunning)`.
    func sync() async -> SyncOutcome {
        guard let cloudService else { return .skipped(reason: .noCloudService) }
        guard let ownerID = ownerIDProvider(), !ownerID.isEmpty else { return .skipped(reason: .notAuthenticated) }
        let state = await dataStore.syncState()
        guard state.cloudSyncEnabled else { return .skipped(reason: .syncDisabled) }
        guard !running else { return .skipped(reason: .alreadyRunning) }

        running = true
        defer { running = false }

        let memoryEnabled = await memoryEnabledProvider()
        await dataStore.updateSyncState { $0.lastSyncStartedAt = Date() }
        DiagnosticTrace.log("PERSONAL_AI_SYNC", "SYNC_START owner=\(hash(ownerID)) memoryEnabled=\(memoryEnabled)")

        var pushed = 0
        var conflictsResolved = 0

        // --- PUSH (skipped entirely when global memory is off: pull-only) ---
        if memoryEnabled {
            if Task.isCancelled { return finish(.skipped(reason: .cancelled), ownerID: ownerID) }
            let pendingResult = await pushPending(ownerID: ownerID, cloudService: cloudService)
            switch pendingResult {
            case .failure(let err):
                return finish(.failedRetryable(code: err.code), ownerID: ownerID, errorCode: err.code)
            case .success(let (count, resolved)):
                pushed = count
                conflictsResolved = resolved
            }
        }

        // --- PULL ---
        if Task.isCancelled { return finish(.skipped(reason: .cancelled), ownerID: ownerID) }
        let pullResult = await pullChanges(ownerID: ownerID, cloudService: cloudService)
        let pulled: Int
        switch pullResult {
        case .failure(let err):
            return finish(.failedRetryable(code: err.code), ownerID: ownerID, errorCode: err.code)
        case .success(let count):
            pulled = count
        }

        await dataStore.updateSyncState {
            $0.lastSyncSucceededAt = Date()
            $0.lastSyncErrorCode = nil
        }
        await refreshPendingCount()
        DiagnosticTrace.log("PERSONAL_AI_SYNC", "SYNC_SUCCESS pushed=\(pushed) pulled=\(pulled) conflicts=\(conflictsResolved)")
        return .completed(pushed: pushed, pulled: pulled, conflictsResolved: conflictsResolved)
    }

    // MARK: - Push

    private func pushPending(ownerID: String, cloudService: any PersonalCloudService) async -> Result<(Int, Int), SyncStepError> {
        var totalPushed = 0
        var conflictsResolved = 0
        var rounds = 0

        while rounds < 5 {
            rounds += 1
            let pending = await dataStore.pendingChanges()
            guard !pending.isEmpty else { break }

            let request = SyncPushRequest(
                ownerID: ownerID,
                records: pending,
                idempotencyKey: Self.idempotencyKey(for: pending, deviceID: deviceID)
            )
            let result: SyncPushResult
            do {
                result = try await cloudService.push(request)
            } catch {
                return .failure(SyncStepError(code: Self.code(for: error)))
            }

            await dataStore.markSynced(result.accepted)
            totalPushed += result.accepted.count

            guard !result.conflicts.isEmpty else { break }

            // Resolve conflicts deterministically, then loop to re-push the
            // resolved versions.
            var resolvedEnvelopes: [SyncRecordEnvelope] = []
            for conflict in result.conflicts {
                guard let resolution = resolver.resolve(conflict) else { continue }
                resolvedEnvelopes.append(resolution.resolved)
                if let extra = resolution.reissued { resolvedEnvelopes.append(extra) }
                if let revision = resolution.revision { await dataStore.appendResolvedRevision(revision) }
                conflictsResolved += 1
            }
            await dataStore.applyRemote(resolvedEnvelopes, asConflictResolution: true)
            // Next loop iteration re-collects pendingChanges (the resolved
            // records are now .pendingPush) and pushes them.
        }

        return .success((totalPushed, conflictsResolved))
    }

    // MARK: - Pull

    private func pullChanges(ownerID: String, cloudService: any PersonalCloudService) async -> Result<Int, SyncStepError> {
        var cursor = await dataStore.syncState().cursor
        var pulled = 0
        var pages = 0

        while pages < maxPullPages {
            pages += 1
            let result: SyncPullResult
            do {
                result = try await cloudService.pull(ownerID: ownerID, since: cursor)
            } catch {
                return .failure(SyncStepError(code: Self.code(for: error)))
            }

            // Guard against a malformed response: if any envelope fails to
            // decode, abandon this pull WITHOUT advancing the cursor and
            // WITHOUT touching local data.
            if result.records.contains(where: { PersonalSyncCodec.decode($0) == nil }) {
                return .failure(SyncStepError(code: "decode"))
            }

            _ = await dataStore.applyRemote(result.records)
            pulled += result.records.count
            let newCursor = result.cursor
            cursor = newCursor
            await dataStore.updateSyncState { $0.cursor = newCursor }

            if !result.hasMore { break }
        }

        return .success(pulled)
    }

    // MARK: - Helpers

    private func finish(_ outcome: SyncOutcome, ownerID: String, errorCode: String? = nil) -> SyncOutcome {
        if let errorCode {
            DiagnosticTrace.log("PERSONAL_AI_SYNC", "SYNC_FAILURE code=\(errorCode)")
        }
        return outcome
    }

    private func refreshPendingCount() async {
        let count = await dataStore.pendingChanges().count
        await dataStore.updateSyncState { $0.pendingMutationCount = count }
    }

    /// Deterministic key over the batch's (id, revision) pairs, so a retried
    /// identical batch is recognised by the server.
    static func idempotencyKey(for envelopes: [SyncRecordEnvelope], deviceID: String) -> String {
        let canonical = deviceID + "#" + envelopes
            .map { "\($0.kind.rawValue):\($0.id.uuidString):\($0.baseRevision):\($0.deletedAt != nil)" }
            .sorted()
            .joined(separator: "|")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func code(for error: Error) -> String {
        if let transport = error as? PersonalCloudTransportError { return transport.code }
        return "unknown"
    }

    private func hash(_ s: String) -> String {
        String(SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8))
    }
}
