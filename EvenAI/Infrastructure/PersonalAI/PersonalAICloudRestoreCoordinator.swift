import Foundation

/// The exact scenarios §12 / §13 demand: a new iPhone, or a reinstall, with
/// **no local database** — authentication plus the cloud snapshot must be
/// enough to reconstruct the whole Personal AI.
///
/// `restoreFromCloud` pulls a full snapshot, validates it, applies it with
/// `.replaceAll`, and sets the sync cursor so the next incremental sync
/// continues cleanly. If the snapshot is unavailable or invalid, local data
/// is left exactly as it was.
struct PersonalAICloudRestoreCoordinator: Sendable {

    private let dataStore: any PersonalDataStore
    private let cloudService: (any PersonalCloudService)?
    private let backupCoordinator: PersonalAIBackupCoordinator?

    init(
        dataStore: any PersonalDataStore,
        cloudService: (any PersonalCloudService)?,
        backupCoordinator: PersonalAIBackupCoordinator? = nil
    ) {
        self.dataStore = dataStore
        self.cloudService = cloudService
        self.backupCoordinator = backupCoordinator
    }

    enum Source: String, Sendable { case cloud, backup, none }

    struct Outcome: Equatable, Sendable {
        var source: Source
        var result: ImportResult
        var succeeded: Bool { result.succeeded }
    }

    /// Try cloud first, then the newest independent backup as a fallback.
    func restore(ownerID: String) async -> Outcome {
        DiagnosticTrace.log("PERSONAL_AI_RESTORE", "RESTORE_START hasCloud=\(cloudService != nil)")

        if let cloudService {
            do {
                let bundle = try await cloudService.snapshot(ownerID: ownerID)
                switch PersonalDataImporter.validate(bundle) {
                case .success(let valid):
                    let result = await dataStore.importBundle(valid, strategy: .replaceAll)
                    await syncCursor(to: valid)
                    if result.succeeded {
                        await dataStore.updateSyncState { $0.needsCloudRestore = false }
                        DiagnosticTrace.log("PERSONAL_AI_RESTORE", "RESTORE_SUCCESS source=cloud counts=\(valid.manifest.counts)")
                        return Outcome(source: .cloud, result: result)
                    }
                case .failure(let error):
                    DiagnosticTrace.log("PERSONAL_AI_RESTORE", "RESTORE_FAILURE source=cloud code=\(error.code)")
                }
            } catch {
                DiagnosticTrace.log("PERSONAL_AI_RESTORE", "RESTORE_FAILURE source=cloud code=\(PersonalAISyncEngine.code(for: error))")
            }
        }

        if let backupCoordinator {
            switch await backupCoordinator.loadLatestBackupBundle() {
            case .success(let bundle):
                let result = await dataStore.importBundle(bundle, strategy: .replaceAll)
                if result.succeeded {
                    DiagnosticTrace.log("PERSONAL_AI_RESTORE", "RESTORE_SUCCESS source=backup counts=\(bundle.manifest.counts)")
                    return Outcome(source: .backup, result: result)
                }
            case .failure(let error):
                DiagnosticTrace.log("PERSONAL_AI_RESTORE", "RESTORE_FAILURE source=backup code=\(error.code)")
            }
        }

        return Outcome(source: .none, result: .failed)
    }

    private func syncCursor(to bundle: PersonalDataBundle) async {
        // The snapshot's records already carry server revisions; set the
        // cursor to the highest so the first incremental pull only fetches
        // newer changes.
        let maxRevision = max(
            bundle.memory.records.map(\.revision).max() ?? 0,
            bundle.memory.rules.map(\.revision).max() ?? 0,
            bundle.conversations.map(\.revision).max() ?? 0,
            bundle.messages.map(\.revision).max() ?? 0
        )
        await dataStore.updateSyncState { $0.cursor = String(maxRevision) }
    }
}
