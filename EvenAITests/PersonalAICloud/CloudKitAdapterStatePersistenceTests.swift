import Testing
import Foundation
import CloudKit
@testable import EvenAI

/// The CloudKit adapter's local state — account binding, sync cursor, per-zone
/// change tokens, per-record change tags — must survive an app relaunch, and
/// any corruption must reset **adapter metadata only**, never canonical
/// Personal AI memory.
@MainActor
@Suite("CloudKit: adapter state persistence")
struct CloudKitAdapterStatePersistenceTests {

    private func tempFile() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ck-state-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("adapter-state.eap")
    }

    // MARK: 1 — account binding survives adapter recreation

    @Test("1 — account binding survives a fresh adapter over the same file (relaunch)")
    func bindingSurvivesRelaunch() async {
        let url = tempFile()
        let db = FakeCloudKitDatabase()
        db.userRecordNameValue = "icloud-A"

        // "Session 1" — bind.
        let s1 = CloudKitPersonalCloudService(
            database: db,
            stateStore: FileCloudKitAdapterStateStore(url: url, file: PlaintextDocumentFile()),
            personalAIUserID: { "user-1" }
        )
        _ = try? await s1.pull(ownerID: "user-1", since: nil) // binds
        #expect(FileManager.default.fileExists(atPath: url.path))

        // "Session 2" — a brand-new adapter + store over the same file.
        let store2 = FileCloudKitAdapterStateStore(url: url, file: PlaintextDocumentFile())
        let reloaded = await store2.load()
        #expect(reloaded.binding?.personalAIUserID == "user-1")
        #expect(reloaded.binding?.ckUserRecordName == "icloud-A")
    }

    // MARK: 2 — reconciliation-required inputs survive (the state is derived)

    @Test("2 — A→B protection still works after relaunch: persisted binding + new account → reconciliation")
    func reconciliationSurvivesRelaunch() async {
        let url = tempFile()
        let db = FakeCloudKitDatabase()
        db.userRecordNameValue = "icloud-A"

        let s1 = CloudKitPersonalCloudService(
            database: db,
            stateStore: FileCloudKitAdapterStateStore(url: url, file: PlaintextDocumentFile()),
            personalAIUserID: { "user-1" }
        )
        _ = try? await s1.pull(ownerID: "user-1", since: nil) // binds to icloud-A

        // Relaunch on a different iCloud account.
        db.simulateICloudAccountSwitch(to: "icloud-B")
        let s2 = CloudKitPersonalCloudService(
            database: db,
            stateStore: FileCloudKitAdapterStateStore(url: url, file: PlaintextDocumentFile()),
            personalAIUserID: { "user-1" }
        )
        let state = await s2.currentAccountState()
        guard case .reconciliationRequired(let reason) = state else {
            Issue.record("expected .reconciliationRequired after relaunch, got \(state)"); return
        }
        #expect(reason.expectedICloudUser == "icloud-A")
        #expect(reason.actualICloudUser == "icloud-B")

        // And a sync attempt is frozen — the push throws, nothing uploaded to B.
        var pushThrew = false
        do {
            _ = try await s2.push(SyncPushRequest(ownerID: "user-1", records: [], idempotencyKey: "k"))
        } catch {
            pushThrew = true
        }
        #expect(pushThrew)
        #expect(db.totalRecordCount(user: "icloud-B") == 0)
    }

    // MARK: 3 — sync cursor + per-record tags survive

    @Test("3 — sync cursor and per-record change tags survive relaunch")
    func cursorAndTagsSurviveRelaunch() async {
        let url = tempFile()
        let db = FakeCloudKitDatabase()
        db.userRecordNameValue = "icloud-A"

        let s1 = CloudKitPersonalCloudService(
            database: db,
            stateStore: FileCloudKitAdapterStateStore(url: url, file: PlaintextDocumentFile()),
            personalAIUserID: { "user-1" }
        )
        let memory = MemoryRecord.fixture("persisted fact")
        _ = try? await s1.push(SyncPushRequest(
            ownerID: "user-1",
            records: [PersonalSyncCodec.encode(memory)],
            idempotencyKey: "k1"
        ))

        let store2 = FileCloudKitAdapterStateStore(url: url, file: PlaintextDocumentFile())
        let reloaded = await store2.load()
        let key = CloudKitAdapterState.key(zone: .core, recordName: memory.id.uuidString)
        #expect(reloaded.records[key] != nil)
        #expect(reloaded.records[key]?.changeTag.isEmpty == false)
        #expect(reloaded.nextSyntheticRevision > 1)
    }

    // MARK: 4 — corrupted file fails safely

    @Test("4 — a corrupted adapter-state file loads as .empty, no throw")
    func corruptFileFailsSafely() async {
        let url = tempFile()
        try? Data("{ not json at all ]".utf8).write(to: url)
        let store = FileCloudKitAdapterStateStore(url: url, file: PlaintextDocumentFile())
        let loaded = await store.load()
        #expect(loaded == .empty)
    }

    @Test("4b — a too-new adapter-state version loads as .empty (safe reset)")
    func tooNewVersionResets() async {
        let url = tempFile()
        var future = CloudKitAdapterState.empty
        future.adapterStateVersion = 999
        future.binding = CloudKitAccountBinding(personalAIUserID: "u", ckUserRecordName: "ic", boundAt: .now)
        try? JSONEncoder().encode(future).write(to: url)

        let store = FileCloudKitAdapterStateStore(url: url, file: PlaintextDocumentFile())
        let loaded = await store.load()
        #expect(loaded.binding == nil)
        #expect(loaded == .empty)
    }

    // MARK: 5 — deleted file → safe rebootstrap

    @Test("5 — a deleted adapter-state file causes a clean re-bootstrap")
    func deletedFileRebootstraps() async {
        let url = tempFile()
        let db = FakeCloudKitDatabase()
        db.userRecordNameValue = "icloud-A"

        let s1 = CloudKitPersonalCloudService(
            database: db,
            stateStore: FileCloudKitAdapterStateStore(url: url, file: PlaintextDocumentFile()),
            personalAIUserID: { "user-1" }
        )
        _ = try? await s1.pull(ownerID: "user-1", since: nil)
        try? FileManager.default.removeItem(at: url)

        let s2 = CloudKitPersonalCloudService(
            database: db,
            stateStore: FileCloudKitAdapterStateStore(url: url, file: PlaintextDocumentFile()),
            personalAIUserID: { "user-1" }
        )
        // Same account is still present → re-binds cleanly, sync works.
        let outcome = try? await s2.pull(ownerID: "user-1", since: nil)
        #expect(outcome != nil)
        #expect(await s2.currentAccountState() == .bound)
    }

    // MARK: 6 — adapter-state reset does not delete canonical memories

    @Test("6 — corrupting the adapter-state file mid-life never touches the memory store")
    func stateResetDoesNotTouchCanonicalMemory() async {
        let url = tempFile()
        let h = await CloudKitTestHarness(personalAIUserID: "user-1", iCloudUser: "icloud-A", adapterStateFileURL: url)
        await h.memoryStore.upsert([MemoryRecord.fixture("canonical one"), MemoryRecord.fixture("canonical two")])
        _ = await h.syncEngine.sync()
        let before = Set((await h.memoryStore.allMemories()).map(\.canonicalContent))

        // Corrupt the adapter state on disk.
        try? Data("garbage".utf8).write(to: url)

        // Keep operating — the adapter rebootstraps from .empty; the engine
        // never clears local data on any adapter outcome.
        await h.memoryStore.upsert([MemoryRecord.fixture("canonical three")])
        _ = await h.syncEngine.sync()
        _ = await h.syncEngine.sync()

        let after = Set((await h.memoryStore.allMemories()).map(\.canonicalContent))
        #expect(before.isSubset(of: after))
        #expect(after.contains("canonical three"))
    }

    // MARK: 7 — no token / secret data serialized

    @Test("7 — the serialized adapter state contains only sync plumbing, no secrets")
    func noSecretsSerialized() async {
        let url = tempFile()
        let db = FakeCloudKitDatabase()
        db.userRecordNameValue = "icloud-A"
        let service = CloudKitPersonalCloudService(
            database: db,
            stateStore: FileCloudKitAdapterStateStore(url: url, file: PlaintextDocumentFile()),
            personalAIUserID: { "user-1" }
        )
        _ = try? await service.push(SyncPushRequest(
            ownerID: "user-1",
            records: [PersonalSyncCodec.encode(MemoryRecord.fixture("hello"))],
            idempotencyKey: "k"
        ))

        let raw = (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(!raw.isEmpty)

        // No secret-shaped keys.
        for forbidden in ["password", "token\"", "accessToken", "refreshToken", "apiKey", "api_key",
                          "secret", "authorization", "bearer", "privateKey", "keychain", "ckWebAuthToken"] {
            #expect(!raw.lowercased().contains(forbidden.lowercased()), "adapter state must not serialize \(forbidden)")
        }
        // Only the expected top-level keys.
        let decoded = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
        let keys = Set((decoded ?? [:]).keys)
        #expect(keys.isSubset(of: ["adapterStateVersion", "records", "cursor", "binding", "nextSyntheticRevision"]),
                "unexpected adapter-state keys: \(keys)")
        // No memory content leaked into the metadata.
        #expect(!raw.contains("hello"))
    }

    // MARK: round-trip through the encrypted document file

    @Test("adapter state round-trips through EncryptedDocumentFile too")
    func encryptedRoundTrip() async {
        let url = tempFile()
        let keyStore = InMemorySymmetricKeyStore()
        let file = EncryptedDocumentFile(keyStore: keyStore)
        let store = FileCloudKitAdapterStateStore(url: url, file: file)

        var state = CloudKitAdapterState.empty
        state.binding = CloudKitAccountBinding(personalAIUserID: "u", ckUserRecordName: "ic", boundAt: Date(timeIntervalSince1970: 1_700_000_000))
        state.nextSyntheticRevision = 9
        await store.save(state)

        let store2 = FileCloudKitAdapterStateStore(url: url, file: EncryptedDocumentFile(keyStore: keyStore))
        let back = await store2.load()
        #expect(back.binding?.personalAIUserID == "u")
        #expect(back.nextSyntheticRevision == 9)

        // On-disk bytes are sealed, not readable plaintext JSON.
        let rawOnDisk = (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(!rawOnDisk.contains("personalAIUserID"))
    }
}
