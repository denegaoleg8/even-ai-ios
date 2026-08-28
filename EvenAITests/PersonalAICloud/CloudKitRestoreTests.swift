import Testing
import Foundation
import CloudKit
@testable import EvenAI

/// Fresh-device / disaster-recovery restore through `snapshot()` +
/// `PersonalAICloudRestoreCoordinator` + `PersonalDataImporter` — all
/// unchanged; the CloudKit adapter only supplies the bundle.
@MainActor
@Suite("CloudKit: restore")
struct CloudKitRestoreTests {

    private func seededSource() async -> (FakeCloudKitDatabase, CloudKitTestHarness) {
        let db = FakeCloudKitDatabase()
        let source = await CloudKitTestHarness(personalAIUserID: "u", iCloudUser: "ic", sharedDatabase: db)
        await source.memoryStore.upsert([
            MemoryRecord(category: .projects, canonicalContent: "Building EvenAI.", entities: ["evenai"]),
            MemoryRecord(category: .people, canonicalContent: "Nadia is the designer.", entities: ["nadia"]),
            MemoryRecord(category: .episodes, canonicalContent: "Shipped v1 in March.", entities: ["v1"]),
        ])
        await source.memoryStore.upsertRule(Rule(text: "Answer in Ukrainian when spoken to directly."))
        let cid = await source.conversationStore.currentConversationID()
        await source.conversationStore.append(PersonalAIChatMessage(role: .user, text: "how's the project"), conversationID: cid)
        await source.conversationStore.append(PersonalAIChatMessage(role: .assistant, text: "on track"), conversationID: cid)
        _ = await source.syncEngine.sync()
        return (db, source)
    }

    @Test("empty local store restores every canonical entity from the cloud")
    func fullRestore() async {
        let (db, _) = await seededSource()
        let fresh = await CloudKitTestHarness(personalAIUserID: "u", iCloudUser: "ic", sharedDatabase: db)
        #expect((await fresh.memoryStore.allMemories()).isEmpty)

        let outcome = await fresh.restoreCoordinator.restore(ownerID: "u")
        #expect(outcome.succeeded)
        #expect(outcome.source == .cloud)

        let contents = Set((await fresh.memoryStore.allMemories()).map(\.canonicalContent))
        #expect(contents.contains("Building EvenAI."))
        #expect(contents.contains("Nadia is the designer."))
        #expect(contents.contains("Shipped v1 in March."))
        #expect((await fresh.memoryStore.allRules()).contains { $0.text.contains("Ukrainian") })
        #expect((await fresh.conversationStore.allMessages()).count == 2)
    }

    @Test("stable IDs are preserved through restore")
    func stableIDsPreserved() async {
        let (db, source) = await seededSource()
        let sourceIDs = Set((await source.memoryStore.allMemories()).map(\.id))

        let fresh = await CloudKitTestHarness(personalAIUserID: "u", iCloudUser: "ic", sharedDatabase: db)
        _ = await fresh.restoreCoordinator.restore(ownerID: "u")
        let restoredIDs = Set((await fresh.memoryStore.allMemories()).map(\.id))
        #expect(restoredIDs == sourceIDs)
    }

    @Test("repeated restore is idempotent — no duplicates")
    func repeatedRestoreIdempotent() async {
        let (db, _) = await seededSource()
        let fresh = await CloudKitTestHarness(personalAIUserID: "u", iCloudUser: "ic", sharedDatabase: db)

        _ = await fresh.restoreCoordinator.restore(ownerID: "u")
        let firstCount = (await fresh.memoryStore.allMemories()).count
        _ = await fresh.restoreCoordinator.restore(ownerID: "u")
        _ = await fresh.restoreCoordinator.restore(ownerID: "u")
        #expect((await fresh.memoryStore.allMemories()).count == firstCount)
    }

    @Test("tombstones in the cloud are respected on restore and stay deleted")
    func tombstonesRespectedOnRestore() async {
        let db = FakeCloudKitDatabase()
        let source = await CloudKitTestHarness(personalAIUserID: "u", iCloudUser: "ic", sharedDatabase: db)
        let keep = MemoryRecord.fixture("keep this")
        let remove = MemoryRecord.fixture("remove this")
        await source.memoryStore.upsert([keep, remove])
        _ = await source.syncEngine.sync()
        var deleted = remove.touched()
        deleted.deletedAt = Date(); deleted.status = .deleted
        await source.memoryStore.upsert([deleted])
        _ = await source.syncEngine.sync()

        let fresh = await CloudKitTestHarness(personalAIUserID: "u", iCloudUser: "ic", sharedDatabase: db)
        _ = await fresh.restoreCoordinator.restore(ownerID: "u")

        let active = (await fresh.memoryStore.allMemories()).filter { $0.deletedAt == nil }.map(\.canonicalContent)
        #expect(active.contains("keep this"))
        #expect(!active.contains("remove this"))
    }

