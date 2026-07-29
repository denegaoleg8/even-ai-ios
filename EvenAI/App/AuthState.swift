import Foundation
import Observation

/// App-wide authentication state — the single source of truth for "who
/// is currently signed in," shared via `.environment()` from
/// `EvenAIApp` exactly like `AppState`. Not a singleton: there is no
/// `static let shared` here, only a normal `@Observable` instance
/// constructed once and injected down the view hierarchy, the same
/// dependency-injection pattern used everywhere else in this app.
///
/// Owns both the state and the actions that mutate it (sign in/up/out,
/// restore) rather than being a passive value a ViewModel updates from
/// outside — a ViewModel calling `authService` directly and forgetting
/// to also update this object is exactly the kind of state-drift bug
/// this design rules out by construction.
@MainActor
@Observable
final class AuthState {
    private(set) var currentUser: User?
    private(set) var isRestoringSession = true

    private let authService: AuthServicing

    init(authService: AuthServicing = AppContainer.live.authService) {
        self.authService = authService
    }

    /// Called once, at launch. Never throws to its caller: a failure
    /// here (e.g. first launch, fully offline) just leaves `currentUser`
    /// nil — the rest of the app already has its own graceful
    /// network-failure handling (see `ChatListViewModel`/`ChatViewModel`'s
    /// `loadFailed`), so an unauthenticated launch state doesn't need to
    /// be a special case here too.
    func restoreSession() async {
        isRestoringSession = true
        defer { isRestoringSession = false }
        currentUser = try? await authService.restoreSession()
    }

    func signUp(email: String, password: String, displayName: String?) async throws {
        currentUser = try await authService.signUp(email: email, password: password, displayName: displayName)
    }

    @discardableResult
    func signIn(email: String, password: String) async throws -> AuthResult {
        let result = try await authService.signIn(email: email, password: password)
        currentUser = result.user
        return result
    }

    func signOut() async {
        try? await authService.signOut()
        currentUser = nil
    }

    func signOutEverywhere() async {
        try? await authService.signOutEverywhere()
        currentUser = nil
    }

    func mergeAccount(fromAccountID: User.ID) async throws -> Int {
        try await authService.mergeAccount(fromAccountID: fromAccountID)
    }
}
