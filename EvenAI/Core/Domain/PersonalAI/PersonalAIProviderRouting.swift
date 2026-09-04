import Foundation

/// Stable identity for a tier in the Personal AI provider router —
/// diagnostic-only labels for "which slot was attempted," independent of
/// `PersonalAIGenerationResult.Provider` (which vendor actually answered a
/// given turn). Deliberately not named after any specific vendor: this is
/// the seam a future remote/local tier slots into, not an Apple-specific
/// concept. No case here implies a working provider exists yet —
/// `remoteCapableProvider` and `localGenerativeProvider` are reserved
/// identities for tiers this router can compose later.
enum PersonalAIProviderIdentity: String, Sendable {
    case onDeviceFoundationModel
    case remoteCapableProvider
    case localGenerativeProvider
    case heuristic
}

/// How a tier's failure should influence routing. `FallbackPersonalAIModelProvider`
/// classifies any thrown `Error` into one of these categories for
/// diagnostics; a tier may also throw one of these cases directly to be
/// explicit about which category applies — the router treats every case
/// the same way (fall through to the next tier), the distinction exists
/// for observability and future policy (e.g. only retrying `.transientFailure`),
/// not for different routing behavior today.
enum PersonalAIProviderOutcome: Error, Sendable {
    /// This tier cannot run right now (e.g. the underlying model/service
    /// isn't ready or isn't configured) — an expected condition, not a bug.
    case unavailable(reason: String)
    /// Looked runnable but failed in a way that might succeed elsewhere or
    /// on a later attempt (e.g. a generation-time SDK/network error).
    case transientFailure(reason: String)
    /// Failed in a way unlikely to be tier-specific (e.g. the request
    /// itself was rejected). Still falls through — the router has no
    /// tier-independent way to "fix" the request — but is logged
    /// distinctly for future policy (e.g. not retrying at all).
    case hardFailure(reason: String)
    /// This tier fundamentally cannot serve this kind of request (e.g. a
    /// future tool-calling request against a tier with no tool support).
    case unsupported(reason: String)
}
