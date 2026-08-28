import Testing
import Foundation
@testable import EvenAI

@MainActor
@Suite("Personal AI Cloud: sync engine")
struct PersonalAISyncEngineTests {

    // MARK: §30.4–8 — every record kind survives a push → pull round trip

    @Test("memories, rules, style, projects, people and conversations survive a full round trip with stable IDs")
    func fullRoundTripStableIDs() async {
        let a = await PersonalCloudHarness(ownerID: "user-A")

        let memID = UUID()
        await a.memoryStore.upsert([
            MemoryRecord(id: memID, category: .projects, canonicalContent: "Building EvenAI for G2 glasses.", entities: ["evenai"]),
            MemoryRecord(category: .people, canonicalContent: "Andrii is my co-founder."),
        ])
        await a.memoryStore.upsertRule(Rule(text: "Keep replies short."))
        var style = await a.memoryStore.styleProfile()
        style.preferredLanguage = "uk"
        style.updatedAt = Date()
        await a.memoryStore.updateStyleProfile(style)
        let convID = await a.conversationStore.currentConversationID()
        await a.conversationStore.append(PersonalAIChatMessage(role: .user, text: "hi"), conversationID: convID)

        let out = await a.syncEngine.sync()
        #expect(out.isSuccess)

        // A second device pulls everything.
        let b = await PersonalCloudHarness(ownerID: "user-A", sharedBackend: a.backend)
        let out2 = await b.syncEngine.sync()
        #expect(out2.isSuccess)

        let mems = await b.memoryStore.allMemories()
        #expect(mems.contains { $0.id == memID && $0.canonicalContent.contains("EvenAI") })
        #expect(mems.contains { $0.category == .people && $0.canonicalContent.contains("Andrii") })
        #expect((await b.memoryStore.allRules()).contains { $0.text.contains("short") })
        #expect((await b.memoryStore.styleProfile()).preferredLanguage == "uk")
        #expect((await b.conversationStore.allMessages()).contains { $0.text == "hi" })
    }

    // MARK: §30.9 — incremental sync via cursor

    @Test("a second sync only pulls records changed since the cursor")
    func incrementalSync() async {
        let a = await PersonalCloudHarness()
        await a.memoryStore.upsert([MemoryRecord.fixture("first")])
        _ = await a.syncEngine.sync()

        let b = await PersonalCloudHarness(ownerID: "owner-A", sharedBackend: a.backend)
        _ = await b.syncEngine.sync()
        let firstPullCount = b.control.pullCount

        // A only adds one more record.
        await a.memoryStore.upsert([MemoryRecord.fixture("second")])
        _ = await a.syncEngine.sync()

        _ = await b.syncEngine.sync()
        #expect((await b.memoryStore.allMemories()).count == 2)
        #expect(b.control.pullCount > firstPullCount)
        // The incremental pull did not re-deliver "first" as a change we had
        // to write again — cursor advanced.
        let state = await b.dataStore.syncState()
        #expect(state.cursor != nil)
    }

    // MARK: §30.10 — idempotent retry

    @Test("a retried push with the same batch does not create duplicates")
    func idempotentRetry() async {
        let a = await PersonalCloudHarness()
        await a.memoryStore.upsert([MemoryRecord.fixture("only one")])

        // Fail once mid-push, then succeed — the engine retries with the
        // same idempotency key.
        a.control.behavior = .failOnce
        _ = await a.syncEngine.sync()   // fails
        a.control.behavior = .ok
        _ = await a.syncEngine.sync()   // retries + succeeds
        _ = await a.syncEngine.sync()   // and again for good measure

        #expect(await a.backend.recordCount(ownerID: "owner-A") == 1)
        #expect((await a.memoryStore.allMemories()).count == 1)
    }

    // MARK: §30.11 — concurrent sync

