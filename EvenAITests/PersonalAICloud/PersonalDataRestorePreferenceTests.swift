import Testing
import Foundation
@testable import EvenAI

/// A data restore restores canonical Personal AI data. It must **not** silently
/// mutate the device's operational sync configuration (`PersonalSyncState` —
/// `cloudSyncEnabled`, the sync cursor, per-record bookkeeping, backup
/// history). `PersonalSyncState` is local runtime/config state, not canonical
/// user data, and a restored bundle's copy is meaningless on this device.
///
/// Invariant:  before restore `cloudSyncEnabled == X`  ⇒  after a successful
/// `.replaceAll` restore `cloudSyncEnabled == X`.
@MainActor
@Suite("Personal AI: restore preserves the local sync preference")
struct PersonalDataRestorePreferenceTests {

    private func bundle(with contents: [String]) -> PersonalDataBundle {
        let doc = PersonalMemoryDocument(
            records: contents.map { MemoryRecord(category: .knowledge, canonicalContent: $0) }
        )
        return PersonalDataExporter.makeBundle(
            memory: doc, conversations: [], messages: [],
            selection: .everything, bundleVersion: 1
        )
    }

    private func restore(_ b: PersonalDataBundle, into store: InMemoryPersonalMemoryStore) async -> ImportResult {
        await PersonalDataImporter.restore(
            b, into: store, conversationStore: InMemoryPersonalAIConversationStore(), strategy: .replaceAll
        )
    }

    @Test("replaceAll preserves cloudSyncEnabled = true")
    func preservesEnabledTrue() async {
        let store = InMemoryPersonalMemoryStore()
        await store.upsert([MemoryRecord.fixture("old fact")])
        await store.saveSyncState(PersonalSyncState(cloudSyncEnabled: true))

        let result = await restore(bundle(with: ["restored fact A", "restored fact B"]), into: store)
        #expect(result.succeeded)
        #expect(await store.loadSyncState().cloudSyncEnabled == true)
        #expect((await store.allMemories()).map(\.canonicalContent).sorted() == ["restored fact A", "restored fact B"])
    }

    @Test("replaceAll preserves cloudSyncEnabled = false")
    func preservesEnabledFalse() async {
        let store = InMemoryPersonalMemoryStore()
        await store.saveSyncState(PersonalSyncState(cloudSyncEnabled: false))

        let result = await restore(bundle(with: ["x"]), into: store)
        #expect(result.succeeded)
        #expect(await store.loadSyncState().cloudSyncEnabled == false)
    }

    @Test("replaceAll preserves the full local sync bookkeeping (cursor, syncedRevisions, backup history)")
    func preservesFullSyncState() async {
        let store = InMemoryPersonalMemoryStore()
        let localState = PersonalSyncState(
            cursor: "device-local-cursor",
            pendingMutationCount: 4,
            cloudSyncEnabled: true,
            lastBackupSucceededAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastBackupVersion: 12,
            syncedRevisions: ["memory:abc": 7]
        )
        await store.saveSyncState(localState)

        _ = await restore(bundle(with: ["y"]), into: store)
        let after = await store.loadSyncState()
        #expect(after.cursor == "device-local-cursor")
        #expect(after.cloudSyncEnabled == true)
        #expect(after.lastBackupVersion == 12)
        #expect(after.syncedRevisions["memory:abc"] == 7)
    }

    @Test("a failed restore preserves the preference (and the data)")
    func failedRestorePreservesPreference() async {
        let store = InMemoryPersonalMemoryStore()
        await store.upsert([MemoryRecord.fixture("do not lose")])
        await store.saveSyncState(PersonalSyncState(cloudSyncEnabled: true))

        // A bundle that fails validation (checksum tampered).
        var bad = bundle(with: ["never applied"])
        bad.manifest.checksum = "deadbeef"
        let result = await PersonalDataImporter.restore(
            bad, into: store, conversationStore: InMemoryPersonalAIConversationStore(), strategy: .replaceAll
        )
        #expect(!result.succeeded)
        #expect(await store.loadSyncState().cloudSyncEnabled == true)
        #expect((await store.allMemories()).contains { $0.canonicalContent == "do not lose" })
    }

    @Test("repeated restore preserves the preference")
    func repeatedRestorePreservesPreference() async {
        let store = InMemoryPersonalMemoryStore()
        await store.saveSyncState(PersonalSyncState(cloudSyncEnabled: true))
        let b = bundle(with: ["a", "b"])
        _ = await restore(b, into: store)
        _ = await restore(b, into: store)
        _ = await restore(b, into: store)
        #expect(await store.loadSyncState().cloudSyncEnabled == true)
        #expect((await store.allMemories()).count == 2)
    }

    @Test("fresh-install restore uses the documented default (PersonalSyncState.empty), not a bundle value")
    func freshInstallUsesDocumentedDefault() async {
        // A brand-new store has never had a sync state written.
        let store = InMemoryPersonalMemoryStore()
        #expect(await store.loadSyncState().cloudSyncEnabled == PersonalSyncState.empty.cloudSyncEnabled) // false

        // Restore a bundle whose own sync state happens to say enabled=true.
        var doc = PersonalMemoryDocument(records: [MemoryRecord(category: .knowledge, canonicalContent: "z")])
        doc.syncState = PersonalSyncState(cursor: "someone-elses-cursor", cloudSyncEnabled: true)
        var b = PersonalDataExporter.makeBundle(memory: doc, conversations: [], messages: [], selection: .everything, bundleVersion: 1)
        b.manifest.checksum = PersonalBundleChecksum.compute(for: b)

        let result = await restore(b, into: store)
        #expect(result.succeeded)
        // The bundle's cloudSyncEnabled / cursor are ignored — the device's
        // own (default/empty) state stands.
        let after = await store.loadSyncState()
        #expect(after.cloudSyncEnabled == false)
        #expect(after.cursor == nil)
    }
}
