import Foundation
@testable import EvenAI

/// Wires `CloudKitPersonalCloudService` (over `FakeCloudKitDatabase`) to a
/// real `LocalPersonalDataStore` + `PersonalAISyncEngine`, so the CloudKit
/// adapter is exercised through the exact same, unchanged sync engine the
/// production app uses. No network, no `CKContainer`.
@MainActor
struct CloudKitTestHarness {
    let database: FakeCloudKitDatabase
    let stateStore: InMemoryCloudKitAdapterStateStore
    let service: CloudKitPersonalCloudService
    let ownerBox: PersonalOwnerBox
    let memoryStore: InMemoryPersonalMemoryStore
    let conversationStore: InMemoryPersonalAIConversationStore
    let dataStore: LocalPersonalDataStore
    let syncEngine: PersonalAISyncEngine
    let restoreCoordinator: PersonalAICloudRestoreCoordinator

    let adapterStateFileURL: URL?

    init(
        personalAIUserID: String = "user-A",
        iCloudUser: String = "icloud-user-A",
        pageLimit: Int = 200,
        pageSize: Int = 50,
        cloudSyncEnabled: Bool = true,
        sharedDatabase: FakeCloudKitDatabase? = nil,
        adapterStateFileURL: URL? = nil
    ) async {
        self.database = sharedDatabase ?? FakeCloudKitDatabase()
        self.database.userRecordNameValue = iCloudUser
        self.database.pageSize = pageSize
        self.stateStore = InMemoryCloudKitAdapterStateStore()
        self.adapterStateFileURL = adapterStateFileURL
        self.ownerBox = PersonalOwnerBox(ownerID: personalAIUserID)
        let box = ownerBox

        if let adapterStateFileURL {
            self.service = CloudKitPersonalCloudService(
                database: database,
                stateStore: FileCloudKitAdapterStateStore(url: adapterStateFileURL, file: PlaintextDocumentFile()),
                personalAIUserID: { box.ownerID },
                pageLimit: pageLimit
            )
        } else {
            self.service = CloudKitPersonalCloudService(
                database: database,
                stateStore: stateStore,
                personalAIUserID: { box.ownerID },
                pageLimit: pageLimit
            )
        }
        self.memoryStore = InMemoryPersonalMemoryStore()
        self.conversationStore = InMemoryPersonalAIConversationStore()
        self.dataStore = LocalPersonalDataStore(
            memory: memoryStore,
            conversations: conversationStore,
            ownerID: { box.ownerID }
        )
        self.syncEngine = PersonalAISyncEngine(
            dataStore: dataStore,
            cloudService: service,
            ownerID: { box.ownerID },
            memoryEnabled: { [memoryStore] in await memoryStore.isMemoryEnabledGlobally() },
            deviceID: "ck-test-\(UUID().uuidString)"
        )
        self.restoreCoordinator = PersonalAICloudRestoreCoordinator(
            dataStore: dataStore,
            cloudService: service
        )

        await dataStore.updateSyncState { $0.cloudSyncEnabled = cloudSyncEnabled }
    }

    func snapshotLocalMemoryContents() async -> Set<String> {
        Set((await memoryStore.allMemories()).map(\.canonicalContent))
    }
}
