import Foundation

/// In-memory placeholder implementation used for tests and previews.
/// Mirrors `MockChatService`'s role for `ChatServicing` — `NetworkAuthService`
/// is what the running app actually talks to.
actor MockAuthService: AuthServicing {
    private var currentUser: User
    private var registeredAccounts: [String: (user: User, password: String)] = [:] // keyed by lowercased email
    private var sessionChangeContinuation: AsyncStream<User>.Continuation?

    init(currentUser: User = User(id: UUID(), email: nil, displayName: nil)) {
        self.currentUser = currentUser
    }

    func restoreSession() async throws -> User {
        currentUser
    }

    func signUp(email: String, password: String, displayName: String?) async throws -> User {
        guard currentUser.email == nil else { throw AuthError.accountAlreadyClaimed }
        let key = email.lowercased()
        guard registeredAccounts[key] == nil else { throw AuthError.emailAlreadyExists }

        let claimed = User(id: currentUser.id, email: key, displayName: displayName)
        registeredAccounts[key] = (claimed, password)
        currentUser = claimed
        return claimed
    }

    func signIn(email: String, password: String) async throws -> AuthResult {
        let key = email.lowercased()
        guard let entry = registeredAccounts[key], entry.password == password else {
            throw AuthError.invalidCredentials
        }

        let previousUserID = currentUser.id
        let mergeAvailableFrom = (previousUserID != entry.user.id && currentUser.email == nil) ? previousUserID : nil
        currentUser = entry.user
        return AuthResult(
            user: entry.user,
            mergeAvailableFrom: mergeAvailableFrom,
            mergeToken: mergeAvailableFrom != nil ? "mock-merge-token" : nil
        )
    }

    func signOut() async throws {
        currentUser = User(id: UUID(), email: nil, displayName: nil)
    }

    func signOutEverywhere() async throws {
        try await signOut()
    }

    func mergeAccount(fromAccountID: User.ID, mergeToken: String?) async throws -> Int {
        // No chat data exists in this mock to move — chat wiring isn't
        // part of this phase (see Phase 3.5/3.7). `mergeToken` isn't
        // validated here; this mock isn't meant to reproduce the
        // backend's security logic, only its shape.
        0
    }

    func sessionChanges() async -> AsyncStream<User> {
        AsyncStream { continuation in
            sessionChangeContinuation = continuation
        }
    }

    /// Test-only: simulates `AuthenticatedAPIClient`'s silent anonymous
    /// fallback (Phase 3.7) — production code never calls this; it's how
    /// `AuthStateTests` verifies `AuthState` reacts to a session change it
    /// never explicitly asked for, without needing a real `URLSession`
    /// stub for something this mock can represent directly.
    func simulateSilentFallback(to user: User) {
        currentUser = user
        sessionChangeContinuation?.yield(user)
    }
}
