import Foundation
import Security

/// Persists a stable per-device UUID in the Keychain, independent of app
/// reinstalls. Used later to identify this device to the backend during
/// the `POST /api/auth/device` flow — see the Even AI API specification.
protocol DeviceIdentityStoring: Sendable {
    func currentDeviceID() -> UUID
}

struct KeychainDeviceIdentityStore: DeviceIdentityStoring {
    private let service = "com.evenai.app.device-identity"
    private let account = "device-id"

    func currentDeviceID() -> UUID {
        if let existing = readUUID() {
            return existing
        }
        let newID = UUID()
        write(newID)
        return newID
    }

    private func readUUID() -> UUID? {
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
              let string = String(data: data, encoding: .utf8),
              let uuid = UUID(uuidString: string) else {
            return nil
        }
        return uuid
    }

    private func write(_ id: UUID) {
        let data = Data(id.uuidString.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess {
            // Worse than a failed token write: currentDeviceID() still
            // hands back `id` even though it never persisted, so if this
            // keeps failing, every call in this process generates and
            // returns a *different* UUID (readUUID() never finds what
            // was never saved) — a device that looks like a different
            // one to the backend on every launch. The UUID itself isn't
            // sensitive; logging it is what makes this diagnosable.
            AppLogger.auth.error("Failed to save device identity \(id.uuidString, privacy: .public) to Keychain (OSStatus \(status, privacy: .public))")
        }
    }
}
