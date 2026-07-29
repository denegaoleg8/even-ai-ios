import Testing
import Foundation
@testable import EvenAI

/// `.serialized`: shares `StubURLProtocol`'s process-global state with
/// `AuthenticatedAPIClientTests` — see that suite's note.
@Suite("NetworkChatService (authenticated)", .serialized)
struct NetworkChatServiceTests {
    private func makeService(tokenStore: AuthTokenStoring = InMemoryAuthTokenStore()) -> (NetworkChatService, AuthenticatedAPIClient) {
        StubURLProtocol.reset()
        let client = AuthenticatedAPIClient(
            baseURL: URL(string: "https://example.com/api")!,
            session: StubURLProtocol.makeSession(),
            tokenStore: tokenStore
        )
        return (NetworkChatService(apiClient: client), client)
    }

    private static func jsonResponse(_ status: Int, _ object: [String: Any]) -> StubURLProtocol.StubResponse {
        StubURLProtocol.StubResponse(status: status, body: try! JSONSerialization.data(withJSONObject: object))
    }

    private static func chatJSON(id: UUID = UUID(), title: String = "Chat") -> [String: Any] {
        [
            "id": id.uuidString, "title": title,
            "createdAt": "2026-07-28T00:00:00.000Z", "updatedAt": "2026-07-28T00:00:00.000Z",
            "lastMessagePreview": NSNull(),
        ]
    }

    // MARK: - Authenticated chat

    @Test("fetchChats attaches the current access token, invisibly to the caller")
    func fetchChatsIsAuthenticated() async throws {
        let (service, client) = makeService()
        await client.installSession(accessToken: "valid-token", refreshToken: "valid-refresh")

        StubURLProtocol.handler = { request in
            let hasToken = request.value(forHTTPHeaderField: "Authorization") == "Bearer valid-token"
            return Self.jsonResponse(hasToken ? 200 : 401, ["chats": hasToken ? [Self.chatJSON()] : []])
        }

        let chats = try await service.fetchChats()
        #expect(chats.count == 1)
    }

    // MARK: - Automatic refresh + retry, invisible to the caller

