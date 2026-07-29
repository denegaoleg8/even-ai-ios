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
    case sessionExpired
    case sessionRevoked
    case offline
    case serverUnavailable
    case unknown

    var errorDescription: String? {
        switch self {
        case .invalidCredentials: "Invalid email or password."
        case .emailAlreadyExists: "An account with this email already exists."
        case .accountAlreadyClaimed: "This account already has credentials."
        case .accountNotFound: "That account couldn't be found."
        case .cannotMergeClaimedAccount: "That account already belongs to someone else."
        case .sessionExpired: "Your session has expired. Please sign in again."
        case .sessionRevoked: "You've been signed out."
        case .offline: "No internet connection."
        case .serverUnavailable: "Couldn't reach the server. Please try again."
        case .unknown: "Something went wrong. Please try again."
        }
    }
}
