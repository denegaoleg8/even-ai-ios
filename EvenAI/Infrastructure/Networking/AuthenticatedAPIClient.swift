import Foundation

/// The single networking entry point for every authenticated request in
/// the app. Owns the in-memory access token (never persisted — see
/// `AuthTokenStoring`) and the refresh-token lifecycle: on a 401, it
/// transparently refreshes and retries the original request once; on
/// launch, `restoreAccessToken()` proactively does the same thing from
/// whatever refresh token is in Keychain.
///
/// Every future authenticated service (Chat in Phase 3.5; Voice, Vision,
/// Glasses, cloud sync later) is expected to be constructed with the
/// *same* `AuthenticatedAPIClient` instance (via `AppContainer`), not
/// its own copy — sharing one instance is what makes "signed in" a
/// single, consistent fact across the whole app rather than N
/// independently-tracked copies of it. No feature should ever attach its
/// own `Authorization` header or implement its own refresh logic; that
/// duplication is exactly what this type exists to prevent.
///
/// An `actor`, not a class with locks: every mutation of `accessToken`
/// or `refreshTask` is already serialized by actor isolation, so the
/// single-flight refresh guard below needs no additional synchronization
/// primitive to be correct.
actor AuthenticatedAPIClient {
    private let baseURL: URL
    private let session: URLSession
    private let tokenStore: AuthTokenStoring

    private var accessToken: String?
    private var refreshTask: Task<User, Error>?

    init(
        baseURL: URL = BackendConfiguration.baseURL,
        session: URLSession = .shared,
        tokenStore: AuthTokenStoring = KeychainAuthTokenStore()
    ) {
        self.baseURL = baseURL
        self.session = session
        self.tokenStore = tokenStore
    }

    // MARK: - Token state

    /// Installs a brand-new session (from a successful device-auth,
    /// login, or signup call) — the in-memory access token and the
    /// persisted refresh token are the only two things that make up a
    /// session, and this is the only place either is written, keeping
    /// Keychain access centralized here rather than spread across every
    /// service that happens to mint a session.
    func installSession(accessToken: String, refreshToken: String) {
        self.accessToken = accessToken
        tokenStore.save(refreshToken: refreshToken)
    }

    /// Clears both the in-memory access token and the persisted refresh
    /// token — used by sign-out and by a refresh that itself fails
    /// (expired/revoked refresh token), so neither survives to be
    /// reused.
    func clearSession() {
        accessToken = nil
        tokenStore.clear()
    }

    /// The refresh token currently in Keychain, if any. Exposed only for
    /// `NetworkAuthService`'s logout call, which — unlike every other
    /// authenticated request — must send the refresh token in its body
    /// rather than rely on the Authorization header.
    func currentRefreshToken() -> String? {
        tokenStore.currentRefreshToken()
    }

    /// Proactively obtains a fresh access token + user from the stored
    /// refresh token, if one exists and is still valid. Returns nil (and
    /// clears Keychain) if there's no stored refresh token, or the
    /// backend rejects it as expired/revoked. Shares the same
    /// single-flight refresh path a reactive 401 mid-session uses — one
    /// place this logic can be wrong, not two.
    @discardableResult
    func restoreAccessToken() async -> User? {
        guard tokenStore.currentRefreshToken() != nil else { return nil }
        return try? await ensureRefreshed()
    }

    // MARK: - REST

    func get(_ path: String) async throws -> Data {
        try await send(path: path, method: "GET", body: nil)
    }

    func post(_ path: String, body: Data?) async throws -> Data {
        try await send(path: path, method: "POST", body: body)
    }

    func patch(_ path: String, body: Data) async throws -> Data {
        try await send(path: path, method: "PATCH", body: body)
    }

    @discardableResult
    func delete(_ path: String) async throws -> Data {
        try await send(path: path, method: "DELETE", body: nil)
    }

    /// Opens an authenticated streaming (SSE) connection. Attaches the
    /// current access token and refreshes once on a 401 before the
    /// stream is ever opened — the same as `send`, just returning raw
    /// bytes instead of buffered `Data`, since parsing the SSE format is
    /// a concern for the caller (e.g. `NetworkChatService`), not this
    /// generic transport layer. Not retried once bytes start flowing —
    /// see `NetworkChatService` for why a partially-consumed stream is
    /// never safe to silently retry.
    func streamBytes(path: String, body: Data) async throws -> (URLSession.AsyncBytes, URLResponse) {
        let request = try await makeRequest(path: path, method: "POST", body: body, accept: "text/event-stream")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                _ = try await ensureRefreshed()
                let retryRequest = try await makeRequest(path: path, method: "POST", body: body, accept: "text/event-stream")
                return try await session.bytes(for: retryRequest)
            }
            try Self.validateStatus(response)
            return (bytes, response)
        } catch let urlError as URLError {
            throw Self.classify(urlError)
        }
    }

    // MARK: - Request construction

    private func makeRequest(path: String, method: String, body: Data?, accept: String? = nil) async throws -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let accept {
            request.setValue(accept, forHTTPHeaderField: "Accept")
        }
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send(path: String, method: String, body: Data?) async throws -> Data {
        let request = try await makeRequest(path: path, method: method, body: body)

        do {
            let (data, response) = try await session.data(for: request)

            guard let http = response as? HTTPURLResponse else {
                throw AuthenticatedAPIClientError.invalidResponse
            }

            if http.statusCode == 401, accessToken != nil {
                // Only worth a refresh-and-retry if we actually sent a
                // token — a 401 on a call made with no token at all
                // (e.g. login, device) means invalid credentials, not an
                // expired session, and retrying would just loop.
                _ = try await ensureRefreshed()
                let retryRequest = try await makeRequest(path: path, method: method, body: body)
                let (retryData, retryResponse) = try await session.data(for: retryRequest)
                try Self.validate(retryResponse, data: retryData)
                return retryData
            }

            try Self.validate(response, data: data)
            return data
        } catch let urlError as URLError {
            throw Self.classify(urlError)
        }
    }

    // MARK: - Refresh (single-flight)

    /// If a refresh is already in flight, awaits *that* one instead of
    /// starting a second — concurrent requests that all hit a 401 at
    /// once trigger exactly one call to `/api/auth/refresh`, not N.
    @discardableResult
    private func ensureRefreshed() async throws -> User {
        if let existing = refreshTask {
            return try await existing.value
        }
        let task = Task { try await performRefresh() }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func performRefresh() async throws -> User {
        guard let refreshToken = tokenStore.currentRefreshToken() else {
            throw AuthenticatedAPIClientError.notAuthenticated
        }

        var request = URLRequest(url: baseURL.appending(path: "auth/refresh"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder.evenAI.encode(["refreshToken": refreshToken])

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AuthenticatedAPIClientError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                // The refresh token itself is no longer usable — expired
                // or revoked server-side. Clear it locally too, so we
                // don't keep retrying a token that will never work again.
                clearSession()
                throw AuthenticatedAPIClientError.sessionExpired
            }

            let decoded = try JSONDecoder.evenAI.decode(RefreshResponseDTO.self, from: data)
            accessToken = decoded.accessToken
            tokenStore.save(refreshToken: decoded.refreshToken)
            return decoded.account.toDomain()
        } catch let urlError as URLError {
            throw Self.classify(urlError)
        }
    }

    // MARK: - Response validation / error classification

    private static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AuthenticatedAPIClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let code = try? JSONDecoder().decode(APIErrorPayloadDTO.self, from: data).error.code
            throw AuthenticatedAPIClientError.http(status: http.statusCode, code: code)
        }
    }

    /// Status-only check, for the streaming path — the error body (if
    /// any) lives in the `AsyncBytes` sequence itself, and reading it
    /// here would mean consuming the stream just to fail, so a failed
    /// stream open surfaces without a backend error code attached.
    private static func validateStatus(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AuthenticatedAPIClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AuthenticatedAPIClientError.http(status: http.statusCode, code: nil)
        }
    }

    private static func classify(_ error: URLError) -> AuthenticatedAPIClientError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return .offline
        default:
            return .underlying(error.localizedDescription)
        }
    }
}

enum AuthenticatedAPIClientError: Error, Sendable, LocalizedError, Equatable {
    case notAuthenticated
    case sessionExpired
    case offline
    case http(status: Int, code: String?)
    case invalidResponse
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: "Not signed in."
        case .sessionExpired: "Your session has expired."
        case .offline: "No internet connection."
        case .http(let status, let code): "Request failed (HTTP \(status)\(code.map { ", \($0)" } ?? ""))."
        case .invalidResponse: "The server returned an unexpected response."
        case .underlying(let message): message
        }
    }
}

private struct RefreshResponseDTO: Decodable {
    let accessToken: String
    let refreshToken: String
    let account: AccountDTO
}

private struct APIErrorPayloadDTO: Decodable {
    struct Body: Decodable { let code: String; let message: String }
    let error: Body
}