    @Test("after restore, the first incremental sync fetches only genuinely new changes")
    func incrementalContinuationAfterRestore() async {
        let db = FakeCloudKitDatabase()
        let source = await CloudKitTestHarness(personalAIUserID: "u", iCloudUser: "ic", sharedDatabase: db)
        await source.memoryStore.upsert([MemoryRecord.fixture("before restore")])
        _ = await source.syncEngine.sync()

        let fresh = await CloudKitTestHarness(personalAIUserID: "u", iCloudUser: "ic", sharedDatabase: db)
        _ = await fresh.restoreCoordinator.restore(ownerID: "u")
        #expect((await fresh.memoryStore.allMemories()).count == 1)
        // The restore does NOT touch the local sync preference — the harness
        // enabled it and it stays enabled (see PersonalDataRestorePreferenceTests).

        // A new fact appears after the restore.
        await source.memoryStore.upsert([MemoryRecord.fixture("after restore")])
        _ = await source.syncEngine.sync()

        let outcome = await fresh.syncEngine.sync()
        #expect(outcome.isSuccess)
        #expect((await fresh.memoryStore.allMemories()).count == 2)
    }

    @Test("interrupted restore can be restarted safely — pagination + resumability")
    func interruptedRestoreRestarts() async {
        let db = FakeCloudKitDatabase()
        db.pageSize = 3
        let source = await CloudKitTestHarness(personalAIUserID: "u", iCloudUser: "ic", pageSize: 3, sharedDatabase: db)
        for i in 0..<25 {
            await source.memoryStore.upsert([MemoryRecord.fixture("fact \(i)")])
        }
        _ = await source.syncEngine.sync()

        let fresh = await CloudKitTestHarness(personalAIUserID: "u", iCloudUser: "ic", pageLimit: 3, pageSize: 3, sharedDatabase: db)
        // Restore twice — a re-run after an "interruption" must not duplicate
        // and must converge to the full set.
        _ = await fresh.restoreCoordinator.restore(ownerID: "u")
        _ = await fresh.restoreCoordinator.restore(ownerID: "u")
        #expect((await fresh.memoryStore.allMemories()).count == 25)
    }

    @Test("a large synthetic message history pages in without a whole-history rewrite")
    func largeChatHistoryPaginates() async {
        let db = FakeCloudKitDatabase()
        db.pageSize = 20
        let source = await CloudKitTestHarness(personalAIUserID: "u", iCloudUser: "ic", pageLimit: 20, pageSize: 20, sharedDatabase: db)
        let cid = await source.conversationStore.currentConversationID()
        for i in 0..<200 {
            await source.conversationStore.append(PersonalAIChatMessage(role: .user, text: "msg \(i)"), conversationID: cid)
        }
        let pushOutcome = await source.syncEngine.sync()
        #expect(pushOutcome.isSuccess)
        // Every message is an independent record — 200 messages, ≥200 records
        // in the chat zone, none of which required rewriting a conversation.
        #expect(db.liveRecordCount(zone: .chat) >= 200)

        let fresh = await CloudKitTestHarness(personalAIUserID: "u", iCloudUser: "ic", pageLimit: 20, pageSize: 20, sharedDatabase: db)
        _ = await fresh.restoreCoordinator.restore(ownerID: "u")
        #expect((await fresh.conversationStore.allMessages()).count == 200)
    }

    @Test("restore failure leaves prior local records untouched")
    func failedRestoreDoesNotWipe() async {
        let h = await CloudKitTestHarness()
        await h.memoryStore.upsert([MemoryRecord.fixture("do not lose me")])
        h.database.alwaysFail = CKErrorFixture.serviceUnavailable

        let outcome = await h.restoreCoordinator.restore(ownerID: "user-A")
        #expect(!outcome.succeeded)
        #expect((await h.memoryStore.allMemories()).contains { $0.canonicalContent == "do not lose me" })
    }
}
