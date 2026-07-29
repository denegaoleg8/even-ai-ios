import Foundation

/// Composition root: the single place that constructs concrete service
/// implementations and hands them out. `MockChatService`/`MockAuthService`
/// remain available for tests/previews, but the running app talks to the
/// real backend — nothing above this layer needed to change to make that
/// swap.
///
/// `apiClient` is constructed once here and shared by every authenticated
/// service — `authService` today, `chatService` from Phase 3.5 onward —
/// so "signed in" is one consistent fact tracked in one place, not N
/// independently-held copies of an access token.
struct AppContainer: Sendable {
    let apiClient: AuthenticatedAPIClient
    let authService: AuthServicing
    let chatService: ChatServicing

    static let live: AppContainer = {
        let apiClient = AuthenticatedAPIClient()
        return AppContainer(
            apiClient: apiClient,
            authService: NetworkAuthService(apiClient: apiClient),
            // Not yet wired to apiClient — that's Phase 3.5. Chat
            // requests carry no auth today, which is why they'll 401
            // against the now-account-scoped backend until then.
            chatService: NetworkChatService()
        )
    }()
}
