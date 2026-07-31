import Foundation
import Observation

@MainActor
@Observable
final class SettingsViewModel {
    var appearance: AppearanceMode = .system

    private let deviceIdentityStore: DeviceIdentityStoring

    init(deviceIdentityStore: DeviceIdentityStoring = KeychainDeviceIdentityStore()) {
        self.deviceIdentityStore = deviceIdentityStore
    }

    var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    /// The same stable, per-device Keychain UUID `AuthenticatedAPIClient`
    /// sends as `deviceId` in `/api/auth/device` — shown here (support
    /// requests, debugging a specific install) rather than fabricated.
    var deviceID: String {
        deviceIdentityStore.currentDeviceID().uuidString
    }

    /// Static, not fetched: there is no subscription/billing system in
    /// this app yet — the backend's `accounts` table has a `settings`/
    /// subscription column reserved for one (see `src/auth/db.js`), but
    /// nothing populates or exposes it over the API today
    /// (`toPublicAccount` deliberately never returns it). Every account
    /// really is on the one tier that exists, so this isn't a placeholder
    /// pretending to be real data — it's the whole truth as it stands.
    var subscriptionTier: String { "Free" }
}
