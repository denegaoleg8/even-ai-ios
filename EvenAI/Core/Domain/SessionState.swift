import Foundation

/// What kind of credential a resolved session carries — never a
/// meaningfully different CONTRACT server-side (see
/// `AuthenticatedAPIClient`'s own doc comment: every backend route this
/// app calls — Chat, Glasses Chat, realtime transcription, suggested
/// replies — accepts either kind identically, verified via
/// `getSessionById`/`verifyAccessToken` with no account-type branch
/// anywhere in the backend). This distinction exists purely for
/// observability (`SESSION_CREDENTIAL_AVAILABLE type=`) and UI (Settings
/// shows "Sign In" only for `.anonymous`), never to gate feature access.
enum SessionCredentialType: String, Sendable {
    case anonymous
    case authenticated
}

/// Why a session-recovery attempt failed — classified so a genuinely
/// transient condition (rate-limited, backend unreachable, offline)
/// never gets treated the same as a definitively invalid credential.
/// This distinction is what fixes a real bug found auditing the session
/// lifecycle: `AuthenticatedAPIClient`'s refresh-recovery step used to
/// clear the stored refresh token on ANY non-2xx `/auth/refresh`
/// response — including a transient 500 or network hiccup — silently
/// discarding a perfectly good, still-valid credential and forcing an
/// unnecessary anonymous-fallback attempt (which itself may be rate-
/// limited, compounding the problem). Only `.invalidCredential` ever
/// triggers that self-heal (see `AuthenticatedAPIClient
/// .performRefresh(refreshToken:)`).
enum SessionRecoveryFailureReason: Sendable, Equatable {
    /// The backend explicitly rejected the credential as invalid,
    /// expired, or revoked (a definitive 401) — safe to clear and fall
    /// back to anonymous recovery.
    case invalidCredential
    /// The backend is rejecting requests due to rate limiting (429) —
    /// never a credential problem; never self-heals by clearing
    /// anything, since the credential itself may be perfectly fine.
    case rateLimited
    /// A backend/network failure that isn't a credential judgment at all
    /// (5xx, timeout, unreachable, malformed response).
    case backendUnavailable
    /// No network path was even attempted (airplane mode, no
    /// connectivity).
    case offline
    case unknown

    var underlyingDescription: String {
        switch self {
        case .invalidCredential: "invalidCredential"
        case .rateLimited: "rateLimited"
        case .backendUnavailable: "backendUnavailable"
        case .offline: "offline"
        case .unknown: "unknown"
        }
    }
}

/// The one authoritative, observable session state
/// `AuthenticatedAPIClient` publishes at every transition (Section G
/// requirement: "session state must be observable"). Every consumer —
/// Chat, Live Translation, Settings — reads this SAME state rather than
/// each independently inferring "is there a credential right now" from
/// its own last network call's outcome.
enum SessionState: Sendable, Equatable, CustomStringConvertible {
    /// Nothing has been resolved yet this process — the state before the
    /// very first `recoverSession()` call ever starts.
    case unknown
    /// A recovery attempt (refresh or anonymous device-auth) is
    /// currently in flight.
    case recovering
    /// A usable credential is attached and ready to use.
    case ready(SessionCredentialType)
    /// The most recent recovery attempt failed — no usable credential is
    /// currently attached. Distinct from `.unknown`: this means recovery
    /// was genuinely ATTEMPTED and did not succeed, not merely "hasn't
    /// been tried yet."
    case failed(SessionRecoveryFailureReason)

    /// A compact, trace-friendly rendering — never a raw Swift enum
    /// dump, which would bury `SESSION_STATE_PUBLISHED state=` lines in
    /// fully-qualified type names.
    var description: String {
        switch self {
        case .unknown: "unknown"
        case .recovering: "recovering"
        case .ready(let type): "ready(\(type.rawValue))"
        case .failed(let reason): "failed(\(reason.underlyingDescription))"
        }
    }
}
