import Foundation
@testable import EvenAI

/// Every call fails — simulates a completely unreachable backend, or an
/// account state where nothing is expected to succeed.
actor FailingAuthService: AuthServicing {
    let errorToThrow: AuthError

    init(errorToThrow: AuthError = .serverUnavailable) {
        self.errorToThrow = errorToThrow
    }

    func restoreSession() async throws -> User { throw errorToThrow }
    func signUp(email: String, password: String, displayName: String?) async throws -> User { throw errorToThrow }
    func signIn(email: String, password: String) async throws -> AuthResult { throw errorToThrow }
    func signOut() async throws { throw errorToThrow }
    func signOutEverywhere() async throws { throw errorToThrow }
    func mergeAccount(fromAccountID: User.ID, mergeToken: String?) async throws -> Int { throw errorToThrow }
    func sessionChanges() async -> AsyncStream<User> { AsyncStream { _ in } }
}

/// In-memory `AuthTokenStoring` double — isolates tests from the real
/// Keychain (see `KeychainAuthTokenStoreTests` for coverage of the real
/// thing) so `AuthenticatedAPIClient` tests are fast, hermetic, and don't
/// leave state behind across runs.
final class InMemoryAuthTokenStore: AuthTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?

    func currentRefreshToken() -> String? {
        lock.withLock { token }
    }

    func save(refreshToken: String) {
        lock.withLock { token = refreshToken }
    }

    func clear() {
        lock.withLock { token = nil }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

/// A stubbed `URLProtocol` for testing `AuthenticatedAPIClient`'s actual
/// request/response/retry handling without a real network. Test-only
/// infrastructure — `nonisolated(unsafe)` static state here is what
/// `URLProtocol`'s class-based loading system requires; it is not a
/// pattern used anywhere in the app's own architecture. `@Suite(.serialized)`
/// on the tests that use it avoids cross-test interference from this
/// being process-global.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct StubResponse {
        let status: Int
        let body: Data
        /// Extra response headers beyond the always-present
        /// `Content-Type` — used to simulate `Retry-After`/
        /// `RateLimit-Reset` on a stubbed `429`, among other things.
        var headers: [String: String] = [:]

        init(status: Int, body: Data, headers: [String: String] = [:]) {
            self.status = status
            self.body = body
            self.headers = headers
        }
    }

    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> StubResponse)?
    nonisolated(unsafe) static var requestLog: [URLRequest] = []
    private static let logLock = NSLock()

    static func reset() {
        logLock.withLock {
            requestLog = []
        }
        handler = nil
    }

    static func recordedRequests() -> [URLRequest] {
        logLock.withLock { requestLog }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.logLock.withLock {
            Self.requestLog.append(request)
        }
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let result = handler(request)
        var headerFields = ["Content-Type": "application/json"]
        for (key, value) in result.headers { headerFields[key] = value }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: result.status,
            httpVersion: "HTTP/1.1",
            headerFields: headerFields
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        // Delivered across several `didLoad:` calls with a small real
        // delay between them, not one synchronous call — a genuinely
        // streamed connection never hands the whole body to
        // `URLSessionDataDelegate` in one shot. This turned out NOT to be
        // what caused `NetworkChatServiceTests.streamReplyParsesEvents`
        // to fail (confirmed by direct experiment: `bytes.lines` drops
        // blank lines identically whether delivered as one chunk or many,
        // with or without delays — the real cause and fix are in
        // `NetworkChatService.performStream`, which no longer uses
        // `.lines` at all). Kept anyway because it's still a more
        // faithful stand-in for a real connection than one atomic blob,
        // and it now exercises something that matters for the *new*
        // manual byte-buffering parser: a line (or a blank-line
        // separator) arriving split across two underlying reads has to
        // reassemble correctly, which a single-chunk delivery would never
        // test.
        let client = self.client
        Task {
            for chunk in Self.chunked(result.body) {
                client?.urlProtocol(self, didLoad: chunk)
                try? await Task.sleep(for: .milliseconds(1))
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    /// Splits on line boundaries (keeping each `\n` with the line before
    /// it) rather than fixed-size byte windows — deliberately preserves
    /// blank lines as their own single-byte ("\n") chunk instead of
    /// merging them into a neighboring chunk, so a line split across two
    /// deliveries is actually exercised. Falls back to delivering
    /// non-line-structured bodies (ordinary JSON REST responses) in one
    /// piece; splitting those wouldn't change anything since
    /// `URLSession.data(for:)` buffers the whole response before
    /// returning regardless.
    private static func chunked(_ data: Data) -> [Data] {
        guard let text = String(data: data, encoding: .utf8), text.contains("\n") else {
            return [data]
        }
        var chunks: [Data] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == "\n" {
                chunks.append(Data(current.utf8))
                current = ""
            }
        }
        if !current.isEmpty {
            chunks.append(Data(current.utf8))
        }
        return chunks
    }

    override func stopLoading() {}

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}
