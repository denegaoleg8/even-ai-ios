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
///
/// `chatService` is `CachingChatService` wrapping `NetworkChatService` as
/// of Phase 3.9 — a SwiftData cache sits transparently in front of the
/// network, invisible to everything above this layer (`ChatListView`/
/// `ChatViewModel` only ever see the `ChatServicing` protocol). `chatCache`
/// exposes the same instance concretely, typed as `CachingChatService`,
/// purely so `AuthState` can call `invalidate()` on it — `ChatServicing`
/// itself deliberately has no such method, since invalidation isn't a
/// concept the network-only or mock implementations have any use for.
struct AppContainer: Sendable {
    let apiClient: AuthenticatedAPIClient
    let authService: AuthServicing
    let chatService: ChatServicing
    let chatCache: CachingChatService

    static let live: AppContainer = {
        let apiClient = AuthenticatedAPIClient()
        let cachingChatService = CachingChatService(wrapping: NetworkChatService(apiClient: apiClient))
        return AppContainer(
            apiClient: apiClient,
            authService: NetworkAuthService(apiClient: apiClient),
            chatService: cachingChatService,
            chatCache: cachingChatService
        )
    }()
}
