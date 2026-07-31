import Foundation

/// The single networking entry point for every authenticated request in
/// the app. Owns the in-memory access token (never persisted — see
/// `AuthTokenStoring`) and the whole session-recovery lifecycle: on a
/// 401, it transparently recovers and retries the original request once;
/// on launch, `recoverSession()` does the same thing proactively.
///
/// Recovery (Phase 3.5) is two-tiered, not just "refresh or fail": if the
/// stored refresh token is missing, expired, or revoked, this falls back
/// to re-authenticating as the device's anonymous session rather than
/// surfacing a dead end. That's what makes "if refresh fails, cleanly
/// transition to the signed-out state" and "continue chatting" true at
/// the same time — a chat request that outlives its session doesn't
/// throw a raw auth error at the caller, it transparently continues
/// against a usable (now-anonymous) session. `AuthState` learns about an
/// explicit sign-out or sign-in the normal way, by awaiting the call it
/// made — and, as of Phase 3.7, also learns about *this* reactive,
/// mid-session fallback the moment it happens, by subscribing to
/// `sessionChanges()` below, rather than continuing to report a
/// signed-in identity that's no longer real until something else
/// happened to call `recoverSession()` again.
///
/// Every future authenticated service (Chat as of this phase; Voice,
/// Vision, Glasses, cloud sync later) is expected to be constructed with
/// the *same* `AuthenticatedAPIClient` instance (via `AppContainer`), not
/// its own copy — sharing one instance is what makes "signed in" a
/// single, consistent fact across the whole app rather than N
/// independently-tracked copies of it. No feature should ever attach its
/// own `Authorization` header, implement its own refresh logic, or retry
/// a request itself; that duplication is exactly what this type exists
/// to prevent.
///
/// An `actor`, not a class with locks: every mutation of `accessToken`
/// or `recoveryTask` is already serialized by actor isolation, so the
/// single-flight recovery guard below needs no additional synchronization
/// primitive to be correct.
actor AuthenticatedAPIClient {
    private let baseURL: URL
    private let session: URLSession
    private let tokenStore: AuthTokenStoring
    private let deviceIdentityStore: DeviceIdentityStoring
    private let platform = "ios"

    private var accessToken: String?
    private var recoveryTask: Task<User, Error>?
    private var sessionChangeContinuation: AsyncStream<User>.Continuation?

    init(
        baseURL: URL = BackendConfiguration.baseURL,
        session: URLSession = .shared,
        tokenStore: AuthTokenStoring = KeychainAuthTokenStore(),
        deviceIdentityStore: DeviceIdentityStoring = KeychainDeviceIdentityStore()
    ) {
        self.baseURL = baseURL
        self.session = session
        self.tokenStore = tokenStore
        self.deviceIdentityStore = deviceIdentityStore
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
    /// token — used by sign-out, and internally by a refresh that itself
    /// fails, so neither survives to be reused.
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

    /// Broadcasts the resolved identity every time `recoverSession()`
    /// resolves — whether that recovery was requested explicitly (launch-
    /// time restore) or triggered silently, mid-request, by a 401 inside
    /// `performOnce`/`streamBytes` that the caller never asked about.
    /// That second case is this stream's entire reason to exist (Phase
    /// 3.7): without it, a refresh token being revoked server-side while
    /// the app sits in the foreground would fall back to an anonymous
    /// session down here with nothing above ever finding out — `AuthState`
    /// would keep reporting the old, no-longer-real signed-in user until
    /// something else happened to call `restoreSession()` again (i.e.
    /// never, short of relaunching the app). One subscriber in practice
    /// (`AuthState`, for the app's lifetime) — a later subscription
    /// simply replaces the previous continuation, which is correct for
    /// that single-long-lived-listener shape and avoids bookkeeping this
    /// app has no actual use for.
    func sessionChanges() -> AsyncStream<User> {
        AsyncStream { continuation in
            sessionChangeContinuation = continuation
        }
    }

    /// Resolves to a valid, usable session on every call — the stored
    /// refresh token's account if it's still good, otherwise this
    /// device's anonymous account. Single-flight: concurrent callers
    /// (whether from an explicit launch-time restore or several requests
    /// independently hitting a 401 at once) share exactly one recovery
    /// attempt, not N. Throws only if *both* tiers fail — typically means
    /// no network at all.
    @discardableResult
    func recoverSession() async throws -> User {
        if let existing = recoveryTask {
            return try await existing.value
        }
        let task = Task { try await performRecovery() }
        recoveryTask = task
        defer { recoveryTask = nil }
        return try await task.value
    }

    // MARK: - REST

    func get(_ path: String) async throws -> Data {
        try await send(path: path, method: "GET", body: nil, retryAttempts: 2, recoverOn401: true)
    }

    /// Not retried on transient failure by default: a POST typically
    /// creates a resource, and retrying risks duplicating it if the first
    /// attempt actually reached the server but the client didn't see the
    /// response. Callers whose POST is genuinely safe to retry (e.g. an
    /// idempotent action) can raise `retryAttempts` explicitly.
    ///
    /// `recoverOn401` defaults to `true` for the same reason `get` always
    /// is: most POSTs (chat creation, signup, logout, merge...) are made
    /// by a caller that's *supposed* to already have a session, so a 401
    /// is worth trying to recover from before giving up. `login` is the
    /// one call that should never do this — a 401 there always means
    /// wrong credentials, never "session not established yet," since
    /// login doesn't depend on any existing session at all — so
    /// `NetworkAuthService.signIn` passes `false` explicitly.
    func post(_ path: String, body: Data?, retryAttempts: Int = 1, recoverOn401: Bool = true) async throws -> Data {
        try await send(path: path, method: "POST", body: body, retryAttempts: retryAttempts, recoverOn401: recoverOn401)
    }

    func patch(_ path: String, body: Data) async throws -> Data {
        try await send(path: path, method: "PATCH", body: body, retryAttempts: 2, recoverOn401: true)
    }

    @discardableResult
    func delete(_ path: String) async throws -> Data {
        try await send(path: path, method: "DELETE", body: nil, retryAttempts: 2, recoverOn401: true)
    }

    /// Opens an authenticated streaming (SSE) connection. Attaches the
    /// current access token and recovers once on a 401 before the stream
    /// is ever opened — the same as `send`, just returning raw bytes
    /// instead of buffered `Data`, since parsing the SSE format is a
    /// concern for the caller (`NetworkChatService`), not this generic
    /// transport layer. Not retried once bytes start flowing, and not
    /// retried on transient failure at all — a partially-consumed stream,
    /// or one that failed to open due to a flaky connection, is never
    /// safe to silently retry from here.
    func streamBytes(path: String, body: Data) async throws -> (URLSession.AsyncBytes, URLResponse) {
        let request = try await makeRequest(path: path, method: "POST", body: body, accept: "text/event-stream")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                _ = try await recoverSession()
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

    private func send(path: String, method: String, body: Data?, retryAttempts: Int, recoverOn401: Bool) async throws -> Data {
        var lastError: Error = AuthenticatedAPIClientError.invalidResponse

        for attempt in 0..<retryAttempts {
            do {
                return try await performOnce(path: path, method: method, body: body, recoverOn401: recoverOn401)
            } catch {
                lastError = error
                // Only transient/transport failures are worth retrying —
                // an auth or HTTP error means the server actively
                // answered, and retrying it would just get the same
                // answer again.
                guard Self.isRetryable(error), attempt < retryAttempts - 1 else { throw error }
                try? await Task.sleep(for: .milliseconds(300 * (attempt + 1)))
            }
        }
        throw lastError
    }

    /// One full attempt at a request, including the 401 → recover →
    /// retry-once handling — that inner retry is about authentication,
    /// not transient failure, so it happens on every attempt regardless
    /// of `retryAttempts`.
    private func performOnce(path: String, method: String, body: Data?, recoverOn401: Bool) async throws -> Data {
        let request = try await makeRequest(path: path, method: method, body: body)

        do {
            let (data, response) = try await session.data(for: request)

            guard let http = response as? HTTPURLResponse else {
                throw AuthenticatedAPIClientError.invalidResponse
            }

            if http.statusCode == 401, recoverOn401 {
                // Deliberately not gated on `accessToken != nil` — a 401
                // with no token attached can legitimately mean "no
                // session has been established yet" (e.g. a chat request
                // racing the launch-time restore, before it's installed
                // anything), and that case is exactly as recoverable as
                // an expired one. `recoverOn401` is what lets `login`
                // opt out instead, since a 401 there always means wrong
                // credentials regardless of whether a token was sent.
                _ = try await recoverSession()
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

    private static func isRetryable(_ error: Error) -> Bool {
        guard let clientError = error as? AuthenticatedAPIClientError else { return false }
        switch clientError {
        case .offline, .underlying, .invalidResponse:
            return true
        case .http(let status, _):
            return status >= 500
        case .notAuthenticated, .sessionExpired:
            return false
        }
    }

    // MARK: - Recovery (single-flight, two-tiered)

    private func performRecovery() async throws -> User {
        let user: User
        if tokenStore.currentRefreshToken() != nil, let refreshed = try? await performRefresh() {
            user = refreshed
        } else {
            user = try await performDeviceAuth()
        }
        sessionChangeContinuation?.yield(user)
        return user
    }

    private func performRefresh() async throws -> User {
        guard let refreshToken = tokenStore.currentRefreshToken() else {
            throw AuthenticatedAPIClientError.notAuthenticated
        }

        var request = URLRequest(url: baseURL.appending(path: "auth/refresh"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder.evenAI.encode(["refreshToken": refreshToken])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthenticatedAPIClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            // The refresh token itself is no longer usable — expired or
            // revoked server-side. Clear it locally too, so nothing keeps
            // retrying a token that will never work again; the anonymous
            // fallback in performRecovery takes over from here.
            clearSession()
            throw AuthenticatedAPIClientError.sessionExpired
        }

        let decoded = try JSONDecoder.evenAI.decode(RefreshResponseDTO.self, from: data)
        accessToken = decoded.accessToken
        tokenStore.save(refreshToken: decoded.refreshToken)
        return decoded.account.toDomain()
    }

    private func performDeviceAuth() async throws -> User {
        let deviceID = deviceIdentityStore.currentDeviceID()
        let payload: [String: String] = [
            "deviceId": deviceID.uuidString,
            "platform": platform,
            "appVersion": Self.appVersion,
        ]

        var request = URLRequest(url: baseURL.appending(path: "auth/device"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder.evenAI.encode(payload)

        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data: data)

        let decoded = try JSONDecoder.evenAI.decode(DeviceAuthResponseDTO.self, from: data)
        accessToken = decoded.accessToken
        tokenStore.save(refreshToken: decoded.refreshToken)
        return decoded.account.toDomain()
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
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
