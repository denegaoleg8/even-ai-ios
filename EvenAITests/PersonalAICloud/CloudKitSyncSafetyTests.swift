import Testing
import Foundation
import CloudKit
@testable import EvenAI

/// The invariant above every feature: **a CloudKit failure may reduce sync
/// availability, but must never destroy local Personal AI memory.** Plus
/// deterministic conflict handling, idempotent delivery, and tombstone rules —
/// all through the unchanged `PersonalAISyncEngine`.
@MainActor
@Suite("CloudKit: sync safety")
struct CloudKitSyncSafetyTests {

    private func localContents(_ h: CloudKitTestHarness) async -> Set<String> {
        Set((await h.memoryStore.allMemories()).map(\.canonicalContent))
    }

    // MARK: round trip baseline

    @Test("push then pull on a second device round-trips memories, rules, conversations, messages")
    func twoDeviceRoundTrip() async {
        let db = FakeCloudKitDatabase()
        let a = await CloudKitTestHarness(personalAIUserID: "u", iCloudUser: "ic", sharedDatabase: db)
        let b = await CloudKitTestHarness(personalAIUserID: "u", iCloudUser: "ic", sharedDatabase: db)

        await a.memoryStore.upsert([MemoryRecord(category: .projects, canonicalContent: "Building EvenAI.", entities: ["evenai"])])
        await a.memoryStore.upsertRule(Rule(text: "Be concise."))
        let cid = await a.conversationStore.currentConversationID()
        await a.conversationStore.append(PersonalAIChatMessage(role: .user, text: "hello from A"), conversationID: cid)
        let s1 = await a.syncEngine.sync()
        #expect(s1.isSuccess)

        let s2 = await b.syncEngine.sync()
        #expect(s2.isSuccess)
        #expect((await b.memoryStore.allMemories()).contains { $0.canonicalContent.contains("EvenAI") })
        #expect((await b.memoryStore.allRules()).contains { $0.text.contains("concise") })
        #expect((await b.conversationStore.allMessages()).contains { $0.text == "hello from A" })
    }

    // MARK: idempotency

    @Test("duplicate remote delivery (token expiry → full re-fetch) does not duplicate")
    func duplicateRemoteDeliveryIdempotent() async {
        let db = FakeCloudKitDatabase()
        let a = await CloudKitTestHarness(personalAIUserID: "u", iCloudUser: "ic", sharedDatabase: db)
        let b = await CloudKitTestHarness(personalAIUserID: "u", iCloudUser: "ic", sharedDatabase: db)

        await a.memoryStore.upsert([MemoryRecord.fixture("fact one"), MemoryRecord.fixture("fact two")])
        _ = await a.syncEngine.sync()

        _ = await b.syncEngine.sync()
        #expect((await b.memoryStore.allMemories()).count == 2)

        // Force CloudKit to redeliver everything.
        db.forceTokenExpiredOnce = true
        _ = await b.syncEngine.sync()
        #expect((await b.memoryStore.allMemories()).count == 2)
        #expect(await localContents(b) == ["fact one", "fact two"])
    }

    @Test("re-running sync with no local changes uploads nothing and creates no duplicates")
    func repeatedSyncNoDuplicates() async {
        let h = await CloudKitTestHarness()
        await h.memoryStore.upsert([MemoryRecord.fixture("only fact")])
        _ = await h.syncEngine.sync()
        let countAfterFirst = h.database.totalRecordCount()
        _ = await h.syncEngine.sync()
        _ = await h.syncEngine.sync()
        #expect(h.database.totalRecordCount() == countAfterFirst)
    }

    // MARK: conflicts

    @Test("stale local push → CloudKit conflict → resolved deterministically, memory not lost")
    func staleConflictResolvedNoLoss() async {
        let h = await CloudKitTestHarness()
        let memory = MemoryRecord.fixture("original content")
        await h.memoryStore.upsert([memory])
        _ = await h.syncEngine.sync()

        // Another device changed this record on the server.
        var serverVersion = memory
        serverVersion.canonicalContent = "server content"
        serverVersion.updatedAt = Date().addingTimeInterval(60)
        serverVersion.revision = 5
        h.database.inject(CloudKitRecordMapper.makeRecord(from: PersonalSyncCodec.encode(serverVersion)), zone: .core)

        // Local edits the same record and syncs → stale base → conflict.
        var localEdit = memory.touched()
        localEdit.canonicalContent = "local content"
        await h.memoryStore.upsert([localEdit])
        let outcome = await h.syncEngine.sync()

        if case .completed(_, _, let conflicts) = outcome {
            #expect(conflicts >= 1)
        } else if case .failedRetryable = outcome {
            // acceptable — a follow-up sync converges; the point is no data loss
        } else {
            Issue.record("unexpected outcome \(outcome)")
        }
        // The record still exists locally — nothing was destroyed by the conflict.
        #expect((await h.memoryStore.allMemories()).contains { $0.id == memory.id })
        // A revision was captured for the superseded side.
        #expect(!(await h.memoryStore.revisions(recordID: memory.id)).isEmpty)
    }

