import Testing
import Foundation
@testable import EvenAI

/// The independent-backup invariant, end to end through
/// `PersonalAIBackupCoordinator`: **a backup or restore failure — R2 dormant,
/// offline, corrupt, wrong key, interrupted — never destroys local Personal
/// AI data, and the previous verified backup stays recoverable.**
@MainActor
@Suite("Backup: hardening & disaster recovery")
struct BackupHardeningTests {

    // MARK: harness

    struct Harness {
        let memory: InMemoryPersonalMemoryStore
        let conversations: InMemoryPersonalAIConversationStore
        let dataStore: LocalPersonalDataStore
        let backupStore: any BackupStore
        let coordinator: PersonalAIBackupCoordinator
        let restoreCoordinator: PersonalAICloudRestoreCoordinator
        let ownerID: String
    }

    private func makeHarness(
        ownerID: String = "user-A",
        keySeed: UInt8 = 0x42,
        backupStore: (any BackupStore)? = nil,
        encryption: (any BackupEncryptionProviding)? = nil,
        verifyAfterUpload: Bool = true
    ) -> Harness {
        let memory = InMemoryPersonalMemoryStore()
        let conversations = InMemoryPersonalAIConversationStore()
        let box = PersonalOwnerBox(ownerID: ownerID)
        let dataStore = LocalPersonalDataStore(memory: memory, conversations: conversations, ownerID: { box.ownerID })
        let keyStore = InMemorySymmetricKeyStore(seed: keySeed)
        let store = backupStore ?? FakeR2.store().store
        let coordinator = PersonalAIBackupCoordinator(
            dataStore: dataStore, backupStore: store, keyStore: keyStore, ownerID: { box.ownerID },
            encryption: encryption, verifyAfterUpload: verifyAfterUpload, clock: { Date() }
        )
        let restoreCoordinator = PersonalAICloudRestoreCoordinator(
            dataStore: dataStore, cloudService: nil, backupCoordinator: coordinator
        )
        return Harness(memory: memory, conversations: conversations, dataStore: dataStore,
                       backupStore: store, coordinator: coordinator, restoreCoordinator: restoreCoordinator, ownerID: ownerID)
    }

    private func seed(_ h: Harness) async {
        await h.memory.upsert([
            MemoryRecord(id: UUID(), ownerID: h.ownerID, category: .projects, canonicalContent: "Building EvenAI.", entities: ["evenai"]),
            MemoryRecord(id: UUID(), ownerID: h.ownerID, category: .people, canonicalContent: "Nadia designs the UI.", entities: ["nadia"]),
            MemoryRecord(id: UUID(), ownerID: h.ownerID, category: .episodes, canonicalContent: "Shipped v1 in March.", entities: ["v1"]),
        ])
        await h.memory.upsertRule(Rule(ownerID: h.ownerID, text: "Answer in Ukrainian when spoken to directly."))
        let cid = await h.conversations.currentConversationID()
        await h.conversations.append(PersonalAIChatMessage(role: .user, text: "how's the project"), conversationID: cid)
        await h.conversations.append(PersonalAIChatMessage(role: .assistant, text: "on track"), conversationID: cid)
    }

    private func localContents(_ h: Harness) async -> Set<String> {
        Set((await h.memory.allMemories()).map(\.canonicalContent))
    }

    // MARK: snapshot round trip

    @Test("backup snapshot survives seal → store → fetch → decrypt → validate")
    func snapshotRoundTrips() async {
        let h = makeHarness()
        await seed(h)
        let outcome = await h.coordinator.backup(tier: .daily)
        #expect(outcome.succeeded)

        switch await h.coordinator.loadLatestBackupBundle() {
        case .success(let bundle):
            #expect(bundle.memory.records.count == 3)
            #expect(bundle.memory.rules.count == 1)
            #expect(bundle.messages.count == 2)
        case .failure(let e):
            Issue.record("loadLatest failed: \(e)")
        }
    }

    @Test("stable IDs, revisions, and tombstones survive backup → restore")
    func idsRevisionsTombstonesPreserved() async {
        let h = makeHarness()
        await seed(h)
        let all = await h.memory.allMemories()
        let keepID = all[0].id
        let deleteID = all[1].id

        // Edit one (creates a revision) and delete another (tombstone).
        var edited = all[0].touched()
        edited.canonicalContent = "Building EvenAI v2."
        await h.memory.upsert([edited])
        await h.memory.appendRevision(RecordRevision(recordID: keepID, recordKind: .memory, version: 0, source: .manualEntry, reason: "user-edit", previousPayloadJSON: "{}"))
        var deleted = all[1].touched()
        deleted.deletedAt = Date(); deleted.status = .deleted
        await h.memory.upsert([deleted])

        _ = await h.coordinator.backup(tier: .daily)

        // Wipe and restore.
        await h.memory.replaceAll(with: .empty)
        await h.conversations.wipe()
        let restore = await h.restoreCoordinator.restore(ownerID: h.ownerID)
        #expect(restore.succeeded)
        #expect(restore.source == .backup)

        let restored = await h.memory.allMemories()
        #expect(restored.contains { $0.id == keepID && $0.canonicalContent == "Building EvenAI v2." })
        #expect(restored.contains { $0.id == deleteID && $0.deletedAt != nil })
        #expect(!(await h.memory.allRevisions()).isEmpty)
    }