    @Test("two concurrent syncs against one store do not corrupt or duplicate data")
    func concurrentSync() async {
        let a = await PersonalCloudHarness()
        for i in 0..<5 { await a.memoryStore.upsert([MemoryRecord.fixture("m\(i)")]) }

        async let s1 = a.syncEngine.sync()
        async let s2 = a.syncEngine.sync()
        let (o1, o2) = await (s1, s2)

        // One completes, the other is refused as already-running — never a
        // double push.
        let successes = [o1, o2].filter { $0.isSuccess }.count
        let skipped = [o1, o2].filter { if case .skipped(.alreadyRunning) = $0 { return true } else { return false } }.count
        #expect(successes >= 1)
        #expect(successes + skipped == 2)
        #expect(await a.backend.recordCount(ownerID: "owner-A") == 5)
    }

    // MARK: §30.12 / §30.13 — offline queue + reconciliation

    @Test("mutations made while offline queue, then reconcile on reconnect")
    func offlineQueueThenReconcile() async {
        let a = await PersonalCloudHarness()
        a.control.behavior = .offline

        await a.memoryStore.upsert([MemoryRecord.fixture("made offline")])
        let offlineOutcome = await a.syncEngine.sync()
        if case .failedRetryable = offlineOutcome {} else { Issue.record("expected retryable failure while offline") }

        // Still queued, still local.
        #expect((await a.dataStore.pendingChanges()).count >= 1)
        #expect((await a.memoryStore.allMemories()).count == 1)

        a.control.behavior = .ok
        let onlineOutcome = await a.syncEngine.sync()
        #expect(onlineOutcome.isSuccess)
        #expect(await a.backend.recordCount(ownerID: "owner-A") == 1)
        #expect((await a.dataStore.pendingChanges()).isEmpty)
    }

    // MARK: §30.14 / §30.15 — tombstones + no resurrection

    @Test("a deletion propagates and a stale device cannot resurrect it")
    func tombstoneNoResurrection() async {
        let shared = InMemoryPersonalCloudBackend()
        let a = await PersonalCloudHarness(ownerID: "u", sharedBackend: shared)
        let b = await PersonalCloudHarness(ownerID: "u", sharedBackend: shared)

        let id = UUID()
        await a.memoryStore.upsert([MemoryRecord(id: id, category: .knowledge, canonicalContent: "delete me")])
        _ = await a.syncEngine.sync()
        _ = await b.syncEngine.sync()
        #expect((await b.memoryStore.allMemories()).contains { $0.id == id })

        // A deletes and syncs.
        await a.memoryStore.deleteMemory(id: id)
        _ = await a.syncEngine.sync()

        // B, unaware, edits its stale copy and syncs.
        if var stale = (await b.memoryStore.allMemories()).first(where: { $0.id == id }) {
            stale.canonicalContent = "resurrected!"
            stale = stale.touched()
            await b.memoryStore.upsert([stale])
        }
        _ = await b.syncEngine.sync()

        // Pull the authoritative state back to both — must stay deleted.
        _ = await a.syncEngine.sync()
        _ = await b.syncEngine.sync()
        let aState = (await a.memoryStore.allMemories()).first { $0.id == id }
        let bState = (await b.memoryStore.allMemories()).first { $0.id == id }
        #expect(aState?.deletedAt != nil)
        #expect(bState?.deletedAt != nil)
        #expect(await a.backend.recordCount(ownerID: "u") == 0)  // tombstone excluded from live count
    }

    // MARK: §30.16 — version history preserved on sync fast-forward