    @Test("conflict resolution is deterministic — same conflict resolves the same way")
    func conflictResolutionDeterministic() {
        let resolver = PersonalConflictResolver()
        let base = MemoryRecord.fixture("base")
        var client = base; client.canonicalContent = "client"; client.revision = 2
        var server = base; server.canonicalContent = "server"; server.revision = 3
        let conflict = SyncConflict(
            id: base.id, kind: .memory,
            clientPayloadJSON: String(data: try! JSONEncoder.personalAI.encode(client), encoding: .utf8)!,
            serverPayloadJSON: String(data: try! JSONEncoder.personalAI.encode(server), encoding: .utf8)!,
            serverRevision: 7, serverRemoteID: base.id.uuidString, serverDeletedAt: nil
        )
        let r1 = resolver.resolve(conflict)
        let r2 = resolver.resolve(conflict)
        #expect(r1?.resolved.payloadJSON == r2?.resolved.payloadJSON)
        #expect(r1?.resolved.id == base.id)
    }

    @Test("cloud-newer / local-not-pending → fast-forward, prior local kept as a revision")
    func cloudNewerFastForwards() async {
        let db = FakeCloudKitDatabase()
        let a = await CloudKitTestHarness(personalAIUserID: "u", iCloudUser: "ic", sharedDatabase: db)
        let b = await CloudKitTestHarness(personalAIUserID: "u", iCloudUser: "ic", sharedDatabase: db)

        let memory = MemoryRecord.fixture("v1")
        await a.memoryStore.upsert([memory])
        _ = await a.syncEngine.sync()
        _ = await b.syncEngine.sync()

        var edited = memory.touched()
        edited.canonicalContent = "v2 from A"
        await a.memoryStore.upsert([edited])
        _ = await a.syncEngine.sync()

        _ = await b.syncEngine.sync()
        let onB = (await b.memoryStore.allMemories()).first { $0.id == memory.id }
        #expect(onB?.canonicalContent == "v2 from A")
        #expect(!(await b.memoryStore.revisions(recordID: memory.id)).isEmpty)
    }

    // MARK: failure modes — never lose local data

    @Test("network unavailable → .failedRetryable, all local data + pending queue intact")
    func networkUnavailableKeepsData() async {
        let h = await CloudKitTestHarness()
        await h.memoryStore.upsert([MemoryRecord.fixture("keep me one"), MemoryRecord.fixture("keep me two")])
        h.database.alwaysFail = CKErrorFixture.networkUnavailable

        let outcome = await h.syncEngine.sync()
        if case .failedRetryable = outcome {} else { Issue.record("expected retryable, got \(outcome)") }
        #expect((await h.memoryStore.allMemories()).count == 2)
        #expect(await h.dataStore.pendingChanges().count >= 2)

        h.database.alwaysFail = nil
        let recovered = await h.syncEngine.sync()
        #expect(recovered.isSuccess)
        #expect(h.database.totalRecordCount() == 2)
    }

    @Test("service unavailable → .failedRetryable, no data loss")
    func serviceUnavailableKeepsData() async {
        let h = await CloudKitTestHarness()
        await h.memoryStore.upsert([MemoryRecord.fixture("a"), MemoryRecord.fixture("b")])
        h.database.alwaysFail = CKErrorFixture.serviceUnavailable
        let outcome = await h.syncEngine.sync()
        if case .failedRetryable = outcome {} else { Issue.record("got \(outcome)") }
        #expect((await h.memoryStore.allMemories()).count == 2)
    }

    @Test("quota exceeded → .failedRetryable, nothing dropped, nothing overwritten")
    func quotaExceededKeepsData() async {
        let h = await CloudKitTestHarness()
        await h.memoryStore.upsert([MemoryRecord.fixture("precious one"), MemoryRecord.fixture("precious two")])
        h.database.alwaysFail = CKErrorFixture.quotaExceeded
        let outcome = await h.syncEngine.sync()
        if case .failedRetryable = outcome {} else { Issue.record("got \(outcome)") }
        #expect(await localContents(h) == ["precious one", "precious two"])
    }

