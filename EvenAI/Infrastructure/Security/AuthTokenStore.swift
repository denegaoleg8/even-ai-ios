import Foundation
import Security

/// Keychain storage for the refresh token — and only the refresh token.
/// The access token deliberately never touches Keychain, UserDefaults,
/// or SwiftData: it lives in memory only, inside `AuthenticatedAPIClient`
/// (see that file), and is cheaply re-derived from the refresh token on
/// every launch. Smaller persisted attack surface, standard OAuth2
/// practice.
protocol AuthTokenStoring: Sendable {
    func currentRefreshToken() -> String?
    func save(refreshToken: String)
    func clear()
}

struct KeychainAuthTokenStore: AuthTokenStoring {
    private let service = "com.evenai.app.auth-token"
    private let account = "refresh-token"

    func currentRefreshToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            return nil
        }
        return token
    }

    func save(refreshToken: String) {
        let data = Data(refreshToken.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        // Stricter than DeviceIdentityStore's .afterFirstUnlock: opts
        // this out of iCloud Keychain sync specifically. A session must
        // stay bound to the device that created it — it should never
        // silently propagate to a user's other devices through Keychain
        // sync, only through an explicit sign-in.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
