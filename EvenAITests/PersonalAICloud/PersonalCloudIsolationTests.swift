import Testing
import Foundation
@testable import EvenAI

@MainActor
@Suite("Personal AI Cloud: user ownership & isolation")
struct PersonalCloudIsolationTests {

    // MARK: §30.20 — cross-user access is impossible server-side

    @Test("owner A's push never becomes visible to owner B on pull, snapshot, or count")
    func crossUserAccessRejected() async {
        let shared = InMemoryPersonalCloudBackend()
        let a = await PersonalCloudHarness(ownerID: "user-A", sharedBackend: shared)
        let b = await PersonalCloudHarness(ownerID: "user-B", sharedBackend: shared)

        await a.memoryStore.upsert([
            MemoryRecord.fixture("A's private memory about salary"),
            MemoryRecord.fixture("A's other secret"),
        ])
        await a.memoryStore.upsertRule(Rule(text: "A's rule"))
        _ = await a.syncEngine.sync()

        // B syncs — must receive nothing of A's.
        let outB = await b.syncEngine.sync()
        #expect(outB.isSuccess)
        #expect((await b.memoryStore.allMemories()).isEmpty)
        #expect((await b.memoryStore.allRules()).isEmpty)

        // Direct backend probes.
        let pull = await shared.pull(ownerID: "user-B", since: nil)
        #expect(pull.records.isEmpty)
        let snapshot = await shared.snapshotEnvelopes(ownerID: "user-B")
        #expect(snapshot.records.isEmpty)
        #expect(await shared.recordCount(ownerID: "user-B") == 0)
        #expect(await shared.recordCount(ownerID: "user-A") == 3)

        // B pushes its own data — still isolated.
        await b.memoryStore.upsert([MemoryRecord.fixture("B's memory")])
        _ = await b.syncEngine.sync()
        #expect(await shared.recordCount(ownerID: "user-A") == 3)
        #expect(await shared.recordCount(ownerID: "user-B") == 1)
        let pullA = await shared.pull(ownerID: "user-A", since: nil)
        #expect(pullA.records.contains { $0.payloadJSON.contains("B's memory") } == false)
    }

    @Test("a snapshot for one owner never contains another owner's records")
    func snapshotIsolation() async {
        let shared = InMemoryPersonalCloudBackend()
        let a = await PersonalCloudHarness(ownerID: "alice", sharedBackend: shared)
        let b = await PersonalCloudHarness(ownerID: "bob", sharedBackend: shared)
        await a.memoryStore.upsert([MemoryRecord.fixture("alice fact")])
        await b.memoryStore.upsert([MemoryRecord.fixture("bob fact")])
        _ = await a.syncEngine.sync()
        _ = await b.syncEngine.sync()

        let aliceSnap = try? await a.cloudService.snapshot(ownerID: "alice")
        #expect(aliceSnap?.memory.records.contains { $0.canonicalContent.contains("bob") } == false)
        #expect(aliceSnap?.memory.records.contains { $0.canonicalContent.contains("alice") } == true)
    }

    @Test("deleteAllData for one owner leaves the other owner intact")
    func deleteIsScopedToOwner() async {
        let shared = InMemoryPersonalCloudBackend()
        let a = await PersonalCloudHarness(ownerID: "a1", sharedBackend: shared)
        let b = await PersonalCloudHarness(ownerID: "b1", sharedBackend: shared)
        await a.memoryStore.upsert([MemoryRecord.fixture("a fact")])
        await b.memoryStore.upsert([MemoryRecord.fixture("b fact")])
        _ = await a.syncEngine.sync()
        _ = await b.syncEngine.sync()

        try? await a.cloudService.deleteAllData(ownerID: "a1")
        #expect(await shared.recordCount(ownerID: "a1") == 0)
        #expect(await shared.recordCount(ownerID: "b1") == 1)
    }
}
