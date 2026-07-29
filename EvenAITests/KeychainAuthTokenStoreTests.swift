import Testing
@testable import EvenAI

/// Exercises the real Keychain (via the Simulator/test host's own
/// keychain) — not a stub. `.serialized` avoids two tests racing to
/// write/clear the same Keychain item concurrently, since
/// `KeychainAuthTokenStore` always operates on one fixed service/account
/// pair.
@Suite("KeychainAuthTokenStore", .serialized)
struct KeychainAuthTokenStoreTests {
    @Test("save then currentRefreshToken round-trips the value")
    func saveAndRead() {
        let store = KeychainAuthTokenStore()
        defer { store.clear() }

        store.save(refreshToken: "test-refresh-token-1")
        #expect(store.currentRefreshToken() == "test-refresh-token-1")
    }

    @Test("saving a new value overwrites the previous one")
    func saveOverwrites() {
        let store = KeychainAuthTokenStore()
        defer { store.clear() }

        store.save(refreshToken: "first")
        store.save(refreshToken: "second")
        #expect(store.currentRefreshToken() == "second")
    }

    @Test("clear removes the stored value")
    func clearRemoves() {
        let store = KeychainAuthTokenStore()
        store.save(refreshToken: "to-be-cleared")
        store.clear()
        #expect(store.currentRefreshToken() == nil)
    }

    @Test("currentRefreshToken is nil when nothing has been saved")
    func readsNilWhenEmpty() {
        let store = KeychainAuthTokenStore()
        store.clear() // in case a prior failed run left something behind
        #expect(store.currentRefreshToken() == nil)
    }
}
