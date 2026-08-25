import Foundation

/// Domain-level authentication errors — meaningful to every caller
/// (ViewModels, `AuthState`) regardless of which `AuthServicing`
/// implementation produced them. `NetworkAuthService` maps transport-
/// level failures (HTTP status + backend error code, or a connectivity
/// problem) into these; `MockAuthService` throws them directly.
enum AuthError: Error, Sendable, LocalizedError, Equatable {
    case invalidCredentials
    case emailAlreadyExists
    case accountAlreadyClaimed
    case accountNotFound
    case cannotMergeClaimedAccount
    /// The backend's optional proof-of-eligibility for a merge (see
    /// `AuthResult.mergeToken`) was present but didn't check out — wrong,
    /// tampered, or past its short window. Distinct from
    /// `cannotMergeClaimedAccount`: this doesn't mean the merge itself is
    /// invalid, just that this specific attempt needs a fresh sign-in to
    /// retry (a new `mergeToken`), or can omit it and rely on the
    /// backend's other check instead.
    case invalidMergeToken
    case sessionExpired
    case sessionRevoked
    case offline
    case serverUnavailable
    /// The backend rate-limited a session-recovery attempt (`/auth/device`
    /// — see `AuthenticatedAPIClientError.rateLimited`'s own doc
    /// comment). `retryAfterSeconds` is the backend's own signal, never
    /// invented client-side. Deliberately distinct from
    /// `.serverUnavailable`: the backend IS reachable and working, it's
    /// just declining this specific request kind for a known, bounded
    /// time — a truthful, temporary-and-bounded message, not a generic
    /// "something's down" one.
    case rateLimited(retryAfterSeconds: Int)
    case unknown

    var errorDescription: String? {
        switch self {
        case .invalidCredentials: "Invalid email or password."
        case .emailAlreadyExists: "An account with this email already exists."
        case .accountAlreadyClaimed: "This account already has credentials."
        case .accountNotFound: "That account couldn't be found."
        case .cannotMergeClaimedAccount: "That account already belongs to someone else."
        case .invalidMergeToken: "This merge request has expired. Please try merging again."
        case .sessionExpired: "Your session has expired. Please sign in again."
        case .sessionRevoked: "You've been signed out."
        case .offline: "No internet connection."
        case .serverUnavailable: "Couldn't reach the server. Please try again."
        case .rateLimited(let seconds): "Session temporarily unavailable. Try again in \(seconds)s."
        case .unknown: "Something went wrong. Please try again."
        }
    }
}
