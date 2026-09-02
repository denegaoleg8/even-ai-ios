import Foundation
import Security

/// Optional on-device storage for the **current** `PersonalAIRecoveryKey`, so
/// that after the user has set one up, future backups can be re-wrapped for it
/// without re-prompting. The *authoritative* copy is the one the user exported
/// (`recoveryCode` / recovery file) — this is a convenience cache, and losing
/// it (new device, wipe) is expected: that is exactly when the user supplies
/// the exported code.
///
/// Mirrors `SymmetricKeyStore`'s shape and protection class, in its **own**
/// Keychain service so it never collides with the device encryption key or the
/// auth token.
///
/// **Not wired into `PersonalAIContainer.live`.** It is the model seam the
/// recovery UX (a later workstream) will use.
protocol RecoveryKeyStore: Sendable {
    /// The stored recovery key, or `nil` if the user has not set one up on
    /// this device.
    func current() throws -> PersonalAIRecoveryKey?
    /// Store (or replace) the recovery key for this device.
    func store(_ key: PersonalAIRecoveryKey) throws
    /// Forget the device copy (the user's exported code still works).
    func clear() throws
}

/// Keychain-backed. `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — never
/// synced to iCloud Keychain (that would be a deliberate, separately-reviewed
/// change), never leaves the device.
struct KeychainRecoveryKeyStore: RecoveryKeyStore {
    private let service: String
    private let account: String

    init(service: String = "com.evenai.personalai.recovery-key", account: String = "primary") {
        self.service = service
        self.account = account
    }

    func current() throws -> PersonalAIRecoveryKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return try PersonalAIRecoveryKey(serialized: data)
        case errSecItemNotFound:
            return nil
        default:
            throw SymmetricKeyStoreError.keychainFailure(status)
        }
    }

    func store(_ key: PersonalAIRecoveryKey) throws {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: key.serialized(),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemDelete(attributes as CFDictionary)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw SymmetricKeyStoreError.keychainFailure(status) }
    }

    func clear() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SymmetricKeyStoreError.keychainFailure(status)
        }
    }
}

/// In-memory store for tests and previews.
final class InMemoryRecoveryKeyStore: RecoveryKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: PersonalAIRecoveryKey?

    init(_ key: PersonalAIRecoveryKey? = nil) { self.key = key }

    func current() throws -> PersonalAIRecoveryKey? { lock.withLock { key } }
    func store(_ key: PersonalAIRecoveryKey) throws { lock.withLock { self.key = key } }
    func clear() throws { lock.withLock { key = nil } }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
