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
    /// The one authoritative session state — see `SessionState`'s own
    /// doc comment. Updated at every transition inside
    /// `performRecovery()`/`ensureSession()`, alongside the matching
    /// `SESSION_STATE_PUBLISHED` trace.
    private var sessionState: SessionState = .unknown
    /// The most recent recovery FAILURE and when it happened — the
    /// cooldown state that makes `recoverSession()` stop hammering the
    /// backend when it's already told this device "no" moments ago.
    /// Real evidence this matters: `AuthenticatedAPIClient.performOnce`'s
    /// reactive 401→recover path is UNCONDITIONAL — every single
    /// authenticated REST call this app makes (Chat's `fetchChats`,
    /// `fetchChat`, `fetchMessages`, ...) independently triggers its own
    /// `recoverSession()` attempt the moment it sees a 401, with no
    /// memory of "we already tried this and the backend said no" a
    /// second ago. Without this cooldown, a single genuinely-exhausted
    /// `/auth/device` rate-limit window (20 requests/15 minutes,
    /// enforced server-side — see `even-ai-assistant-asr`'s
    /// `authRateLimit`) gets hit again by literally every dependent
    /// screen's own load attempt, each burning another attempt against
    /// the same limit and extending how long the device stays locked
    /// out — which is exactly the physical-device symptom under
    /// investigation ("Your session couldn't be verified" for Live
    /// Translation, Chat simply never loading). This is NOT a retry
    /// mechanism — it suppresses REDUNDANT ones. `recoveryFailureCooldown`
    /// is intentionally short: long enough to stop the immediate,
    /// automatic pile-on from every independent consumer's own reactive
    /// 401 handling, short enough that a user who waits even a few
    /// seconds and retries deliberately (or `retrySessionRecovery()`,
    /// which bypasses this explicitly) is never meaningfully blocked.
    private var lastRecoveryFailure: (error: Error, at: ContinuousClock.Instant)?
    private let recoveryFailureCooldown: Duration
    private let clock: ContinuousClock
    /// Wall-clock (not `ContinuousClock`) deadline before which NO
    /// automatic session-recovery attempt may touch `/auth/device` at
    /// all — set only from a genuine, backend-reported `429`/
    /// `RATE_LIMITED` response (see `parseRetryAfterSeconds(from:)`),
    /// never invented client-side. Deliberately `Date`, not
    /// `ContinuousClock.Instant`: this needs to survive an app relaunch
    /// (Section 6 of the follow-up rate-limit hardening pass — a force-
    /// quit must not immediately restart the request storm), and only a
    /// wall-clock timestamp remains meaningful across a process restart.
    /// Distinct from — and checked BEFORE — `lastRecoveryFailure`'s much
    /// shorter generic cooldown: a real 15-minute backend rate-limit
    /// window must never be treated the same as an ordinary transient
    /// hiccup that's fine to retry again in a few seconds.
    private var rateLimitedUntil: Date?
    private let defaults: UserDefaults
    private static let rateLimitedUntilDefaultsKey = "com.evenai.session.rateLimitedUntilTimestamp"
    /// `UserDefaults` isn't `Sendable`, so it can't cross directly into
    /// an actor's `init` as a plain parameter under Swift 6 strict
    /// concurrency — a `@Sendable` closure that PRODUCES it, invoked
    /// here inside the actor's own initializer, is the standard way
    /// around that: the closure itself is `Sendable` (captures nothing
    /// non-`Sendable` when the default `{ .standard }` is used, or when
    /// a test passes a fresh, locally-created instance), and the
    /// `UserDefaults` value it returns is constructed/obtained ONLY
    /// after execution has already entered this initializer — it never
    /// "crosses" the actor boundary as a value in flight.
    typealias DefaultsProvider = @Sendable () -> UserDefaults
    /// Used only when the backend's `429` response carries neither a
    /// parseable `Retry-After` header nor a `RateLimit-Reset` header —
    /// matches the known, currently-configured window
    /// (`even-ai-assistant-asr`'s `authRateLimit`: 15 minutes) as the
    /// safest assumption when the server didn't say otherwise.
    private static let defaultRateLimitWindow: Duration = .seconds(15 * 60)

    init(
        baseURL: URL = BackendConfiguration.baseURL,
        session: URLSession = .shared,
        tokenStore: AuthTokenStoring = KeychainAuthTokenStore(),
        deviceIdentityStore: DeviceIdentityStoring = KeychainDeviceIdentityStore(),
        defaults defaultsProvider: @escaping DefaultsProvider = { .standard },
        recoveryFailureCooldown: Duration = .seconds(5)
    ) {
        self.baseURL = baseURL
        self.session = session
        self.tokenStore = tokenStore
        self.deviceIdentityStore = deviceIdentityStore
        let defaults = defaultsProvider()
        self.defaults = defaults
        self.recoveryFailureCooldown = recoveryFailureCooldown
        self.clock = ContinuousClock()
        // Load any still-active rate-limit deadline persisted from a
        // PRIOR process run — an already-expired one is simply never
        // set here (nothing to suppress), and is opportunistically
        // cleared from storage the first time anything reads it.
        if let stored = defaults.object(forKey: Self.rateLimitedUntilDefaultsKey) as? TimeInterval {
            let deadline = Date(timeIntervalSince1970: stored)
            if deadline > Date() {
                rateLimitedUntil = deadline
            } else {
                defaults.removeObject(forKey: Self.rateLimitedUntilDefaultsKey)
            }
        }
    }

    /// A snapshot of the one authoritative session state, right now —
    /// what Chat/Live Translation/Settings read to answer "is there a
    /// usable credential" without triggering any network activity of
    /// their own.
    func currentSessionState() -> SessionState {
        sessionState
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
        publish(.ready(.authenticated))
    }

    /// Clears both the in-memory access token and the persisted refresh
    /// token — used by sign-out, and internally by `performRefresh(refreshToken:)`
    /// ONLY when the backend has explicitly said the refresh token is
    /// invalid (see that method's own doc comment for why every OTHER
    /// failure kind deliberately does NOT reach here).
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
    /// attempt, not N — this is true by construction (actor isolation:
    /// `recoveryTask` can only be read/written serially, so no two
    /// callers can ever both observe it `nil` and each start their own
    /// task). Throws only if *both* tiers fail.
    ///
    /// ALSO protected against REPEATED failed attempts arriving close
    /// together, at two different granularities: a real, backend-timed
    /// rate-limit deadline (`rateLimitedUntil`, checked FIRST — never
    /// bypassable by anything except the real reset time itself) and a
    /// much shorter generic cooldown for every other transient failure
    /// kind (`lastRecoveryFailure`, bypassable by
    /// `retrySessionRecovery()`, an explicit user-initiated action).
    @discardableResult
    func recoverSession() async throws -> User {
        if let existing = recoveryTask {
            DiagnosticTrace.log("SESSION_SINGLE_FLIGHT_JOINED", "")
            return try await existing.value
        }
        if let suppression = rateLimitSuppression() {
            throw suppression
        }
        if let lastFailure = lastRecoveryFailure, clock.now - lastFailure.at < recoveryFailureCooldown {
            DiagnosticTrace.log("SESSION_RECOVERY_COOLDOWN_ACTIVE", "suppressing a redundant attempt — reusing the recent failure")
            throw lastFailure.error
        }
        return try await startRecovery()
    }

    /// Explicit, user-initiated retry (Section J's "Retry Session"
    /// affordance) — bypasses ONLY the short generic cooldown
    /// (`lastRecoveryFailure`), never the real backend rate-limit
    /// deadline (`rateLimitedUntil`): per the follow-up hardening pass's
    /// own explicit requirement, "Retry Session" must stay
    /// disabled/suppressed until the server's actual reset time, even
    /// for a deliberate human tap — a production device retrying while
    /// the backend is still rate-limiting it is exactly the failure mode
    /// this exists to prevent. Once that deadline passes, this (or the
    /// very next ordinary `recoverSession()` call) is what performs the
    /// one fresh attempt the reset permits.
    @discardableResult
    func retrySessionRecovery() async throws -> User {
        if let suppression = rateLimitSuppression() {
            throw suppression
        }
        lastRecoveryFailure = nil
        if let existing = recoveryTask {
            DiagnosticTrace.log("SESSION_SINGLE_FLIGHT_JOINED", "")
            return try await existing.value
        }
        return try await startRecovery()
    }

    /// `nil` if no rate-limit deadline is active (or it has already
    /// passed — in which case it's cleared here, so this is also the one
    /// place an EXPIRED deadline gets cleaned up without needing a
    /// separate timer). Otherwise logs `SESSION_RECOVERY_SUPPRESSED` and
    /// returns the exact error to throw — never touches the network.
    private func rateLimitSuppression() -> AuthenticatedAPIClientError? {
        guard let deadline = rateLimitedUntil else { return nil }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else {
            clearRateLimit()
            return nil
        }
        let remainingSeconds = Int(remaining.rounded(.up))
        DiagnosticTrace.log("SESSION_RECOVERY_SUPPRESSED", "reason=rateLimited remainingSeconds=\(remainingSeconds)")
        return .rateLimited(retryAfterSeconds: remainingSeconds)
    }

    private func setRateLimit(retryAfterSeconds: Int) {
        let deadline = Date().addingTimeInterval(TimeInterval(retryAfterSeconds))
        rateLimitedUntil = deadline
        defaults.set(deadline.timeIntervalSince1970, forKey: Self.rateLimitedUntilDefaultsKey)
        DiagnosticTrace.log("SESSION_RATE_LIMITED", "retryAfterSeconds=\(retryAfterSeconds)")
        DiagnosticTrace.log("SESSION_RETRY_NOT_BEFORE", "timestamp=\(deadline.timeIntervalSince1970)")
    }

    /// Called the moment recovery succeeds — Section 5's own
    /// requirement: "successful recovery clears rate-limit state."
    private func clearRateLimit() {
        guard rateLimitedUntil != nil else { return }
        rateLimitedUntil = nil
        defaults.removeObject(forKey: Self.rateLimitedUntilDefaultsKey)
    }

    private func startRecovery() async throws -> User {
        let task = Task { try await performRecovery() }
        recoveryTask = task
        defer { recoveryTask = nil }
        return try await task.value
    }

    /// A cheaper, more conservative sibling of `recoverSession()` for
    /// callers that only need to guarantee *some* credential is attached
    /// before proceeding — never call this from a REST path, which
    /// already gets the right behavior for free from `performOnce`'s
    /// reactive 401→recover→retry (that path's `recoverOn401` is what
    /// correctly re-recovers an EXPIRED token; this method deliberately
    /// does not attempt that).
    ///
    /// A no-op — no network call at all — whenever `accessToken` is
    /// already set. This distinction matters: `/auth/refresh` ROTATES
    /// the refresh token on every single call (the old one is revoked
    /// server-side the instant a new one is issued — see
    /// `even-ai-assistant-asr`'s `/auth/refresh` handler), so calling
    /// `recoverSession()` unconditionally on every WebSocket connection
    /// AND every one of its bounded reconnect attempts — as this class's
    /// one and only caller of this method briefly did — churns the ONE
    /// session Live Translation and Chat share far more than necessary,
    /// and risks cascading into `/auth/device`'s rate limit if a refresh
    /// attempt ever comes back invalid for any reason. This only ever
    /// recovers when there is genuinely NO credential attached yet — the
    /// exact "missing Authorization header" case a WebSocket connect
    /// needs to guard against, without manufacturing new load on every
    /// reconnect that already has a perfectly good token.
    func ensureSession() async throws {
        guard accessToken == nil else {
            DiagnosticTrace.log("SESSION_ACCESS_TOKEN_VALID", "")
            return
        }
        _ = try await recoverSession()
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
    ///
    /// The retry's response is validated just like `send`/`performOnce`
    /// does — previously it wasn't, so a retry that *also* came back 401
    /// (recovery resolving to a session the backend still rejects) was
    /// never detected as an error at all: the 401's JSON error body has no
    /// `event:`/`data:` framing, so the SSE parser silently read it as an
    /// empty stream instead of surfacing the failure.
    func streamBytes(path: String, body: Data) async throws -> (URLSession.AsyncBytes, URLResponse) {
        let request = try await makeRequest(path: path, method: "POST", body: body, accept: "text/event-stream")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                _ = try await recoverSession()
                let retryRequest = try await makeRequest(path: path, method: "POST", body: body, accept: "text/event-stream")
                let (retryBytes, retryResponse) = try await session.bytes(for: retryRequest)
                try Self.validateStatus(retryResponse)
                return (retryBytes, retryResponse)
            }
            try Self.validateStatus(response)
            return (bytes, response)
        } catch let urlError as URLError {
            throw Self.classify(urlError)
        }
    }

    /// Builds an authenticated WebSocket upgrade request for `path` — the
    /// same Bearer-token attachment `get`/`post`/etc. use (see
    /// `makeRequest`), returned as a plain `URLRequest` rather than sent,
    /// since constructing a `URLSessionWebSocketTask` from it (not
    /// `URLSession.data(for:)`) is the caller's own job — see
    /// `URLSessionRealtimeTranscriptionSocket`. Deliberately no 401/retry
    /// handling here: a WS upgrade failure just surfaces as a closed/
    /// errored socket to the caller, whose own reconnect logic is what
    /// calls `recoverSession()` before rebuilding this request with a
    /// fresh token — the same division of responsibility `streamBytes`
    /// has for SSE, just one level further out since a dropped WS
    /// reconnects as a whole new connection, not a retried request.
    func makeWebSocketRequest(path: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        return request
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
                AppLogger.networking.notice("Retrying \(method, privacy: .public) \(path, privacy: .public) after a transient failure (attempt \(attempt + 1, privacy: .public)/\(retryAttempts, privacy: .public))")
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
                DiagnosticTrace.log("SESSION_ACCESS_TOKEN_EXPIRED", "path=\(path)")
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
        case .rateLimited:
            // Never retried automatically, by this method or by ANY
            // caller — retrying a rate-limited failure, even once more,
            // is exactly the "hammer the endpoint" behavior this whole
            // mechanism exists to stop. The user (or `retrySessionRecovery()`,
            // itself gated on the real retry-not-before time) is the
            // only path that ever tries again.
            return false
        }
    }

    // MARK: - Recovery (single-flight, two-tiered, cooldown-protected)
    //
    // The deterministic launch/recovery flow (Section E of the session-
    // lifecycle audit this rewrite comes from):
    //   1. Load persisted session — `tokenStore.currentRefreshToken()`.
    //   2. A valid IN-MEMORY access token short-circuits entirely — see
    //      `ensureSession()`; this whole section only ever runs when one
    //      is genuinely absent.
    //   3. Else, if a refresh token exists → attempt refresh.
    //   4. Else (or if refresh was DEFINITIVELY invalid) → anonymous
    //      device-auth recovery.
    //   5. The resulting credential is persisted atomically inside
    //      `performRefresh`/`performDeviceAuth` themselves (in-memory
    //      `accessToken` write + `tokenStore.save` happen together, with
    //      no `await` between them — nothing can observe a half-written
    //      state).
    //   6. `sessionState` is published at every transition (below).
    //   7. Every consumer (Chat, Live Translation) goes through
    //      `recoverSession()`/`ensureSession()`, never its own bespoke
    //      recovery — this method is the ONE place that runs.

    private func performRecovery() async throws -> User {
        DiagnosticTrace.log(
            "SESSION_STATE_LOADED",
            "hasRefreshToken=\(tokenStore.currentRefreshToken() != nil)"
        )
        publish(.recovering)

        if let refreshToken = tokenStore.currentRefreshToken() {
            DiagnosticTrace.log("SESSION_REFRESH_STARTED", "")
            do {
                let user = try await performRefresh(refreshToken: refreshToken)
                DiagnosticTrace.log("SESSION_REFRESH_SUCCEEDED", "")
                succeed(user, as: .authenticated)
                return user
            } catch RefreshFailure.permanentlyInvalid(let underlying) {
                DiagnosticTrace.log("SESSION_REFRESH_FAILED", "reason=invalidCredential")
                // Self-heal: the backend explicitly told us this
                // refresh token will never work again — this is the
                // ONLY condition that clears it (see `performRefresh`'s
                // own doc comment for why every other failure kind must
                // NOT reach here). Falls through to anonymous recovery
                // below, matching the deterministic flow's step 4.
                clearSession()
                _ = underlying
            } catch {
                // A TRANSIENT refresh failure (backend 5xx, offline,
                // malformed response) — the refresh token itself was
                // never judged invalid, so it must NOT be cleared, and
                // this must NOT fall through to anonymous recovery
                // (which would silently demote a signed-in user to
                // anonymous over a mere network hiccup, and could ALSO
                // hit `/auth/device`'s rate limit for no reason). Fail
                // outright, preserving the credential for the next
                // attempt — exactly the fix for the real bug found
                // auditing this: the old code cleared the refresh token
                // on ANY non-2xx response from `/auth/refresh`.
                let reason = Self.classifyRecoveryFailure(error)
                DiagnosticTrace.log("SESSION_REFRESH_FAILED", "reason=\(reason.underlyingDescription)")
                fail(error, reason: reason)
                throw error
            }
        }

        // The one previously-silent transition this whole mechanism
        // exists to catch (see the class doc comment and
        // `sessionChanges()`): a signed-in session just became an
        // anonymous one, possibly mid-request, with no explicit
        // sign-out ever called. Never log the account id or any
        // token — just that it happened.
        AppLogger.auth.notice("Session recovery fell back to an anonymous device session (missing, expired, or revoked refresh token)")
        DiagnosticTrace.log("SESSION_ANONYMOUS_RECOVERY_STARTED", "")
        do {
            let user = try await performDeviceAuth()
            DiagnosticTrace.log("SESSION_ANONYMOUS_RECOVERY_SUCCEEDED", "")
            succeed(user, as: .anonymous)
            return user
        } catch {
            let reason = Self.classifyRecoveryFailure(error)
            DiagnosticTrace.log("SESSION_ANONYMOUS_RECOVERY_FAILED", "reason=\(reason.underlyingDescription)")
            fail(error, reason: reason)
            throw error
        }
    }

    private func succeed(_ user: User, as type: SessionCredentialType) {
        publish(.ready(type))
        DiagnosticTrace.log("SESSION_CREDENTIAL_AVAILABLE", "type=\(type.rawValue)")
        lastRecoveryFailure = nil
        clearRateLimit()
        sessionChangeContinuation?.yield(user)
    }

    private func fail(_ error: Error, reason: SessionRecoveryFailureReason) {
        publish(.failed(reason))
        DiagnosticTrace.log("SESSION_CREDENTIAL_MISSING", "")
        lastRecoveryFailure = (error, clock.now)
    }

    private func publish(_ state: SessionState) {
        sessionState = state
        DiagnosticTrace.log("SESSION_STATE_PUBLISHED", "state=\(state)")
    }

    /// The real classifier behind `LiveTranslationStartError
    /// .classifyTranscriberStartFailure(_:)`'s own `AuthenticatedAPIClientError`
    /// handling, reused here so `SessionRecoveryFailureReason` and that
    /// type's classification never drift apart. A 429 (rate-limited) is
    /// deliberately NEVER `.invalidCredential`-adjacent — a backend
    /// telling this device to slow down says nothing about whether the
    /// credential itself is valid.
    private static func classifyRecoveryFailure(_ error: Error) -> SessionRecoveryFailureReason {
        guard let apiError = error as? AuthenticatedAPIClientError else { return .unknown }
        switch apiError {
        case .offline:
            return .offline
        case .rateLimited(let retryAfterSeconds):
            return .rateLimited(retryAfterSeconds: retryAfterSeconds)
        case .http(let status, _):
            return status >= 500 ? .backendUnavailable : .invalidCredential
        case .notAuthenticated, .sessionExpired:
            return .invalidCredential
        case .invalidResponse, .underlying:
            return .backendUnavailable
        }
    }

    private enum RefreshFailure: Error {
        case permanentlyInvalid(underlying: Error)
    }

    /// Distinguishes a DEFINITIVE "this refresh token will never work
    /// again" response (a 401, the backend's own `INVALID_REFRESH_TOKEN`
    /// contract — see `even-ai-assistant-asr`'s `/auth/refresh` handler)
    /// from every other failure kind (5xx, offline, malformed response),
    /// which must be treated as transient — see `performRecovery()`'s
    /// own doc comment for why conflating the two was a real bug.
    private func performRefresh(refreshToken: String) async throws -> User {
        var request = URLRequest(url: baseURL.appending(path: "auth/refresh"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder.evenAI.encode(["refreshToken": refreshToken])

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw Self.classify(urlError)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AuthenticatedAPIClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 {
                throw RefreshFailure.permanentlyInvalid(underlying: AuthenticatedAPIClientError.sessionExpired)
            }
            let code = try? JSONDecoder().decode(APIErrorPayloadDTO.self, from: data).error.code
            throw AuthenticatedAPIClientError.http(status: http.statusCode, code: code)
        }

        let decoded = try JSONDecoder.evenAI.decode(RefreshResponseDTO.self, from: data)
        // Atomic from any external observer's perspective: both writes
        // happen with no `await` between them, and this whole method
        // runs on the actor, so nothing can read a half-updated state.
        accessToken = decoded.accessToken
        tokenStore.save(refreshToken: decoded.refreshToken)
        return decoded.account.toDomain()
    }

    /// `/auth/device` is the ONE endpoint this app calls that the
    /// backend actually rate-limits (`even-ai-assistant-asr`'s
    /// `authRateLimit`: 20 requests/15 minutes per IP, applied to
    /// `/auth/device`/`/auth/signup`/`/auth/login` — confirmed NOT
    /// applied to `/auth/refresh`, which has no such limit). A `429`
    /// here is handled specially: parses the backend's own
    /// `Retry-After`/`RateLimit-Reset` signal, records
    /// `rateLimitedUntil` (persisted — see that property's own doc
    /// comment), and throws the dedicated `.rateLimited` case rather
    /// than a generic `.http(429, ...)`.
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

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw Self.classify(urlError)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AuthenticatedAPIClientError.invalidResponse
        }
        if http.statusCode == 429 {
            let retryAfterSeconds = Self.parseRetryAfterSeconds(from: http) ?? Int(Self.defaultRateLimitWindow.components.seconds)
            setRateLimit(retryAfterSeconds: retryAfterSeconds)
            throw AuthenticatedAPIClientError.rateLimited(retryAfterSeconds: retryAfterSeconds)
        }
        guard (200..<300).contains(http.statusCode) else {
            let code = try? JSONDecoder().decode(APIErrorPayloadDTO.self, from: data).error.code
            throw AuthenticatedAPIClientError.http(status: http.statusCode, code: code)
        }

        let decoded = try JSONDecoder.evenAI.decode(DeviceAuthResponseDTO.self, from: data)
        accessToken = decoded.accessToken
        tokenStore.save(refreshToken: decoded.refreshToken)
        return decoded.account.toDomain()
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    /// Reads the backend's own rate-limit signal off a `429` response —
    /// never a client-invented guess (see `performDeviceAuth()`'s doc
    /// comment). Prefers the standard `Retry-After` header (RFC 6585 —
    /// `express-rate-limit`'s `standardHeaders: true` sets this on a
    /// blocked request), which may be either delta-seconds ("900") or an
    /// HTTP-date; falls back to the IETF draft `RateLimit-Reset` header
    /// (also emitted by `standardHeaders: true`, delta-seconds only) if
    /// `Retry-After` is absent or unparseable. Returns `nil` — never a
    /// fabricated number — if neither header yields a usable value, so
    /// the caller's own `defaultRateLimitWindow` fallback is what
    /// applies, and that fallback is clearly attributable, not
    /// disguised as a real server signal.
    private static func parseRetryAfterSeconds(from response: HTTPURLResponse) -> Int? {
        if let retryAfter = response.value(forHTTPHeaderField: "Retry-After") {
            if let seconds = Int(retryAfter.trimmingCharacters(in: .whitespaces)), seconds >= 0 {
                return seconds
            }
            if let httpDate = Self.httpDateFormatter.date(from: retryAfter) {
                let seconds = Int(httpDate.timeIntervalSinceNow.rounded(.up))
                return max(seconds, 0)
            }
        }
        if let resetHeader = response.value(forHTTPHeaderField: "RateLimit-Reset"),
           let seconds = Int(resetHeader.trimmingCharacters(in: .whitespaces)), seconds >= 0 {
            return seconds
        }
        return nil
    }

    /// RFC 7231 IMF-fixdate — the format `Retry-After` uses when it
    /// carries a date instead of delta-seconds.
    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

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
    /// The backend explicitly rate-limited a session-recovery request
    /// (`/auth/device`, `HTTP 429`/`RATE_LIMITED` — see
    /// `even-ai-assistant-asr`'s `authRateLimit`: 20 requests per 15-
    /// minute window, IP-keyed). `retryAfterSeconds` is the backend's own
    /// signal (its `Retry-After` header, or `RateLimit-Reset` as a
    /// fallback — see `AuthenticatedAPIClient
    /// .parseRetryAfterSeconds(from:)`), never a client-invented guess.
    /// Deliberately a DISTINCT case from `.http(status: 429, ...)` — this
    /// is what lets every downstream classifier (`LiveTranslationStartError`,
    /// Chat's own load-failure handling) recognize "the backend told us
    /// to slow down" as a single, unambiguous signal, both on the LIVE
    /// 429 response and on every later call this class suppresses on its
    /// own before ever reaching the network again (see
    /// `AuthenticatedAPIClient.recoverSession()`'s rate-limit check).
    case rateLimited(retryAfterSeconds: Int)
    case http(status: Int, code: String?)
    case invalidResponse
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: "Not signed in."
        case .sessionExpired: "Your session has expired."
        case .offline: "No internet connection."
        case .rateLimited(let seconds): "Too many session attempts. Try again in \(seconds)s."
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
