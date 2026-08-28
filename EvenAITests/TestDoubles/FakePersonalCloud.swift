import Foundation
@testable import EvenAI

/// Everything a Personal AI Cloud test needs, wired against the in-process
/// `InMemoryPersonalCloudBackend`. No network, no files unless a test asks
/// for a temp dir.
@MainActor
struct PersonalCloudHarness {
    let backend: InMemoryPersonalCloudBackend
    let cloudService: MockPersonalCloudService
    let control: MockPersonalCloudService.Control
    let keyStore: InMemorySymmetricKeyStore
    let ownerBox: PersonalOwnerBox
    let memoryStore: InMemoryPersonalMemoryStore
    let conversationStore: InMemoryPersonalAIConversationStore
    let dataStore: LocalPersonalDataStore
    let syncEngine: PersonalAISyncEngine
    let backupStore: LocalDirectoryBackupStore
    let backupCoordinator: PersonalAIBackupCoordinator
    let restoreCoordinator: PersonalAICloudRestoreCoordinator

    init(
        ownerID: String = "owner-A",
        cloudSyncEnabled: Bool = true,
        pageSize: Int = 50,
        backupDirectory: URL? = nil,
        sharedBackend: InMemoryPersonalCloudBackend? = nil
    ) async {
        self.backend = sharedBackend ?? InMemoryPersonalCloudBackend(pageSize: pageSize)
        self.control = MockPersonalCloudService.Control()
        self.cloudService = MockPersonalCloudService(backend: backend, control: control)
        self.keyStore = InMemorySymmetricKeyStore()
        self.ownerBox = PersonalOwnerBox(ownerID: ownerID)
        self.memoryStore = InMemoryPersonalMemoryStore()
        self.conversationStore = InMemoryPersonalAIConversationStore()

        let box = ownerBox
        self.dataStore = LocalPersonalDataStore(
            memory: memoryStore,
            conversations: conversationStore,
            ownerID: { box.ownerID }
        )
        self.syncEngine = PersonalAISyncEngine(
            dataStore: dataStore,
            cloudService: cloudService,
            ownerID: { box.ownerID },
            memoryEnabled: { [memoryStore] in await memoryStore.isMemoryEnabledGlobally() },
            deviceID: "test-device-\(UUID().uuidString)"
        )
        self.backupStore = LocalDirectoryBackupStore(directory: backupDirectory ?? Self.tempDir())
        self.backupCoordinator = PersonalAIBackupCoordinator(
            dataStore: dataStore,
            backupStore: backupStore,
            keyStore: keyStore,
            ownerID: { box.ownerID }
        )
        self.restoreCoordinator = PersonalAICloudRestoreCoordinator(
            dataStore: dataStore,
            cloudService: cloudService,
            backupCoordinator: backupCoordinator
        )

        await dataStore.updateSyncState { $0.cloudSyncEnabled = cloudSyncEnabled }
    }

    static func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PA-cloud-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func cloudBundle(environment: PersonalCloudEnvironment = .simulated, includeCloudService: Bool = true) -> PersonalAICloudBundle {
        PersonalAICloudBundle(
            dataStore: dataStore,
            syncEngine: syncEngine,
            backupCoordinator: backupCoordinator,
            restoreCoordinator: restoreCoordinator,
            cloudService: includeCloudService ? cloudService : nil,
            environment: environment,
            keyStore: keyStore,
            ownerBox: ownerBox
        )
    }

    /// A `PersonalAIService` wired to this harness.
    func makeService(model: any PersonalAIModelProviding = FakePersonalAIModelProvider(reply: "ok")) -> PersonalAIService {
        PersonalAIService(
            store: memoryStore,
            contextBuilder: DefaultPersonalAIContextBuilder(store: memoryStore),
            modelProvider: model,
            conversationStore: conversationStore,
            cloud: cloudBundle()
        )
    }
}

extension MemoryRecord {
    static func fixture(_ content: String, category: MemoryCategory = .knowledge, owner: String? = nil) -> MemoryRecord {
        MemoryRecord(ownerID: owner, category: category, canonicalContent: content, confidence: 0.9, userConfirmed: true)
    }
}
