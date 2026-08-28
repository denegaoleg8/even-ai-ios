import Foundation
import CryptoKit
import Security

/// Supplies the AES-256 key that seals the Personal AI local cache and
/// backups. The key lives in the iOS Keychain and **never** in the same
/// file, service, or account as the data it protects or as
/// `AuthTokenStore`'s refresh token — auth credentials and Personal AI
/// content are cryptographically and physically separate.
protocol SymmetricKeyStore: Sendable {
    /// Returns the existing key, or generates + stores one on first use.
    func key() throws -> SymmetricKey
    /// Wipe the key (part of "delete Personal AI account" — makes any
    /// remaining ciphertext unrecoverable).
    func destroy() throws
}

enum SymmetricKeyStoreError: Error, Equatable, Sendable {
    case keychainFailure(OSStatus)
    case generationFailed
}

/// Production key store. Key: 32 random bytes, stored with
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (usable in the
/// background after first unlock, never synced to iCloud Keychain, never
/// leaves the device) — the same protection class `KeychainAuthTokenStore`
/// chose, but its **own** service + account so the two never collide.
struct KeychainSymmetricKeyStore: SymmetricKeyStore {
    private let service: String
    private let account: String

    init(service: String = "com.evenai.personalai.cache-key", account: String = "primary") {
        self.service = service
        self.account = account
    }

    func key() throws -> SymmetricKey {
        if let existing = try readKey() { return existing }
        let fresh = SymmetricKey(size: .bits256)
        try writeKey(fresh)
        return fresh
    }

    func destroy() throws {
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

    private func readKey() throws -> SymmetricKey? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        query.removeAll()
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            return nil
        default:
            throw SymmetricKeyStoreError.keychainFailure(status)
        }
    }

    private func writeKey(_ key: SymmetricKey) throws {
        let data = key.withUnsafeBytes { Data($0) }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemDelete(attributes as CFDictionary)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw SymmetricKeyStoreError.keychainFailure(status) }
    }
}

/// In-memory key store for tests and previews — deterministic, no Keychain.
/// A fixed seed makes ciphertext reproducible across a test run.
struct InMemorySymmetricKeyStore: SymmetricKeyStore {
    private let fixed: SymmetricKey

    init(seed: UInt8 = 0x42) {
        self.fixed = SymmetricKey(data: Data(repeating: seed, count: 32))
    }

    func key() throws -> SymmetricKey { fixed }
    func destroy() throws {}
}
