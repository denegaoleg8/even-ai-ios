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
    func mergeAccount(fromAccountID: User.ID) async throws -> Int { throw errorToThrow }
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
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: result.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}