    @Test("deleted records do not resurrect after restore; repeated restore does not duplicate")
    func noResurrectionNoDuplication() async {
        let h = makeHarness()
        await seed(h)
        let all = await h.memory.allMemories()
        var deleted = all[2].touched()
        deleted.deletedAt = Date(); deleted.status = .deleted
        await h.memory.upsert([deleted])
        _ = await h.coordinator.backup(tier: .daily)

        await h.memory.replaceAll(with: .empty)
        await h.conversations.wipe()
        _ = await h.restoreCoordinator.restore(ownerID: h.ownerID)
        _ = await h.restoreCoordinator.restore(ownerID: h.ownerID)
        _ = await h.restoreCoordinator.restore(ownerID: h.ownerID)

        let active = (await h.memory.allMemories()).filter { $0.deletedAt == nil }
        #expect(active.count == 2)
        #expect(!active.contains { $0.id == all[2].id })
        #expect((await h.conversations.allMessages()).count == 2) // not tripled
    }

    // MARK: rejection paths — previous verified backup always survives

    @Test("a corrupted new object fails verification, is discarded, previous backup stays recoverable")
    func corruptNewBackupDiscarded() async {
        let (store, transport) = FakeR2.store()
        let h = makeHarness(backupStore: store)
        await seed(h)
        let first = await h.coordinator.backup(tier: .daily)
        #expect(first.succeeded)
        let firstVersion = first.bundleVersion

        // Next backup's object is corrupted at rest — verify must catch it.
        transport.corruptObjectReads = true
        await h.memory.upsert([MemoryRecord(ownerID: h.ownerID, category: .knowledge, canonicalContent: "new fact")])
        let second = await h.coordinator.backup(tier: .daily)
        #expect(!second.succeeded)
        #expect(second.errorCode == "verify")
        transport.corruptObjectReads = false   // storage is healthy again

        // The previous verified backup is still what a restore picks.
        switch await h.coordinator.loadLatestBackupBundle() {
        case .success(let bundle):
            #expect(bundle.manifest.bundleVersion == firstVersion)
        case .failure(let e):
            Issue.record("previous backup not recoverable: \(e)")
        }
        #expect(await localContents(h).contains("new fact")) // local data untouched
    }

    @Test("an interrupted upload never replaces the last verified backup")
    func interruptedUploadKeepsLastVerified() async {
        let (store, transport) = FakeR2.store()
        let h = makeHarness(backupStore: store)
        await seed(h)
        #expect(await h.coordinator.backup(tier: .daily).succeeded)

        transport.failNextPut = BackupTransportError.network
        await h.memory.upsert([MemoryRecord(ownerID: h.ownerID, category: .knowledge, canonicalContent: "later fact")])
        let interrupted = await h.coordinator.backup(tier: .daily)
        #expect(!interrupted.succeeded)

        #expect((try? await store.listBackups(ownerID: h.ownerID))?.count == 1)
        if case .success = await h.coordinator.loadLatestBackupBundle() {} else {
            Issue.record("last verified backup no longer loads")
        }
    }

    @Test("retrying a failed backup is idempotent and eventually succeeds")
    func retryIsIdempotent() async {
        let (store, transport) = FakeR2.store()
        let h = makeHarness(backupStore: store)
        await seed(h)

        transport.failNextPut = BackupTransportError.network
        #expect(!(await h.coordinator.backup(tier: .daily)).succeeded)
        // retry
        #expect(await h.coordinator.backup(tier: .daily).succeeded)
        #expect((try? await store.listBackups(ownerID: h.ownerID))?.count == 1)
    }

    @Test("wrong encryption key → restore rejected, local data untouched")
    func wrongKeyRestoreRejected() async {
        let (store, _) = FakeR2.store()
        let writer = makeHarness(keySeed: 0x01, backupStore: store)
        await seed(writer)
        #expect(await writer.coordinator.backup(tier: .daily).succeeded)

        // A different device / key tries to restore from the same store.
        let reader = makeHarness(keySeed: 0x02, backupStore: store)
        await seed(reader) // reader has its own local data
        let before = await localContents(reader)
        let outcome = await reader.restoreCoordinator.restore(ownerID: reader.ownerID)
        #expect(!outcome.succeeded)
        #expect(await localContents(reader) == before)
    }

