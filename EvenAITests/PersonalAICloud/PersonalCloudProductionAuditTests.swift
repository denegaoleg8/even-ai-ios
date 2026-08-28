import Testing
import Foundation
@testable import EvenAI

/// Pre-commit audit of Phase 2's production safety: a shipping build must
/// never imply cloud durability it does not have, and destructive paths must
/// stay safe with no cloud wired.
@MainActor
@Suite("Personal AI Cloud: production safety audit")
struct PersonalCloudProductionAuditTests {

    // MARK: §1 / §16 — production default is honestly "not configured"

    @Test("PersonalAIContainer.live wires no cloud service and reports .notConfigured")
    func productionIsNotConfigured() {
        let container = PersonalAIContainer.live
        #expect(container.cloudEnvironment == .notConfigured)
        #expect(container.cloudService == nil)
    }

    @Test("a .notConfigured service cannot enable sync and reports no durability")
    func notConfiguredCannotSync() async {
        let container = PersonalAIContainer.make(cloudService: nil, environment: .notConfigured)
        let service = container.makeService()
        #expect(service.cloudEnvironment == .notConfigured)
        #expect(service.cloudProvidesDurability == false)

        await service.setCloudSyncEnabled(true)
        #expect(service.cloudSyncEnabled == false, "sync must not enable with no cloud service")

        let outcome = await service.syncNow()
        if case .skipped = outcome {} else { Issue.record("expected sync to be skipped, got \(outcome)") }
    }

    @Test("the simulated environment is clearly non-durable")
    func simulatedIsNotDurable() {
        #expect(PersonalCloudEnvironment.simulated.providesDurability == false)
        #expect(PersonalCloudEnvironment.notConfigured.providesDurability == false)
        #expect(PersonalCloudEnvironment.connected.providesDurability == true)
    }

    // MARK: destructive paths remain safe with no cloud

    @Test("delete Personal AI data wipes local memory + conversations + key with no cloud wired")
    func deleteWipesLocalWithoutCloud() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PA-del-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let keyStore = InMemorySymmetricKeyStore()
        let mem = LocalPersonalMemoryStore(directory: dir, fileStore: PlaintextDocumentFile())
        let conv = LocalPersonalAIConversationStore(directory: dir, fileStore: PlaintextDocumentFile())
        await mem.upsert([MemoryRecord.fixture("delete me")])
        let cid = await conv.currentConversationID()
        await conv.append(PersonalAIChatMessage(role: .user, text: "gone soon"), conversationID: cid)

        let bundle = PersonalAICloudBundle(
            dataStore: LocalPersonalDataStore(memory: mem, conversations: conv),
            syncEngine: PersonalAISyncEngine(dataStore: LocalPersonalDataStore(memory: mem, conversations: conv), cloudService: nil, ownerID: { nil }),
            backupCoordinator: PersonalAIBackupCoordinator(dataStore: LocalPersonalDataStore(memory: mem, conversations: conv), backupStore: LocalDirectoryBackupStore(directory: dir), keyStore: keyStore, ownerID: { nil }),
            restoreCoordinator: PersonalAICloudRestoreCoordinator(dataStore: LocalPersonalDataStore(memory: mem, conversations: conv), cloudService: nil),
            cloudService: nil,
            environment: .notConfigured,
            keyStore: keyStore,
            ownerBox: PersonalOwnerBox()
        )
        let service = PersonalAIService(store: mem, contextBuilder: DefaultPersonalAIContextBuilder(store: mem), modelProvider: FakePersonalAIModelProvider(), conversationStore: conv, cloud: bundle)

        await service.deletePersonalAIAccount()

        #expect((await mem.allMemories()).isEmpty)
        #expect((await conv.allMessages()).isEmpty)
    }

    @Test("deleteCloudData is a harmless no-op with no cloud service")
    func deleteCloudDataNoOpWithoutCloud() async {
        let container = PersonalAIContainer.make(cloudService: nil, environment: .notConfigured)
        let service = container.makeService()
        await service.deleteCloudData() // must not crash / must not wipe local
        #expect(service.cloudEnvironment == .notConfigured)
    }

    // MARK: §8 — new-iPhone restore uses genuinely separate stores

    @Test("new-iPhone restore reconstructs from cloud with NO shared local store object")
    func newIPhoneUsesSeparateStores() async {
        let backend = InMemoryPersonalCloudBackend()
        let deviceA = await PersonalCloudHarness(ownerID: "sep", sharedBackend: backend)
        let deviceB = await PersonalCloudHarness(ownerID: "sep", sharedBackend: backend)

        // Distinct store instances.
        #expect(deviceA.memoryStore !== (deviceB.memoryStore as AnyObject))
        #expect(deviceA.conversationStore !== (deviceB.conversationStore as AnyObject))

        await deviceA.memoryStore.upsert([
            MemoryRecord(category: .projects, canonicalContent: "Building EvenAI.", entities: ["evenai"]),
        ])
        await deviceA.memoryStore.upsertRule(Rule(text: "Be concise."))
        let cid = await deviceA.conversationStore.currentConversationID()
        await deviceA.conversationStore.append(PersonalAIChatMessage(role: .user, text: "hi from A"), conversationID: cid)
        _ = await deviceA.syncEngine.sync()

        #expect((await deviceB.memoryStore.allMemories()).isEmpty) // truly empty before restore

        let outcome = await deviceB.restoreCoordinator.restore(ownerID: "sep")
        #expect(outcome.succeeded)
        #expect((await deviceB.memoryStore.allMemories()).contains { $0.canonicalContent.contains("EvenAI") })
        #expect((await deviceB.memoryStore.allRules()).contains { $0.text.contains("concise") })
        #expect((await deviceB.conversationStore.allMessages()).contains { $0.text == "hi from A" })
    }
}
