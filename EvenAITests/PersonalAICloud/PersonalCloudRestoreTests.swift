import Testing
import Foundation
@testable import EvenAI

@MainActor
@Suite("Personal AI Cloud: recovery scenarios")
struct PersonalCloudRestoreTests {

    /// Seed a "cloud" (shared backend) with a full Personal AI from a first
    /// device, then return a shared backend other devices can restore from.
    private func seededCloud(ownerID: String) async -> InMemoryPersonalCloudBackend {
        let backend = InMemoryPersonalCloudBackend()
        let device1 = await PersonalCloudHarness(ownerID: ownerID, sharedBackend: backend)
        await device1.memoryStore.upsert([
            MemoryRecord(category: .projects, canonicalContent: "Building EvenAI for Even G2 smart glasses.", entities: ["evenai", "g2"]),
            MemoryRecord(category: .people, canonicalContent: "Andrii is my co-founder."),
            MemoryRecord(category: .profile, canonicalContent: "I live in Kyiv."),
        ])
        await device1.memoryStore.upsertRule(Rule(text: "Keep business replies short."))
        var style = await device1.memoryStore.styleProfile()
        style.preferredLanguage = "uk"; style.responseLength = .short; style.updatedAt = Date()
        await device1.memoryStore.updateStyleProfile(style)
        let convID = await device1.conversationStore.currentConversationID()
        await device1.conversationStore.append(PersonalAIChatMessage(role: .user, text: "How's EvenAI going?"), conversationID: convID)
        await device1.conversationStore.append(PersonalAIChatMessage(role: .assistant, text: "Making progress on retrieval."), conversationID: convID)
        _ = await device1.syncEngine.sync()
        return backend
    }

    // MARK: §30.3 / §12 — new iPhone restore from cloud

    @Test("a completely new device with no local data reconstructs the whole Personal AI from the cloud")
    func newIPhoneRestore() async {
        let backend = await seededCloud(ownerID: "traveler")
        let newDevice = await PersonalCloudHarness(ownerID: "traveler", sharedBackend: backend)

        // Nothing local yet.
        #expect((await newDevice.memoryStore.allMemories()).isEmpty)

        let outcome = await newDevice.restoreCoordinator.restore(ownerID: "traveler")
        #expect(outcome.succeeded)
        #expect(outcome.source == .cloud)

        let mems = await newDevice.memoryStore.allMemories()
        #expect(mems.contains { $0.canonicalContent.contains("EvenAI") })
        #expect(mems.contains { $0.canonicalContent.contains("Andrii") })
        #expect(mems.contains { $0.canonicalContent.contains("Kyiv") })
        #expect((await newDevice.memoryStore.allRules()).contains { $0.text.contains("short") })
        #expect((await newDevice.memoryStore.styleProfile()).preferredLanguage == "uk")
        #expect((await newDevice.conversationStore.allMessages()).count == 2)
    }

    // MARK: §30.1 / §13 — app delete / reinstall

    @Test("after app delete + reinstall + sign-in, PersonalAIService.open() restores everything")
    func reinstallRestoreViaService() async {
        let backend = await seededCloud(ownerID: "user-9")
        let fresh = await PersonalCloudHarness(ownerID: "user-9", sharedBackend: backend)
        await fresh.dataStore.updateSyncState { $0.needsCloudRestore = true }

        let service = fresh.makeService()
        await service.setCloudSyncEnabled(true)
        await service.open()

        #expect((await fresh.memoryStore.allMemories()).contains { $0.canonicalContent.contains("EvenAI") })
        #expect(service.messages.count == 2)
    }

    // MARK: §30.32 — restored memory is usable by the context builder

    @Test("after a cloud restore, PersonalAIContextBuilder uses the restored project memory")
    func restoredMemoryDrivesContext() async {
        let backend = await seededCloud(ownerID: "u32")
        let device = await PersonalCloudHarness(ownerID: "u32", sharedBackend: backend)
        _ = await device.restoreCoordinator.restore(ownerID: "u32")

        let builder = DefaultPersonalAIContextBuilder(store: device.memoryStore)
        let context = await builder.buildContext(PersonalAIContextRequest(
            surface: .personalChat,
            userMessage: "Any updates on the EvenAI retrieval work?"
        ))
        #expect(context.systemPromptText.localizedCaseInsensitiveContains("EvenAI"))
        #expect(context.hasPersonalization)
    }

    // MARK: §19.D / disaster: cloud unavailable → fall back to local backup

    @Test("restore falls back to the newest independent backup when the cloud snapshot is unavailable")
    func restoreFallsBackToBackup() async {
        let harness = await PersonalCloudHarness(ownerID: "dr-user")
        await harness.memoryStore.upsert([MemoryRecord.fixture("important local memory")])
        let backup = await harness.backupCoordinator.backup(tier: .daily)
        #expect(backup.succeeded)

        // Simulate: local wiped, cloud unreachable.
        await harness.memoryStore.replaceAll(with: .empty)
        harness.control.behavior = .offline

        let outcome = await harness.restoreCoordinator.restore(ownerID: "dr-user")
        #expect(outcome.succeeded)
        #expect(outcome.source == .backup)
        #expect((await harness.memoryStore.allMemories()).contains { $0.canonicalContent.contains("important local memory") })
    }

    // MARK: §30.2 — local cache survives relaunch (production encrypted store)

    @Test("the encrypted local cache round-trips memories, rules, style and conversations across a relaunch")
    func encryptedCacheSurvivesRelaunch() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PA-relaunch-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let keyStore = InMemorySymmetricKeyStore()
        let fileStore = EncryptedDocumentFile(keyStore: keyStore)

        do {
            let mem = LocalPersonalMemoryStore(directory: dir, fileStore: fileStore)
            let conv = LocalPersonalAIConversationStore(directory: dir, fileStore: fileStore)
            await mem.upsert([MemoryRecord(category: .profile, canonicalContent: "I live in Lviv.")])
            await mem.upsertRule(Rule(text: "Be direct."))
            var style = await mem.styleProfile(); style.preferredLanguage = "uk"; await mem.updateStyleProfile(style)
            let id = await conv.currentConversationID()
            await conv.append(PersonalAIChatMessage(role: .user, text: "remembered across relaunch"), conversationID: id)
        }

        // On-disk bytes must be encrypted (not plain JSON).
        let memFile = dir.appendingPathComponent("personal-memory.json")
        let raw = try! Data(contentsOf: memFile)
        #expect(String(data: raw, encoding: .utf8)?.contains("Lviv") != true)

        let mem2 = LocalPersonalMemoryStore(directory: dir, fileStore: fileStore)
        let conv2 = LocalPersonalAIConversationStore(directory: dir, fileStore: fileStore)
        #expect((await mem2.allMemories()).contains { $0.canonicalContent.contains("Lviv") })
        #expect((await mem2.allRules()).contains { $0.text.contains("direct") })
        #expect((await mem2.styleProfile()).preferredLanguage == "uk")
        #expect((await conv2.allMessages()).contains { $0.text.contains("relaunch") })
    }
}
