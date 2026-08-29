import Testing
import Foundation
@testable import EvenAI

/// `R2BackupStore` over the in-memory transport + fake presign provider — the
/// object layout, the catalog, publication atomicity, idempotency, scoping,
/// and the dormant-in-production posture.
@Suite("Backup: R2 store adapter")
struct R2BackupStoreTests {

    private func handle(id: String = UUID().uuidString, version: Int = 1, tier: String = "daily") -> BackupHandle {
        BackupHandle(id: id, createdAt: Date(), bundleVersion: version, sizeBytes: 0, checksum: "c\(version)", tier: tier)
    }

    @Test("put → list → get → delete round trip")
    func roundTrip() async throws {
        let (store, _) = FakeR2.store()
        let h = handle()
        let payload = Data("sealed-bytes".utf8)
        try await store.putBackup(payload, handle: h, ownerID: "user-1")

        let listed = try await store.listBackups(ownerID: "user-1")
        #expect(listed.map(\.id) == [h.id])

        let got = try await store.getBackup(h, ownerID: "user-1")
        #expect(got == payload)

        try await store.deleteBackup(h, ownerID: "user-1")
        #expect(try await store.listBackups(ownerID: "user-1").isEmpty)
    }

    @Test("object keys are scoped under the salted owner tag, never the raw owner id")
    func ownerScopedKeys() async throws {
        let (store, transport) = FakeR2.store()
        try await store.putBackup(Data("x".utf8), handle: handle(), ownerID: "sensitive-user-id")
        let tag = BackupOwnerTag.tag("sensitive-user-id")
        for key in transport.keys() {
            #expect(key.contains(tag))
            #expect(!key.contains("sensitive-user-id"))
        }
    }

    @Test("a failed object upload leaves the catalog — every prior backup — untouched")
    func failedUploadKeepsPriorBackups() async throws {
        let (store, transport) = FakeR2.store()
        let good = handle(id: "good", version: 1)
        try await store.putBackup(Data("first".utf8), handle: good, ownerID: "u")

        transport.failNextPut = BackupTransportError.network
        let bad = handle(id: "bad", version: 2)
        await #expect(throws: (any Error).self) {
            try await store.putBackup(Data("second".utf8), handle: bad, ownerID: "u")
        }

        let listed = try await store.listBackups(ownerID: "u")
        #expect(listed.map(\.id) == ["good"])
        #expect(try await store.getBackup(good, ownerID: "u") == Data("first".utf8))
    }

    @Test("re-putting the same handle id does not duplicate it in the catalog (idempotent)")
    func idempotentPut() async throws {
        let (store, _) = FakeR2.store()
        let h = handle(id: "same", version: 3)
        try await store.putBackup(Data("v1".utf8), handle: h, ownerID: "u")
        try await store.putBackup(Data("v1".utf8), handle: h, ownerID: "u")
        try await store.putBackup(Data("v1".utf8), handle: h, ownerID: "u")
        #expect(try await store.listBackups(ownerID: "u").count == 1)
    }

    @Test("truncated object on get is detected against the handle size")
    func truncationDetected() async throws {
        let (store, transport) = FakeR2.store()
        let payload = Data(repeating: 0xAB, count: 500)
        var h = handle()
        h.sizeBytes = payload.count
        try await store.putBackup(payload, handle: h, ownerID: "u")

        transport.truncateNextGetBy = 10
        await #expect(throws: BackupTransportError.self) {
            _ = try await store.getBackup(h, ownerID: "u")
        }
    }

    @Test("a credential provider that isn't configured makes every op throw notConfigured")
    func notConfiguredThrows() async {
        let (store, _) = FakeR2.store(configured: false)
        await #expect(throws: (any Error).self) {
            try await store.putBackup(Data("x".utf8), handle: handle(), ownerID: "u")
        }
        await #expect(throws: (any Error).self) {
            _ = try await store.listBackups(ownerID: "u")
        }
    }

    @Test("R2BackupStore.dormant is the production posture — nothing configured, nothing throws-through")
    func dormantPosture() async {
        let store = R2BackupStore.dormant
        await #expect(throws: (any Error).self) {
            try await store.putBackup(Data("x".utf8), handle: handle(), ownerID: "u")
        }
    }

    @Test("credential scope check rejects a key outside the owner's prefix")
    func scopeEnforced() async {
        let provider = FakePresignProvider()
        await #expect(throws: BackupCredentialError.self) {
            _ = try await provider.presign(.get, key: "other-tag/objects/1.eapb", ownerTag: "my-tag")
        }
    }
}