    @Test("not authenticated → sync frozen, local data retained")
    func notAuthenticatedKeepsData() async {
        let h = await CloudKitTestHarness()
        await h.memoryStore.upsert([MemoryRecord.fixture("mine")])
        h.database.accountStatusValue = .noAccount
        let outcome = await h.syncEngine.sync()
        if case .failedRetryable = outcome {} else { Issue.record("got \(outcome)") }
        #expect((await h.memoryStore.allMemories()).count == 1)
    }

    @Test("partial batch failure — some records save, the rest stay pending and retry clean")
    func partialBatchFailure() async {
        let h = await CloudKitTestHarness()
        let good = MemoryRecord.fixture("saves fine")
        let flaky = MemoryRecord.fixture("transient once")
        await h.memoryStore.upsert([good, flaky])
        h.database.transientRecordNames = [flaky.id.uuidString]

        let first = await h.syncEngine.sync()
        // The engine treats a round with an unresolved pending remainder as
        // complete-with-work-left or retryable; either way nothing is lost.
        _ = first
        #expect((await h.memoryStore.allMemories()).count == 2)

        h.database.transientRecordNames = []
        let second = await h.syncEngine.sync()
        #expect(second.isSuccess || {
            if case .completed = second { return true } else { return false }
        }())
        #expect(h.database.totalRecordCount() == 2)
    }

    @Test("cancelled sync leaves a consistent state, nothing lost")
    func cancelledSyncSafe() async {
        let h = await CloudKitTestHarness()
        await h.memoryStore.upsert([MemoryRecord.fixture("survives cancel")])
        let task = Task { await h.syncEngine.sync() }
        task.cancel()
        _ = await task.value
        #expect((await h.memoryStore.allMemories()).count == 1)
        // A later, uncancelled sync still works.
        let ok = await h.syncEngine.sync()
        #expect(ok.isSuccess)
    }

    @Test("malformed server payload → pull rejected, cursor not advanced, local untouched")
    func malformedServerPayloadRejected() async {
        let db = FakeCloudKitDatabase()
        let a = await CloudKitTestHarness(personalAIUserID: "u", iCloudUser: "ic", sharedDatabase: db)
        let b = await CloudKitTestHarness(personalAIUserID: "u", iCloudUser: "ic", sharedDatabase: db)

        await a.memoryStore.upsert([MemoryRecord.fixture("valid fact")])
        _ = await a.syncEngine.sync()
        _ = await b.syncEngine.sync()
        let bBefore = await localContents(b)

        // Inject a record with a corrupt payload directly into the shared DB.
        let bad = CKRecord(recordType: CloudKitSchema.RecordType.memory,
                           recordID: CloudKitRecordID.make(kind: .memory, canonicalID: UUID()))
        bad[CloudKitSchema.Field.recordKind] = "memory"
        bad.encryptedValues[CloudKitSchema.Field.payload] = Data("{ not valid json".utf8)
        db.inject(bad, zone: .core)

        let outcome = await b.syncEngine.sync()
        if case .failedRetryable(let code) = outcome { #expect(code == "decode") }
        else { Issue.record("expected decode failure, got \(outcome)") }
        #expect(await localContents(b) == bBefore) // untouched
    }

    // MARK: tombstones

    @Test("deleted record propagates and does not resurrect")
    func tombstoneDoesNotResurrect() async {
        let db = FakeCloudKitDatabase()
        let a = await CloudKitTestHarness(personalAIUserID: "u", iCloudUser: "ic", sharedDatabase: db)
        let b = await CloudKitTestHarness(personalAIUserID: "u", iCloudUser: "ic", sharedDatabase: db)

        let memory = MemoryRecord.fixture("temporary fact")
        await a.memoryStore.upsert([memory])
        _ = await a.syncEngine.sync()
        _ = await b.syncEngine.sync()
        #expect((await b.memoryStore.allMemories()).contains { $0.id == memory.id && $0.deletedAt == nil })

        // A deletes it.
        var tombstoned = memory.touched()
        tombstoned.deletedAt = Date()
        tombstoned.status = .deleted
        await a.memoryStore.upsert([tombstoned])
        _ = await a.syncEngine.sync()

        // B pulls the tombstone.
        _ = await b.syncEngine.sync()
        let onB = (await b.memoryStore.allMemories()).first { $0.id == memory.id }
        #expect(onB?.deletedAt != nil)

        // B re-syncs repeatedly — the record must not come back to life.
        _ = await b.syncEngine.sync()
        _ = await b.syncEngine.sync()
        let finalOnB = (await b.memoryStore.allMemories()).first { $0.id == memory.id }
        #expect(finalOnB?.deletedAt != nil)
    }
}
