import Foundation

/// A thread-safe holder for the current signed-in owner id, shared by
/// reference between `PersonalAIService` (which sets it on auth changes) and
/// the sync / backup engines (which read it). Lets the `Sendable` engine
/// closures observe auth without capturing the `@MainActor` service.
final class PersonalOwnerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _ownerID: String?
    var ownerID: String? {
        get { lock.lock(); defer { lock.unlock() }; return _ownerID }
        set { lock.lock(); _ownerID = newValue; lock.unlock() }
    }
    init(ownerID: String? = nil) { _ownerID = ownerID }
}

/// Composition root for the Personal AI stack, Phase 1 + Phase 2. The one
/// place concrete implementations are chosen. Kept separate from
/// `AppContainer` so the proven AI Conversation / Chat / Auth wiring is not
/// touched.
///
/// ## Production is `.notConfigured` — deliberately
///
/// Phase 2 built and verified the cloud/sync/backup architecture against an
/// in-process simulation. **No external provider has been deployed**, so
/// `PersonalAIContainer.live` wires **no `PersonalCloudService` at all**
/// (`cloudService == nil`, `cloudEnvironment == .notConfigured`). In this
/// state:
/// - memory lives only on this device, AES-GCM encrypted;
/// - the sync engine is inert (`.skipped(.noCloudService)`);
/// - the UI says "not set up" and never claims cross-device durability;
/// - **Export** and **local Backup files** are the only ways to keep a copy
///   off-device — and both are real and work.
///
/// The `MockPersonalCloudService` simulation is reachable only via
/// `PersonalAIContainer.simulated()` — used by tests, and by a developer
/// build launched with `-EvenAISimulatedCloud`. It is never the default and
/// never ships as production behaviour.
///
/// Wiring a real backend (CloudKit / hosted API) is a Phase 3 change to
/// `cloudService` + `cloudEnvironment` here only — see
/// `PHASE2_PERSONAL_AI_CLOUD_IMPLEMENTATION.md`.
struct PersonalAIContainer: Sendable {
    let memoryStore: any PersonalMemoryStore
    let conversationStore: any PersonalAIConversationStore
    let contextBuilder: any PersonalAIContextBuilding
    let modelProvider: any PersonalAIModelProviding
    let dataStore: LocalPersonalDataStore
    let syncEngine: PersonalAISyncEngine
    let backupCoordinator: PersonalAIBackupCoordinator
    let restoreCoordinator: PersonalAICloudRestoreCoordinator
    let cloudService: (any PersonalCloudService)?
    let cloudEnvironment: PersonalCloudEnvironment
    let keyStore: SymmetricKeyStore
    let ownerBox: PersonalOwnerBox