    @Test("an expired access token triggers automatic refresh and the original call succeeds without the caller doing anything")
    func fetchChatsRecoversFromExpiredToken() async throws {
        let (service, client) = makeService()
        await client.installSession(accessToken: "expired-token", refreshToken: "still-good-refresh")
        let chatID = UUID()

        StubURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/auth/refresh") == true {
                return Self.jsonResponse(200, [
                    "accessToken": "fresh-token", "refreshToken": "fresh-refresh",
                    "account": ["id": UUID().uuidString, "email": NSNull(), "displayName": NSNull()],
                ])
            }
            let hasFreshToken = request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-token"
            return Self.jsonResponse(hasFreshToken ? 200 : 401, ["chats": hasFreshToken ? [Self.chatJSON(id: chatID)] : []])
        }

        // From this call site, there is no visible difference between a
        // token that was valid all along and one that had to be silently
        // refreshed first — same call, same success path.
        let chats = try await service.fetchChats()
        #expect(chats.first?.id == chatID)
    }

    // MARK: - Revoked / expired session — chat keeps working anyway

    @Test("a revoked refresh token falls back to an anonymous session and chat continues working")
    func fetchChatsContinuesAfterRevokedSession() async throws {
        let tokenStore = InMemoryAuthTokenStore()
        tokenStore.save(refreshToken: "revoked-refresh")
        let (service, client) = makeService(tokenStore: tokenStore)
        await client.installSession(accessToken: "expired-token", refreshToken: "revoked-refresh")

        StubURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/auth/refresh") == true {
                return Self.jsonResponse(401, ["error": ["code": "INVALID_REFRESH_TOKEN", "message": "no"]])
            }
            if request.url?.path.hasSuffix("/auth/device") == true {
                return Self.jsonResponse(200, [
                    "accessToken": "anonymous-token", "refreshToken": "anonymous-refresh",
                    "account": ["id": UUID().uuidString, "email": NSNull(), "displayName": NSNull()],
                ])
            }
            let hasAnonymousToken = request.value(forHTTPHeaderField: "Authorization") == "Bearer anonymous-token"
            return Self.jsonResponse(hasAnonymousToken ? 200 : 401, ["chats": []])
        }

        // "Cleanly transition to the signed-out state" concretely means:
        // this succeeds (with the anonymous account's — empty — list),
        // it does not throw and strand the caller.
        let chats = try await service.fetchChats()
        #expect(chats.isEmpty)
    }

    @Test("a request fails with a clear, typed error when the backend is genuinely unreachable — never a crash")
    func createChatFailsClearlyWhenBackendDown() async throws {
        let (service, _) = makeService()

        StubURLProtocol.handler = { _ in Self.jsonResponse(500, ["error": ["code": "INTERNAL_ERROR", "message": "down"]]) }

        await #expect(throws: AuthenticatedAPIClientError.self) {
            try await service.createChat(title: "New Chat")
        }
    }

    // MARK: - Restored session

    @Test("chat works immediately after a session is restored at launch")
    func chatWorksAfterRestoredSession() async throws {
        let tokenStore = InMemoryAuthTokenStore()
        tokenStore.save(refreshToken: "stored-refresh")
        let (service, client) = makeService(tokenStore: tokenStore)

        StubURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/auth/refresh") == true {
                return Self.jsonResponse(200, [
                    "accessToken": "restored-token", "refreshToken": "rotated-refresh",
                    "account": ["id": UUID().uuidString, "email": NSNull(), "displayName": NSNull()],
                ])
            }
            let hasToken = request.value(forHTTPHeaderField: "Authorization") == "Bearer restored-token"
            return Self.jsonResponse(hasToken ? 200 : 401, ["chats": []])
        }

        _ = try await client.recoverSession() // what RootView's launch-time restore triggers
        let chats = try await service.fetchChats() // a chat call made afterward, with no further setup
        #expect(chats.isEmpty)
    }

    // MARK: - Streaming (unchanged parsing, now routed through the authenticated client)

    @Test("streamReply parses SSE events correctly through the authenticated client")
    func streamReplyParsesEvents() async throws {
        let (service, client) = makeService()
        await client.installSession(accessToken: "valid-token", refreshToken: "valid-refresh")
        let chatID = UUID()
        let userMessageID = UUID()
        let assistantMessageID = UUID()

        let sse = """
        event: start
        data: {"chatId":"\(chatID.uuidString)","userMessage":{"id":"\(userMessageID.uuidString)","chatId":"\(chatID.uuidString)","role":"user","content":"hi","createdAt":"2026-07-28T00:00:00.000Z","status":"complete"}}

        event: delta
        data: {"content":"Hello"}

        event: done
        data: {"message":{"id":"\(assistantMessageID.uuidString)","chatId":"\(chatID.uuidString)","role":"assistant","content":"Hello","createdAt":"2026-07-28T00:00:01.000Z","status":"complete"}}


        """
        StubURLProtocol.handler = { _ in StubURLProtocol.StubResponse(status: 200, body: Data(sse.utf8)) }

        var events: [ChatStreamEvent] = []
        for try await event in service.streamReply(chatID: chatID, content: "hi") {
            events.append(event)
        }

        #expect(events.count == 3)
        if case .userMessageSaved(let message) = events[0] {
            #expect(message.id == userMessageID)
        } else {
            Issue.record("expected .userMessageSaved first")
        }
        if case .assistantDelta(let content) = events[1] {
            #expect(content == "Hello")
        } else {
            Issue.record("expected .assistantDelta second")
        }
        if case .assistantMessageSaved(let message) = events[2] {
            #expect(message.id == assistantMessageID)
        } else {
            Issue.record("expected .assistantMessageSaved third")
        }
    }

    @Test("streamReply surfaces a business-level error reported inside the stream")
    func streamReplySurfacesServerError() async throws {
        let (service, client) = makeService()
        await client.installSession(accessToken: "valid-token", refreshToken: "valid-refresh")

        let sse = """
        event: error
        data: {"error":{"code":"UPSTREAM_LLM_ERROR","message":"The model failed."}}


        """
        StubURLProtocol.handler = { _ in StubURLProtocol.StubResponse(status: 200, body: Data(sse.utf8)) }

        await #expect(throws: NetworkChatServiceError.self) {
            for try await _ in service.streamReply(chatID: UUID(), content: "hi") {}
        }
    }
}
