import Foundation

/// Development/test-only remote Personal AI provider gate — the ONLY
/// thing standing between the existing, already-deployed, already
/// end-to-end-tested remote path (`RemotePersonalAIModelProvider` +
/// `OpenAIResponsesTransport`, proven against the real Worker + OpenAI in
/// a controlled one-request smoke test) and `PersonalAIContainer.live`.
///
/// **Release builds get hardcoded `false`/`nil`/`nil` here — no runtime
/// check, no environment read, nothing to bypass.** `DevEnvironmentRemoteAuth`
/// (the type that actually reads the app→proxy credential) is `#if DEBUG`-only
/// below and does not exist in a Release binary at all — there is no way
/// for a Release build to construct a working remote tier no matter what
/// arguments or environment it launches with.
///
/// Even in DEBUG this defaults OFF: nothing enables it unless the
/// developer explicitly passes `-EvenAIDevRemotePersonalAI` as a launch
/// argument — the same mechanism `PersonalAIContainer.live` already uses
/// for `-EvenAISimulatedCloud`, so this follows an existing, reviewed
/// pattern rather than inventing a new one.
///
/// Two independent, deliberately separate pieces of local configuration,
/// matching the app→proxy / proxy→OpenAI trust-domain split documented on
/// `RemotePersonalAIModelProvider`:
/// - `isEnabled` — a plain on/off switch (a launch argument, never a
///   secret);
/// - `auth` — the actual app→proxy credential, read at runtime from an
///   environment variable (`EVENAI_DEV_APP_PROXY_SHARED_SECRET`).
///
/// Both the launch argument and the environment variable are set once,
/// locally, in the Xcode scheme's Run configuration — which this
/// project's `xcodegen`-generated `.xcodeproj` is already gitignored
/// (regenerated from `project.yml`), so neither the flag nor the
/// credential is ever committed, ever appears in Swift source,
/// `Info.plist`, `project.yml`, an xcconfig, an entitlement,
/// `UserDefaults`, or any file this repository tracks.
///
/// Enabling `isEnabled` with no credential present is safe by
/// construction, not by an extra check here: `DevEnvironmentRemoteAuth.currentToken()`
/// returning `nil` (unset) is exactly what already makes
/// `RemotePersonalAIModelProvider.generate` throw `.unavailable` before
/// ever calling the transport — existing, already-tested behavior. This
/// file adds no new fail-closed logic of its own; it only decides whether
/// the remote tier exists in the router at all (see
/// `PersonalAIProviderComposition`).
enum PersonalAIRemoteDevFlag {
    #if DEBUG
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-EvenAIDevRemotePersonalAI")
    }
    static var auth: (any PersonalAIRemoteAuthorizing)? { DevEnvironmentRemoteAuth() }
    static var transport: (any PersonalAIRemoteTransport)? { OpenAIResponsesTransport(proxyURL: proxyURL) }
    #else
    static var isEnabled: Bool { false }
    static var auth: (any PersonalAIRemoteAuthorizing)? { nil }
    static var transport: (any PersonalAIRemoteTransport)? { nil }
    #endif

    /// The deployed Personal AI proxy Worker's public endpoint. Not a
    /// secret — the Worker enforces its own app→proxy auth, and OpenAI's
    /// key never leaves it; this URL alone grants no access to anything.
    /// Referenced only from the `#if DEBUG` branch above.
    static let proxyURL = URL(string: "https://evenai-personal-ai-proxy.evenai-personal-ai-proxy.workers.dev/personal-ai/generate")!
}

#if DEBUG
/// Development-only credential source for the app→proxy trust boundary —
/// never the OpenAI key (the deployed proxy alone holds that; see
/// `cloudflare/personal-ai-proxy/src/openai.ts`). Reads a value the
/// developer places in the Xcode scheme's Environment Variables; never a
/// literal in source, never persisted by this app, never logged.
struct DevEnvironmentRemoteAuth: PersonalAIRemoteAuthorizing {
    func currentToken() async -> String? {
        ProcessInfo.processInfo.environment["EVENAI_DEV_APP_PROXY_SHARED_SECRET"]
    }
}
#endif