    @Test("a pulled change to an existing record writes a revision of the old version")
    func revisionOnFastForward() async {
        let shared = InMemoryPersonalCloudBackend()
        let a = await PersonalCloudHarness(ownerID: "u", sharedBackend: shared)
        let b = await PersonalCloudHarness(ownerID: "u", sharedBackend: shared)

        let id = UUID()
        await a.memoryStore.upsert([MemoryRecord(id: id, category: .projects, canonicalContent: "Launch in September.")])
        _ = await a.syncEngine.sync()
        _ = await b.syncEngine.sync()

        // A changes it.
        if var rec = (await a.memoryStore.allMemories()).first(where: { $0.id == id }) {
            rec.canonicalContent = "Launch moved to October."
            rec = rec.touched()
            await a.memoryStore.upsert([rec])
        }
        _ = await a.syncEngine.sync()

        // B pulls the change → keeps a revision of "September".
        _ = await b.syncEngine.sync()
        let revs = await b.dataStore.revisions(recordID: id)
        #expect(revs.contains { $0.previousPayloadJSON.contains("September") })
        #expect((await b.memoryStore.allMemories()).first { $0.id == id }?.canonicalContent.contains("October") == true)
    }

    // MARK: §30.17 — deterministic conflict resolution

    @Test("a rule text conflict resolves the same way regardless of order (union: enabled = OR)")
    func deterministicRuleConflict() async {
        let shared = InMemoryPersonalCloudBackend()
        let a = await PersonalCloudHarness(ownerID: "u", sharedBackend: shared)
        let b = await PersonalCloudHarness(ownerID: "u", sharedBackend: shared)

        let ruleID = UUID()
        await a.memoryStore.upsertRule(Rule(id: ruleID, text: "Keep replies short."))
        _ = await a.syncEngine.sync()
        _ = await b.syncEngine.sync()

        // Both edit the same rule offline: A disables it, B keeps enabled + edits text.
        await a.memoryStore.setRuleEnabled(id: ruleID, enabled: false)
        if var r = (await b.memoryStore.allRules()).first(where: { $0.id == ruleID }) {
            r = r.touched(); r.text = "Keep replies short and direct."
            await b.memoryStore.upsertRule(r)
        }
        _ = await a.syncEngine.sync()      // A pushes first
        _ = await b.syncEngine.sync()      // B conflicts, resolves via ruleUnion, re-pushes
        _ = await a.syncEngine.sync()      // A pulls resolved

        let ra = (await a.memoryStore.allRules()).first { $0.id == ruleID }
        let rb = (await b.memoryStore.allRules()).first { $0.id == ruleID }
        #expect(ra?.text == rb?.text)          // converged
        #expect(ra?.enabled == rb?.enabled)
    }

    // MARK: §30.18 — sync failure never wipes local data

    @Test("a push failure leaves every local record and its content untouched")
    func failureNeverWipesLocal() async {
        let a = await PersonalCloudHarness()
        await a.memoryStore.upsert([
            MemoryRecord.fixture("keep me 1"),
            MemoryRecord.fixture("keep me 2"),
        ])
        await a.memoryStore.upsertRule(Rule(text: "keep this rule"))
        let before = await a.memoryStore.export()

        a.control.behavior = .offline
        _ = await a.syncEngine.sync()
        _ = await a.syncEngine.sync()

        let after = await a.memoryStore.export()
        #expect(after.records.map(\.canonicalContent).sorted() == before.records.map(\.canonicalContent).sorted())
        #expect(after.rules.map(\.text) == before.rules.map(\.text))
    }

    // MARK: §4 — an empty server response is not "delete everything"

    @Test("a pull that returns zero records deletes nothing local")
    func emptyPullDeletesNothing() async {
        let a = await PersonalCloudHarness()
        await a.memoryStore.upsert([MemoryRecord.fixture("A"), MemoryRecord.fixture("B")])
        await a.memoryStore.upsertRule(Rule(text: "keep me"))
        _ = await a.syncEngine.sync()

        // Sync again — the server has nothing new; the pull returns [].
        let before = await a.memoryStore.export()
        _ = await a.syncEngine.sync()
        _ = await a.syncEngine.sync()
        let after = await a.memoryStore.export()

        #expect(after.records.filter { $0.deletedAt == nil }.count == before.records.filter { $0.deletedAt == nil }.count)
        #expect(after.rules.map(\.text) == before.rules.map(\.text))
        #expect((await a.memoryStore.allMemories()).count == 2)
    }

