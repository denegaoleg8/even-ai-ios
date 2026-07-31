import Foundation

/// Abstraction over authentication — identity, sessions, and account
/// lifecycle. `NetworkAuthService` is the live implementation, talking
/// to the real backend's `/api/auth/*` endpoints; `MockAuthService` is
/// an in-memory placeholder for tests and previews, mirroring the same
/// relationship `ChatServicing`/`NetworkChatService`/`MockChatService`
/// already establish.
///
/// Deliberately does not expose tokens, refresh, or device registration
/// as separate protocol methods — those are transport-level concerns
/// owned by `AuthenticatedAPIClient` (refresh) and each implementation's
/// own use of `DeviceIdentityStoring` (device identity), not something a
/// caller should ever need to think about directly.
protocol AuthServicing: Sendable {
    /// Resolves to a valid, usable session on every call: a stored,
    /// still-valid refresh token's account if one exists, otherwise this
    /// device's anonymous account (minted on first-ever launch, reused
    /// after). Throws only when neither path is reachable at all — no
    /// stored session AND the backend can't be reached to mint an
    /// anonymous one (e.g. first launch, fully offline). Callers should
    /// treat that as "not signed in yet," not a fatal condition — the
    /// app must remain usable.
    func restoreSession() async throws -> User

    /// Claims the caller's current (anonymous) account with real
    /// credentials. Same account id before and after — nothing to
    /// migrate.
    func signUp(email: String, password: String, displayName: String?) async throws -> User

    func signIn(email: String, password: String) async throws -> AuthResult

    /// "Logout current device."
    func signOut() async throws

    /// "Logout everywhere."
    func signOutEverywhere() async throws

    /// Reassigns `fromAccountID`'s chats to the currently signed-in
    /// account (see `AuthResult.mergeAvailableFrom`). Returns the number
    /// of conversations moved. Safe to call more than once — the backend
    /// endpoint is idempotent by construction. `mergeToken` should be
    /// `AuthResult.mergeToken` from the sign-in that offered this merge,
    /// when available (see that property) — `nil` is valid too (merging
    /// later, past the token's window) and falls back to the backend's
    /// original ownership check.
    func mergeAccount(fromAccountID: User.ID, mergeToken: String?) async throws -> Int

    /// Broadcasts the resolved identity every time the underlying session
    /// is (re-)established, including *without* the caller asking for it
    /// — e.g. a chat request silently recovering after its refresh token
    /// was revoked. `AuthState` is the one subscriber, and this is what
    /// lets it stay accurate without the caller ever polling or the app
    /// needing a restart (see `AuthenticatedAPIClient.sessionChanges()`,
    /// which `NetworkAuthService` delegates straight to).
    func sessionChanges() async -> AsyncStream<User>
}
