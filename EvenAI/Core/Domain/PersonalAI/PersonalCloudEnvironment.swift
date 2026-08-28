import Foundation

/// Which kind of Personal AI Cloud is actually wired — so the app can never
/// imply durability it doesn't have.
///
/// - `.notConfigured` — **the production default today.** No external
///   provider. Memory lives only on this device (encrypted). Export and
///   local backup files are the only way to keep a copy elsewhere.
/// - `.simulated` — an in-process simulation (`MockPersonalCloudService`
///   over `InMemoryPersonalCloudBackend`). Used only in tests and in a
///   developer build explicitly launched with `-EvenAISimulatedCloud`. Its
///   "server" is RAM: data here does **not** survive an app relaunch,
///   reinstall, or device loss. The UI must say so.
/// - `.connected` — a real external `PersonalCloudService` (CloudKit /
///   hosted API) is wired. Only in this state may the UI say "synced" or
///   "backed up to the cloud".
enum PersonalCloudEnvironment: String, Sendable, Equatable, Codable {
    case notConfigured
    case simulated
    case connected

    /// True only when memory genuinely survives loss of this device.
    var providesDurability: Bool { self == .connected }

    var displayName: String {
        switch self {
        case .notConfigured: return "Not set up"
        case .simulated: return "Simulated (development)"
        case .connected: return "Connected"
        }
    }
}
