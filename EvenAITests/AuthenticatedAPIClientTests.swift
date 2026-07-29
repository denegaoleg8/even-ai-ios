import Testing
import Foundation
@testable import EvenAI

/// `.serialized`: these tests drive `StubURLProtocol`'s process-global
/// handler/request log, which would race if Swift Testing's default
/// parallel execution interleaved them.
@Suite("AuthenticatedAPIClient", .serialized)
struct AuthenticatedAPIClientTests {
    private func makeClient(tokenStore: AuthTokenStoring = InMemoryAuthTokenStore()) -> AuthenticatedAPIClient {
        StubURLProtocol.reset()
        return AuthenticatedAPIClient(
            baseURL: URL(string: "https://example.com/api")!,
            session: StubURLProtocol.makeSession(),
            tokenStore: tokenStore
        )
    }

    private static func jsonResponse(_ status: Int, _ object: [String: Any]) -> StubURLProtocol.StubResponse {
        StubURLProtocol.StubResponse(status: status, body: try! JSONSerialization.data(withJSONObject: object))
    }

    private static func accountJSON(id: UUID = UUID(), email: String? = nil) -> [String: Any] {
        ["id": id.uuidString, "email": email as Any, "displayName": NSNull()]
    }

    // MARK: - Authorization header

    @Test("no Authorization header is sent when there's no access token")
    func noHeaderWithoutToken() async throws {
        let client = makeClient()
        StubURLProtocol.handler = { _ in Self.jsonResponse(200, ["ok": true]) }

        _ = try await client.get("chats")

        let request = StubURLProtocol.recordedRequests().first
        #expect(request?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("Authorization header carries the installed access token")
    func headerCarriesToken() async throws {
        let client = makeClient()
        StubURLProtocol.handler = { _ in Self.jsonResponse(200, ["ok": true]) }

        await client.installSession(accessToken: "abc123", refreshToken: "refresh-1")
        _ = try await client.get("chats")

        let request = StubURLProtocol.recordedRequests().last
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer abc123")
    }

    // MARK: - 401 → refresh → retry

    @Test("a 401 triggers exactly one refresh and retries the original request once")
    func refreshesOnceAndRetries() async throws {
        let tokenStore = InMemoryAuthTokenStore()
        tokenStore.save(refreshToken: "old-refresh")
        let client = makeClient(tokenStore: tokenStore)
        await client.installSession(accessToken: "expired-token", refreshToken: "old-refresh")

        let refreshCount = Counter()
        StubURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/auth/refresh") == true {
                refreshCount.increment()
                return Self.jsonResponse(200, [
                    "accessToken": "fresh-token",
                    "refreshToken": "fresh-refresh",
                    "account": Self.accountJSON(),
                ])
            }
            let hasFreshToken = request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-token"
            return Self.jsonResponse(hasFreshToken ? 200 : 401, ["ok": hasFreshToken])
        }

