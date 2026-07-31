import Testing
import Foundation
@testable import EvenAI

/// End-to-end coverage for Phase 3.7's session-sync fix, exercising the
/// real `AuthenticatedAPIClient` recovery path (not `MockAuthService`'s
/// simulated hook — see `AuthStateTests.reactsToSilentSessionChange` for
/// that faster, more isolated version of the same contract). `.serialized`
/// for the same reason as `AuthenticatedAPIClientTests`/
/// `NetworkChatServiceTests`: shared `StubURLProtocol` process-global state.
@MainActor
@Suite("AuthState session sync (real client)", .serialized)
struct AuthStateSessionSyncTests {
    // nonisolated: this suite is @MainActor (needed to construct/observe
    // AuthState directly), but StubURLProtocol.handler is a synchronous
    // @Sendable closure invoked from a nonisolated context — same reason
    // AuthenticatedAPIClientTests/NetworkChatServiceTests's own
    // jsonResponse helpers had to be called via `Self.` there too.
    private nonisolated static func jsonResponse(_ status: Int, _ object: [String: Any]) -> StubURLProtocol.StubResponse {
        StubURLProtocol.StubResponse(status: status, body: try! JSONSerialization.data(withJSONObject: object))
    }

    @Test("a chat-style request's silent anonymous fallback (revoked refresh token) reaches AuthState with no explicit call")
    func chatRequestFallbackUpdatesAuthState() async throws {
        StubURLProtocol.reset()
        let tokenStore = InMemoryAuthTokenStore()
        tokenStore.save(refreshToken: "revoked-refresh")
        let apiClient = AuthenticatedAPIClient(
            baseURL: URL(string: "https://example.com/api")!,
            session: StubURLProtocol.makeSession(),
            tokenStore: tokenStore
        )
        await apiClient.installSession(accessToken: "expired-token", refreshToken: "revoked-refresh")

        let authState = AuthState(authService: NetworkAuthService(apiClient: apiClient))
        // Give the session-changes subscription a moment to attach before
        // the event we're testing fires, matching real launch timing
        // where AuthState exists well before any chat request runs.
        try await Task.sleep(for: .milliseconds(20))

        let anonymousAccountID = UUID()
        StubURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/auth/refresh") == true {
                return Self.jsonResponse(401, ["error": ["code": "INVALID_REFRESH_TOKEN", "message": "no"]])
            }
            if request.url?.path.hasSuffix("/auth/device") == true {
                return Self.jsonResponse(200, [
                    "accessToken": "anonymous-token", "refreshToken": "anonymous-refresh",
                    "account": ["id": anonymousAccountID.uuidString, "email": NSNull(), "displayName": NSNull()],
                ])
            }
            let hasAnonymousToken = request.value(forHTTPHeaderField: "Authorization") == "Bearer anonymous-token"
            return Self.jsonResponse(hasAnonymousToken ? 200 : 401, ["chats": []])
        }

        // This is exactly what NetworkChatService.fetchChats() does under
        // the hood — a plain authenticated GET, no auth-specific call
        // anywhere in sight from the caller's side.
        _ = try await apiClient.get("chats")

        try await Task.sleep(for: .milliseconds(50))

        #expect(authState.currentUser?.id == anonymousAccountID)
    }
}