    @Test("a backup belonging to a different Personal AI user cannot be restored (defence in depth)")
    func ownerMismatchRejected() async {
        // A store with NO owner scoping + a shared key (a mis-scoped bucket).
        // R2BackupStore would never expose this; the coordinator's owner check
        // is the backstop.
        let store = FlatInMemoryBackupStore()
        let userA = makeHarness(ownerID: "user-A", keySeed: 0x09, backupStore: store)
        await seed(userA)
        #expect(await userA.coordinator.backup(tier: .daily).succeeded)

        let userB = makeHarness(ownerID: "user-B", keySeed: 0x09, backupStore: store)
        switch await userB.coordinator.loadLatestBackupBundle() {
        case .success: Issue.record("user-B loaded user-A's backup")
        case .failure(let e): #expect(e == .ownerMismatch)
        }
    }

    @Test("unsupported / incomplete / integrity-mismatched backups are rejected without touching local data")
    func malformedBackupsRejected() async {
        let (store, transport) = FakeR2.store()
        let h = makeHarness(backupStore: store)
        await seed(h)
        #expect(await h.coordinator.backup(tier: .daily).succeeded)
        let before = await localContents(h)

        // Truncate the stored object → decrypt/validate fails on load.
        transport.truncateNextGetBy = 50
        if case .success = await h.coordinator.loadLatestBackupBundle() {
            Issue.record("truncated backup validated")
        }
        #expect(await localContents(h) == before)
    }

    // MARK: provider unavailable

    @Test("backup provider unavailable → backup fails, local cache and prior state intact")
    func providerUnavailableIsSafe() async {
        let h = makeHarness(backupStore: R2BackupStore.dormant)
        await seed(h)
        let before = await localContents(h)
        let stateBefore = await h.dataStore.syncState()

        let outcome = await h.coordinator.backup(tier: .daily)
        #expect(!outcome.succeeded)
        #expect(await localContents(h) == before)
        let stateAfter = await h.dataStore.syncState()
        #expect(stateAfter.lastBackupSucceededAt == stateBefore.lastBackupSucceededAt) // not advanced
    }

    @Test("a failed backup never clears authoritative data or the prior verified backup")
    func failedBackupNeverClears() async {
        let (store, transport) = FakeR2.store()
        let h = makeHarness(backupStore: store)
        await seed(h)
        #expect(await h.coordinator.backup(tier: .daily).succeeded)
        let memoriesBefore = await h.memory.allMemories()

        transport.alwaysFail = BackupTransportError.http(status: 503)
        for _ in 0..<3 { _ = await h.coordinator.backup(tier: .daily) }
        transport.alwaysFail = nil

        #expect(await h.memory.allMemories().map(\.id).sorted() == memoriesBefore.map(\.id).sorted())
        if case .success = await h.coordinator.loadLatestBackupBundle() {} else {
            Issue.record("prior backup lost after repeated failures")
        }
    }

    @Test("restore validation happens before any destructive local mutation")
    func validateBeforeMutation() async {
        let (store, transport) = FakeR2.store()
        let h = makeHarness(backupStore: store)
        await seed(h)
        #expect(await h.coordinator.backup(tier: .daily).succeeded)
        let before = await localContents(h)

        // Every fetch from the store now returns garbage.
        transport.alwaysFail = BackupTransportError.network
        let outcome = await h.restoreCoordinator.restore(ownerID: h.ownerID)
        #expect(!outcome.succeeded)
        #expect(await localContents(h) == before)   // nothing was wiped first
    }

    // MARK: no secrets

    @Test("nothing in a backup (sealed or decrypted) looks like an auth token / secret")
    func noSecretsInBackup() async {
        let (store, transport) = FakeR2.store()
        let h = makeHarness(backupStore: store)
        await seed(h)
        #expect(await h.coordinator.backup(tier: .daily).succeeded)

        let sealed = transport.rawData(forKeySuffix: ".eapb") ?? Data()
        #expect(!sealed.isEmpty)
        let decrypted: Data
        if case .success(let bundle) = await h.coordinator.loadLatestBackupBundle() {
            decrypted = (try? PersonalDataExporter.data(for: bundle)) ?? Data()
        } else { decrypted = Data() }

        for blob in [sealed, decrypted] {
            let text = String(decoding: blob, as: UTF8.self).lowercased()
            for forbidden in ["\"password\"", "accesstoken", "refreshtoken", "\"apikey\"", "api_key",
                              "bearer ", "authorization", "privatekey", "keychain", "secretkey",
                              "cloudflare", "r2accesskey", "aws_secret"] {
                #expect(!text.contains(forbidden), "backup blob contains \(forbidden)")
            }
        }
    }
}