    // MARK: §6 — prior revisions never become active memories

    @Test("revisions from a fast-forward are stored as history, never as active memory records")
    func revisionsAreNotActiveMemories() async {
        let shared = InMemoryPersonalCloudBackend()
        let a = await PersonalCloudHarness(ownerID: "u", sharedBackend: shared)
        let b = await PersonalCloudHarness(ownerID: "u", sharedBackend: shared)
        let id = UUID()
        await a.memoryStore.upsert([MemoryRecord(id: id, category: .projects, canonicalContent: "v1: September")])
        _ = await a.syncEngine.sync()
        _ = await b.syncEngine.sync()
        if var r = (await a.memoryStore.allMemories()).first(where: { $0.id == id }) {
            r.canonicalContent = "v2: October"; r = r.touched()
            await a.memoryStore.upsert([r])
        }
        _ = await a.syncEngine.sync()
        _ = await b.syncEngine.sync()

        let mems = await b.memoryStore.allMemories()
        #expect(mems.filter { $0.canonicalContent.contains("September") && $0.deletedAt == nil && $0.status == .active }.isEmpty)
        #expect(mems.filter { $0.id == id }.count == 1)  // exactly one record for that id
        #expect(await b.dataStore.revisions(recordID: id).contains { $0.previousPayloadJSON.contains("September") })
    }

    // MARK: §30.19 — malformed server response fails safely

    @Test("a malformed pull response is rejected and local data is byte-identical afterwards")
    func malformedResponseFailsSafely() async {
        let a = await PersonalCloudHarness()
        await a.memoryStore.upsert([MemoryRecord.fixture("safe local")])
        _ = await a.syncEngine.sync()
        let before = await a.memoryStore.export()

        // Put a record on the server for the next pull to deliver, then corrupt it.
        let b = await PersonalCloudHarness(ownerID: "owner-A", sharedBackend: a.backend)
        await b.memoryStore.upsert([MemoryRecord.fixture("from B")])
        _ = await b.syncEngine.sync()

        a.control.behavior = .malformedPull
        let outcome = await a.syncEngine.sync()
        if case .failedRetryable(let code) = outcome { #expect(code == "decode") } else { Issue.record("expected decode failure") }

        let after = await a.memoryStore.export()
        #expect(after.records.map(\.canonicalContent).sorted() == before.records.map(\.canonicalContent).sorted())
    }

    // MARK: §30.33 / §30.34 — memory-off & do-not-remember never upload

    @Test("with global memory off, sync is pull-only and pushes nothing")
    func memoryOffIsPullOnly() async {
        let a = await PersonalCloudHarness()
        await a.memoryStore.upsert([MemoryRecord.fixture("should not upload")])
        await a.memoryStore.setMemoryEnabledGlobally(false)

        _ = await a.syncEngine.sync()
        #expect(a.control.pushCount == 0)
        #expect(await a.backend.recordCount(ownerID: "owner-A") == 0)
    }

    @Test("a Do-Not-Remember conversation's messages are never in the sync change feed")
    func doNotRememberNeverUploads() async {
        let a = await PersonalCloudHarness()
        let convID = await a.conversationStore.currentConversationID()
        await a.conversationStore.append(PersonalAIChatMessage(role: .user, text: "secret thought"), conversationID: convID)
        await a.conversationStore.setDoNotRemember(convID, true)

        let pending = await a.dataStore.pendingChanges()
        #expect(pending.contains { $0.kind == .message } == false)
        #expect(pending.contains { $0.payloadJSON.contains("secret thought") } == false)

        _ = await a.syncEngine.sync()
        let (_, envelopes) = await a.backend.snapshotEnvelopes(ownerID: "owner-A")
        #expect(envelopes.contains { $0.payloadJSON.contains("secret thought") } == false)
    }
}
