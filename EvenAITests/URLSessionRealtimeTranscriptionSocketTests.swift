import Testing
import Foundation
@testable import EvenAI

/// Physical-device root-cause fix: `URLSessionRealtimeTranscriptionSocket
/// .connect()` used to build its WebSocket upgrade request straight from
/// `AuthenticatedAPIClient.makeWebSocketRequest(path:)` with NO attempt to
/// first ensure a valid session existed — unlike every other authenticated
/// call in this app, which gets that for free from `AuthenticatedAPIClient
/// .performOnce`'s reactive 401→recover→retry path. On a real device this
/// showed up as EVERY connection attempt (the first one AND all 5 bounded
/// reconnects) going out with no `Authorization` header at all, which the
/// backend correctly rejects with a raw, bodiless `401 Unauthorized`
/// during the WS upgrade — surfacing to iOS as `NSURLErrorDomain -1011`
/// ("bad response from the server" during the handshake).
///
/// These tests prove the fix directly, at the real seam (a genuine
/// `AuthenticatedAPIClient` + `URLSessionRealtimeTranscriptionSocket`
/// pair, only the underlying `URLSession` mocked via `StubURLProtocol` —
/// exactly the pattern `AuthenticatedAPIClientTests` already established),
/// without needing to intercept the actual WebSocket handshake itself
/// (which `URLProtocol`-based mocking doesn't reach): `connect()` returns
/// well before the WS task's own handshake outcome is known (see
/// `connect()`'s own doc comment), so verifying its observable SIDE
/// EFFECT on `apiClient` — a subsequent `makeWebSocketRequest(path:)` now
/// carrying a real `Authorization` header — is a faithful, direct proof
/// that credential propagation happened, independent of whatever the raw
/// socket layer does afterward.
///
/// `.serialized`: shares `StubURLProtocol`'s process-global handler/
/// request log with `AuthenticatedAPIClientTests`, same reasoning as that
/// suite's own `.serialized` attribute.
@MainActor
@Suite("URLSessionRealtimeTranscriptionSocket — credential propagation", .serialized)
struct URLSessionRealtimeTranscriptionSocketTests {
    private nonisolated static func accountJSON(id: UUID = UUID()) -> [String: Any] {
        ["id": id.uuidString, "email": NSNull(), "displayName": NSNull()]
    }

    private nonisolated static func deviceAuthResponse(accessToken: String, refreshToken: String) -> StubURLProtocol.StubResponse {
        StubURLProtocol.StubResponse(
            status: 200,
            body: try! JSONSerialization.data(withJSONObject: [
                "accessToken": accessToken,
                "refreshToken": refreshToken,
                "account": accountJSON(),
            ])
        )
    }

    private func makeAPIClient(tokenStore: AuthTokenStoring = InMemoryAuthTokenStore()) -> AuthenticatedAPIClient {
        StubURLProtocol.reset()
        return AuthenticatedAPIClient(
            baseURL: URL(string: "https://example.com/api")!,
            session: StubURLProtocol.makeSession(),
            tokenStore: tokenStore
        )
    }

    // MARK: - Anonymous-device session (the exact contract the physical
    // failure's own "fell back to an anonymous device session" trace
    // line refers to)

    @Test("the very first connection attempt — no prior session at all — recovers an anonymous device session and attaches its credential")
    func firstConnectionAttachesAnonymousDeviceCredential() async throws {
        let apiClient = makeAPIClient()
        StubURLProtocol.handler = { request in
            #expect(request.url?.path.hasSuffix("auth/device") == true)
            return Self.deviceAuthResponse(accessToken: "anon-token", refreshToken: "anon-refresh")
        }

        // Before connect(): exactly the state that produced the physical
        // failure — nothing installed yet, so this alone has no header.
        let requestBefore = await apiClient.makeWebSocketRequest(path: "realtime-transcription")
        #expect(requestBefore.value(forHTTPHeaderField: "Authorization") == nil)

        let socket = URLSessionRealtimeTranscriptionSocket(apiClient: apiClient, urlSession: .shared)
        _ = try await socket.connect()

        let requestAfter = await apiClient.makeWebSocketRequest(path: "realtime-transcription")
        #expect(requestAfter.value(forHTTPHeaderField: "Authorization") == "Bearer anon-token")
    }

    // MARK: - Already-authenticated (signed-in) session

    @Test("a connection attempt with an existing signed-in session refreshes and attaches THAT account's credential, not a fresh anonymous one")
    func connectionWithExistingSessionAttachesRefreshedCredential() async throws {
        let tokenStore = InMemoryAuthTokenStore()
        tokenStore.save(refreshToken: "existing-refresh")
        let apiClient = makeAPIClient(tokenStore: tokenStore)
        StubURLProtocol.handler = { request in
            #expect(request.url?.path.hasSuffix("auth/refresh") == true)
            return Self.deviceAuthResponse(accessToken: "refreshed-token", refreshToken: "new-refresh")
        }

        let socket = URLSessionRealtimeTranscriptionSocket(apiClient: apiClient, urlSession: .shared)
        _ = try await socket.connect()

        let request = await apiClient.makeWebSocketRequest(path: "realtime-transcription")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer refreshed-token")
    }

    // MARK: - Reconnect (not just the initial connection)

    @Test("a reconnect attempt — a fresh socket instance, same apiClient, exactly what OpenAIRealtimeTranscriber's bounded retry loop does — also attaches a valid Authorization header")
    func reconnectAttemptAlsoAttachesCredential() async throws {
        let apiClient = makeAPIClient()
        // A fixed response is enough here — each connect() attempt only
        // needs to succeed, not receive a DISTINCT token, and a plain
        // `var` counter mutated from `StubURLProtocol`'s `@Sendable`
        // handler isn't safe under strict concurrency.
        StubURLProtocol.handler = { _ in
            Self.deviceAuthResponse(accessToken: "reconnect-token", refreshToken: "reconnect-refresh")
        }

        let firstSocket = URLSessionRealtimeTranscriptionSocket(apiClient: apiClient, urlSession: .shared)
        _ = try await firstSocket.connect()
        let firstRequest = await apiClient.makeWebSocketRequest(path: "realtime-transcription")
        #expect(firstRequest.value(forHTTPHeaderField: "Authorization") != nil)

        let secondSocket = URLSessionRealtimeTranscriptionSocket(apiClient: apiClient, urlSession: .shared)
        _ = try await secondSocket.connect()
        let secondRequest = await apiClient.makeWebSocketRequest(path: "realtime-transcription")
        #expect(secondRequest.value(forHTTPHeaderField: "Authorization") != nil)
    }

    // MARK: - connect() never silently proceeds with a missing credential

    @Test("connect() throws — never silently proceeds with no credential attached — when session recovery itself fails")
    func connectThrowsWhenRecoveryFails() async throws {
        let apiClient = makeAPIClient()
        StubURLProtocol.handler = { _ in
            StubURLProtocol.StubResponse(
                status: 500,
                body: try! JSONSerialization.data(withJSONObject: ["error": ["code": "INTERNAL_ERROR", "message": "boom"]])
            )
        }
        let socket = URLSessionRealtimeTranscriptionSocket(apiClient: apiClient, urlSession: .shared)

        do {
            _ = try await socket.connect()
            Issue.record("expected connect() to throw when session recovery itself fails, not silently proceed")
        } catch {
            // Expected.
        }
    }
}