        let data = try await client.get("chats")
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Bool]

        #expect(decoded?["ok"] == true)
        #expect(refreshCount.value == 1)
        #expect(tokenStore.currentRefreshToken() == "fresh-refresh")
    }

    @Test("concurrent requests that all hit a 401 share a single refresh call")
    func singleFlightRefresh() async throws {
        let tokenStore = InMemoryAuthTokenStore()
        tokenStore.save(refreshToken: "old-refresh")
        let client = makeClient(tokenStore: tokenStore)
        await client.installSession(accessToken: "expired-token", refreshToken: "old-refresh")

        let refreshCount = Counter()
        StubURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/auth/refresh") == true {
                refreshCount.increment()
                // A small artificial delay widens the race window so
                // concurrent callers are actually likely to overlap
                // rather than happening to run sequentially by luck.
                Thread.sleep(forTimeInterval: 0.05)
                return Self.jsonResponse(200, [
                    "accessToken": "fresh-token",
                    "refreshToken": "fresh-refresh",
                    "account": Self.accountJSON(),
                ])
            }
            let hasFreshToken = request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-token"
            return Self.jsonResponse(hasFreshToken ? 200 : 401, ["ok": hasFreshToken])
        }

        async let first = client.get("chats")
        async let second = client.get("chats")
        async let third = client.get("chats")
        _ = try await (first, second, third)

        #expect(refreshCount.value == 1)
    }

    @Test("a refresh that itself fails throws sessionExpired and clears local state")
    func refreshFailureClearsSession() async throws {
        let tokenStore = InMemoryAuthTokenStore()
        tokenStore.save(refreshToken: "revoked-refresh")
        let client = makeClient(tokenStore: tokenStore)
        await client.installSession(accessToken: "expired-token", refreshToken: "revoked-refresh")

        StubURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/auth/refresh") == true {
                return Self.jsonResponse(401, ["error": ["code": "INVALID_REFRESH_TOKEN", "message": "no"]])
            }
            return Self.jsonResponse(401, ["error": ["code": "UNAUTHORIZED", "message": "no"]])
        }

        await #expect(throws: AuthenticatedAPIClientError.self) {
            try await client.get("chats")
        }
        #expect(tokenStore.currentRefreshToken() == nil)
    }

    // MARK: - restoreAccessToken

    @Test("restoreAccessToken returns nil when there's no stored refresh token")
    func restoreWithNoStoredToken() async {
        let client = makeClient()
        let user = await client.restoreAccessToken()
        #expect(user == nil)
    }

    @Test("restoreAccessToken succeeds and installs a fresh session from a stored refresh token")
    func restoreWithStoredToken() async throws {
        let tokenStore = InMemoryAuthTokenStore()
        tokenStore.save(refreshToken: "stored-refresh")
        let client = makeClient(tokenStore: tokenStore)
        let accountID = UUID()

        StubURLProtocol.handler = { _ in
            Self.jsonResponse(200, [
                "accessToken": "restored-token",
                "refreshToken": "rotated-refresh",
                "account": Self.accountJSON(id: accountID),
            ])
        }

        let user = await client.restoreAccessToken()
        #expect(user?.id == accountID)
        #expect(tokenStore.currentRefreshToken() == "rotated-refresh")

        // The restored access token is actually in effect for subsequent calls.
        StubURLProtocol.handler = { request in
            let hasToken = request.value(forHTTPHeaderField: "Authorization") == "Bearer restored-token"
            return Self.jsonResponse(hasToken ? 200 : 401, ["ok": hasToken])
        }
        _ = try await client.get("chats")
        let lastRequest = StubURLProtocol.recordedRequests().last
        #expect(lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer restored-token")
    }

    // MARK: - clearSession

    @Test("clearSession removes both the in-memory access token and the stored refresh token")
    func clearSessionClearsEverything() async {
        let tokenStore = InMemoryAuthTokenStore()
        let client = makeClient(tokenStore: tokenStore)
        await client.installSession(accessToken: "token", refreshToken: "refresh")

        await client.clearSession()

        #expect(tokenStore.currentRefreshToken() == nil)
        StubURLProtocol.handler = { request in
            Self.jsonResponse(request.value(forHTTPHeaderField: "Authorization") == nil ? 200 : 401, ["ok": true])
        }
        _ = try? await client.get("chats")
        #expect(StubURLProtocol.recordedRequests().last?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    // MARK: - Offline

    @Test("a connectivity failure is classified as offline, not a generic error")
    func offlineIsClassified() async {
        // A dedicated failing-transport session, not StubURLProtocol —
        // this simulates no connectivity at all (didFailWithError),
        // distinct from StubURLProtocol's "backend responded" stubbing.
        let offlineSession = OfflineFailingSession.makeSession()
        let offlineClient = AuthenticatedAPIClient(
            baseURL: URL(string: "https://example.com/api")!,
            session: offlineSession,
            tokenStore: InMemoryAuthTokenStore()
        )

        await #expect(throws: AuthenticatedAPIClientError.offline) {
            try await offlineClient.get("chats")
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.withLock { _value } }
    func increment() { lock.withLock { _value += 1 } }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

/// A second stub protocol, dedicated to simulating a connectivity
/// failure (`didFailWithError`) rather than a handled HTTP response —
/// kept separate from `StubURLProtocol` so the two failure modes (a
/// backend that responds vs. no connectivity at all) can't be confused.
private final class OfflineFailingSession: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineFailingSession.self]
        return URLSession(configuration: configuration)
    }
}