    /// Production. No external cloud provider — local-only, honestly labelled.
    /// A developer build launched with `-EvenAISimulatedCloud` gets the
    /// in-process simulation instead (so the flow can be exercised on a
    /// device without ever shipping simulated persistence as real).
    static let live: PersonalAIContainer = {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-EvenAISimulatedCloud") {
            return .simulated()
        }
        #endif
        return make(cloudService: nil, environment: .notConfigured)
    }()

    /// In-process simulation. **Tests and developer builds only** — its
    /// "server" is RAM and does not survive an app relaunch. Never wired by
    /// `.live` in a shipping build.
    static func simulated() -> PersonalAIContainer {
        make(cloudService: MockPersonalCloudService(backend: InMemoryPersonalCloudBackend()),
             environment: .simulated)
    }

    static func make(cloudService: (any PersonalCloudService)?, environment: PersonalCloudEnvironment) -> PersonalAIContainer {
        let ownerBox = PersonalOwnerBox()
        let keyStore: SymmetricKeyStore = KeychainSymmetricKeyStore()
        let fileStore = EncryptedDocumentFile(keyStore: keyStore)

        let memoryStore = LocalPersonalMemoryStore(fileStore: fileStore)
        let conversationStore = LocalPersonalAIConversationStore(fileStore: fileStore)

        // Cross-lingual semantic retrieval — SEAM ONLY (Slice 1). The scorer
        // is `NoSemanticScorer` (`modelIdentifier == "none"`), so the builder
        // never embeds anything and retrieval stays exactly lexical. A real
        // on-device multilingual encoder drops in here as a one-line swap in
        // a later slice; the derived index is already wired and encrypted at
        // rest via the same `fileStore` as memory.
        let semanticScorer: any SemanticMemoryScoring = NoSemanticScorer()
        let embeddingIndex = EmbeddingVectorIndex(fileStore: fileStore)
        let dataStore = LocalPersonalDataStore(
            memory: memoryStore,
            conversations: conversationStore,
            ownerID: { ownerBox.ownerID }
        )

        let syncEngine = PersonalAISyncEngine(
            dataStore: dataStore,
            cloudService: cloudService,
            ownerID: { ownerBox.ownerID },
            memoryEnabled: { await memoryStore.isMemoryEnabledGlobally() }
        )

        // Local backup files work regardless of whether a cloud is wired —
        // an honest "keep a copy you control" affordance, not fake DR.
        let backupCoordinator = PersonalAIBackupCoordinator(
            dataStore: dataStore,
            backupStore: LocalDirectoryBackupStore(),
            keyStore: keyStore,
            ownerID: { ownerBox.ownerID }
        )

        let restoreCoordinator = PersonalAICloudRestoreCoordinator(
            dataStore: dataStore,
            cloudService: cloudService,
            backupCoordinator: backupCoordinator
        )

        return PersonalAIContainer(
            memoryStore: memoryStore,
            conversationStore: conversationStore,
            contextBuilder: DefaultPersonalAIContextBuilder(
                store: memoryStore,
                semanticScorer: semanticScorer,
                vectorIndex: embeddingIndex
            ),
            // Provider router — shipping behavior is exactly Apple
            // Foundation Models, else heuristic, UNLESS the DEBUG-only
            // `PersonalAIRemoteDevFlag` is explicitly enabled (never true
            // in Release; off by default in DEBUG too — see that type's
            // doc comment), in which case a remote OpenAI tier (via the
            // already-deployed, already end-to-end-tested proxy Worker)
            // is tried between the two. `PersonalAIProviderComposition`
            // owns the actual tier-building logic — this call site never
            // needs to change again for a future capable tier.
            modelProvider: FallbackPersonalAIModelProvider(tiers: PersonalAIProviderComposition.tiers(
                appleProvider: OnDevicePersonalAIModelProvider(),
                remoteEnabled: PersonalAIRemoteDevFlag.isEnabled,
                remoteAuth: PersonalAIRemoteDevFlag.auth,
                remoteTransport: PersonalAIRemoteDevFlag.transport,
                heuristicProvider: HeuristicPersonalAIModelProvider()
            )),
            dataStore: dataStore,
            syncEngine: syncEngine,
            backupCoordinator: backupCoordinator,
            restoreCoordinator: restoreCoordinator,
            cloudService: cloudService,
            cloudEnvironment: environment,
            keyStore: keyStore,
            ownerBox: ownerBox
        )
    }

    @MainActor
    func makeService() -> PersonalAIService {
        PersonalAIService(
            store: memoryStore,
            contextBuilder: contextBuilder,
            modelProvider: modelProvider,
            conversationStore: conversationStore,
            cloud: PersonalAICloudBundle(
                dataStore: dataStore,
                syncEngine: syncEngine,
                backupCoordinator: backupCoordinator,
                restoreCoordinator: restoreCoordinator,
                cloudService: cloudService,
                environment: cloudEnvironment,
                keyStore: keyStore,
                ownerBox: ownerBox
            )
        )
    }
}

/// The Phase 2 cloud dependencies handed to `PersonalAIService` as one
/// group, so its Phase 1 initializer stays unchanged for tests that don't
/// exercise the cloud. `cloudService == nil` ⇒ no external provider; local
/// backup/export/encryption still work.
struct PersonalAICloudBundle: Sendable {
    var dataStore: any PersonalDataStore
    var syncEngine: PersonalAISyncEngine
    var backupCoordinator: PersonalAIBackupCoordinator
    var restoreCoordinator: PersonalAICloudRestoreCoordinator
    var cloudService: (any PersonalCloudService)?
    var environment: PersonalCloudEnvironment
    var keyStore: SymmetricKeyStore
    var ownerBox: PersonalOwnerBox

    func cloudDeleteAllData(ownerID: String) async throws {
        try await cloudService?.deleteAllData(ownerID: ownerID)
    }
}
