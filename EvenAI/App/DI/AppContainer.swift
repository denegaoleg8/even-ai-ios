import Foundation

/// Composition root: the single place that constructs concrete service
/// implementations and hands them out. `MockChatService`/`MockAuthService`
/// remain available for tests/previews, but the running app talks to the
/// real backend — nothing above this layer needed to change to make that
/// swap.
///
/// `apiClient` is constructed once here and shared by both authenticated
/// services — `authService` and `chatService`, as of Phase 3.5 — so
/// "signed in" is one consistent fact tracked in one place, not N
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
            chatService: NetworkChatService(apiClient: apiClient)
        )
    }()
}
