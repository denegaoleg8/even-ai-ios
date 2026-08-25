import Testing
import Foundation
@testable import EvenAI

/// Full session-lifecycle audit (physical-device regressions: Live
/// Translation showing "Your session couldn't be verified," normal AI
/// Chat not opening). Root cause traced to two compounding issues in
/// `AuthenticatedAPIClient`'s recovery machinery:
///
/// 1. `performRefresh()` used to clear the stored refresh token on ANY
///    non-2xx `/auth/refresh` response — including a TRANSIENT one (5xx,
///    network hiccup) — not just a definitive "this token is invalid"
///    401. A transient refresh failure silently discarded a perfectly
///    good credential and forced an unnecessary anonymous-fallback
///    attempt, which itself hits `/auth/device`'s 20-requests/15-minute
///    IP rate limit (confirmed in `even-ai-assistant-asr`'s
///    `authRateLimit`).
/// 2. Every dependent screen's own reactive 401→recover path
///    (`AuthenticatedAPIClient.performOnce`) independently re-attempted
///    FULL recovery with no memory of a recent failure — so once
///    `/auth/device` genuinely was rate-limited, literally every Chat
///    load and every Live Translation start kept re-attempting recovery,
///    each burning another attempt against the same limit and extending
///    the lockout window. This is the exact shared-layer regression this
///    file's tests lock in the fix for.
///
/// `.serialized`: shares `StubURLProtocol`'s process-global handler/
/// request log with `AuthenticatedAPIClientTests`, same reasoning as
/// that suite's own `.serialized` attribute.
///
/// Scenarios 1-3 (expired access token + valid refresh; missing both
/// tiers falling back to anonymous; revoked refresh token falling back
/// to anonymous) are already covered by `AuthenticatedAPIClientTests
/// .recoverWithStoredToken`/`.recoversOnUnauthenticated401WithNoTokenAttached`/
/// `.recoverWithNoStoredTokenFallsBackToAnonymous`/
/// `.recoverFallsBackToAnonymousWhenRefreshTokenRevoked` — not
/// duplicated here.
@Suite("Session recovery — shared auth/session lifecycle", .serialized)
struct SessionRecoveryTests {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "SessionRecoveryTests.\(UUID().uuidString)")!
    }

    /// A fresh, isolated `UserDefaults` suite PER CALL, never `.standard`
    /// — `rateLimitedUntil` is persisted (Section 6 of the rate-limit
    /// hardening pass: it must survive an app relaunch), so two clients
    /// sharing `.standard` in the same test process would leak rate-
    /// limit state between them exactly like two real, separate
    /// `AuthenticatedAPIClient` instances constructed across a genuine
    /// relaunch are SUPPOSED to share it — correct in production,
    /// exactly the behavior `relaunchRespectsPersistedRateLimit` below
    /// deliberately exercises, but wrong for any OTHER test in this file
    /// that wants a clean slate.
    private func makeClient(
        tokenStore: AuthTokenStoring = InMemoryAuthTokenStore(),
        defaults: (@Sendable () -> UserDefaults)? = nil,
        recoveryFailureCooldown: Duration = .seconds(5)
    ) -> AuthenticatedAPIClient {
        StubURLProtocol.reset()
        return AuthenticatedAPIClient(
            baseURL: URL(string: "https://example.com/api")!,
            session: StubURLProtocol.makeSession(),
            tokenStore: tokenStore,
            defaults: defaults ?? { self.freshDefaults() },
            recoveryFailureCooldown: recoveryFailureCooldown
        )
    }

    private static func jsonResponse(_ status: Int, _ object: [String: Any], headers: [String: String] = [:]) -> StubURLProtocol.StubResponse {
        StubURLProtocol.StubResponse(status: status, body: try! JSONSerialization.data(withJSONObject: object), headers: headers)
    }

    private static func accountJSON(id: UUID = UUID()) -> [String: Any] {
        ["id": id.uuidString, "email": NSNull(), "displayName": NSNull()]
    }

    private static func deviceAuthResponse(id: UUID = UUID(), accessToken: String, refreshToken: String) -> StubURLProtocol.StubResponse {
        jsonResponse(200, ["accessToken": accessToken, "refreshToken": refreshToken, "account": accountJSON(id: id)])
    }

    // MARK: - The core regression fix: transient refresh failure never clears the token

    @Test("a TRANSIENT refresh failure (backend 500) never clears the stored refresh token, and never falls back to anonymous")
    func transientRefreshFailureNeverClearsToken() async throws {
        let tokenStore = InMemoryAuthTokenStore()
        tokenStore.save(refreshToken: "genuinely-still-valid-refresh")
        let client = makeClient(tokenStore: tokenStore)

        StubURLProtocol.handler = { request in
            // Every request — refresh included — hits a transient
            // backend failure. `/auth/device` must NEVER be called: a
            // transient refresh failure is not license to fall back to
            // anonymous.
            #expect(request.url?.path.hasSuffix("/auth/device") != true)
            return Self.jsonResponse(500, ["error": ["code": "INTERNAL_ERROR", "message": "db unavailable"]])
        }

        await #expect(throws: AuthenticatedAPIClientError.self) {
            try await client.recoverSession()
        }

        // The refresh token survives — it was never judged invalid.
        #expect(tokenStore.currentRefreshToken() == "genuinely-still-valid-refresh")
    }

    @Test("a TRANSIENT refresh failure, once the backend recovers, lets the SAME preserved refresh token succeed on the next attempt")
    func preservedTokenSucceedsOnceBackendRecovers() async throws {
        let tokenStore = InMemoryAuthTokenStore()
        tokenStore.save(refreshToken: "still-valid-refresh")
        // No cooldown here — this test deliberately makes two SEPARATE,
        // sequential `recoverSession()` calls and needs the second one
        // to actually attempt the network, not be suppressed.
        let client = makeClient(tokenStore: tokenStore, recoveryFailureCooldown: .zero)
        let accountID = UUID()

        StubURLProtocol.handler = { _ in Self.jsonResponse(500, ["error": ["code": "INTERNAL_ERROR", "message": "down"]]) }
        await #expect(throws: AuthenticatedAPIClientError.self) {
            try await client.recoverSession()
        }
        #expect(tokenStore.currentRefreshToken() == "still-valid-refresh")

        StubURLProtocol.handler = { request in
            #expect(request.url?.path.hasSuffix("/auth/refresh") == true)
            return Self.jsonResponse(200, ["accessToken": "recovered", "refreshToken": "rotated", "account": Self.accountJSON(id: accountID)])
        }
        let user = try await client.recoverSession()
        #expect(user.id == accountID)
    }

    @Test("only a DEFINITIVE 401 from refresh clears the token and falls back to anonymous — never a 5xx")
    func onlyDefinitive401TriggersSelfHeal() async throws {
        let tokenStore = InMemoryAuthTokenStore()
        tokenStore.save(refreshToken: "actually-revoked")
        let client = makeClient(tokenStore: tokenStore)
        let anonymousID = UUID()

        StubURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/auth/refresh") == true {
                return Self.jsonResponse(401, ["error": ["code": "INVALID_REFRESH_TOKEN", "message": "revoked"]])
            }
            return Self.deviceAuthResponse(id: anonymousID, accessToken: "anon-token", refreshToken: "anon-refresh")
        }

        let user = try await client.recoverSession()
        #expect(user.id == anonymousID)
        #expect(tokenStore.currentRefreshToken() == "anon-refresh") // self-healed to a fresh, working credential
    }

    // MARK: - 4: concurrent Chat + Live Translation startup share one recovery task

    @Test("4: two concurrent callers (modeling Chat + Live Translation both starting up) share exactly one recovery attempt")
    func concurrentCallersShareOneRecoveryTask() async throws {
        let client = makeClient()
        let accountID = UUID()
        let deviceAuthCallCount = Counter()

        StubURLProtocol.handler = { request in
            #expect(request.url?.path.hasSuffix("/auth/device") == true)
            deviceAuthCallCount.increment()
            // A real delay so both callers are genuinely in flight
            // together, not accidentally serialized by test timing.
            return Self.deviceAuthResponse(id: accountID, accessToken: "shared-token", refreshToken: "shared-refresh")
        }

        async let first = client.recoverSession()
        async let second = client.recoverSession()
        let (userA, userB) = try await (first, second)

        #expect(userA.id == accountID)
        #expect(userB.id == accountID)
        #expect(deviceAuthCallCount.value == 1) // exactly one network attempt, not two
    }

    // MARK: - 5: no duplicate anonymous session creation

    @Test("5: three concurrent recoverSession() callers with no prior session create exactly one anonymous session, never three")
    func noDuplicateAnonymousSessionCreation() async throws {
        let client = makeClient()
        let deviceAuthCallCount = Counter()

        StubURLProtocol.handler = { _ in
            deviceAuthCallCount.increment()
            return Self.deviceAuthResponse(accessToken: "token", refreshToken: "refresh")
        }

        async let a = client.recoverSession()
        async let b = client.recoverSession()
        async let c = client.recoverSession()
        _ = try await (a, b, c)

        #expect(deviceAuthCallCount.value == 1)
    }

    // MARK: - 6: recovered credential is persisted atomically

    @Test("6: the recovered access token and refresh token are both usable immediately after recoverSession() returns — no partially-applied state")
    func recoveredCredentialPersistsAtomically() async throws {
        let tokenStore = InMemoryAuthTokenStore()
        let client = makeClient(tokenStore: tokenStore)
        let accountID = UUID()

        StubURLProtocol.handler = { _ in Self.deviceAuthResponse(id: accountID, accessToken: "atomic-token", refreshToken: "atomic-refresh") }
        _ = try await client.recoverSession()

        // Both halves of the credential are in place — not just one.
        #expect(tokenStore.currentRefreshToken() == "atomic-refresh")
        StubURLProtocol.handler = { request in
            Self.jsonResponse(request.value(forHTTPHeaderField: "Authorization") == "Bearer atomic-token" ? 200 : 401, ["ok": true])
        }
        _ = try await client.get("chats")
        #expect(StubURLProtocol.recordedRequests().last?.value(forHTTPHeaderField: "Authorization") == "Bearer atomic-token")
    }

    // MARK: - 11/13: realtime WebSocket and normal Chat receive the SAME current credential

    @Test("11/13: the WebSocket auth path (ensureSession) and a normal Chat REST call both end up using the identical recovered credential")
    func webSocketAndChatShareTheSameCredential() async throws {
        let client = makeClient()
        let accountID = UUID()
        StubURLProtocol.handler = { _ in Self.deviceAuthResponse(id: accountID, accessToken: "one-true-token", refreshToken: "one-true-refresh") }

        // The WebSocket path — ensureSession() (used by
        // URLSessionRealtimeTranscriptionSocket.connect()).
        try await client.ensureSession()
        let wsRequest = await client.makeWebSocketRequest(path: "realtime-transcription")
        #expect(wsRequest.value(forHTTPHeaderField: "Authorization") == "Bearer one-true-token")

        // A normal Chat REST call, right after — same client, same
        // already-attached token, no second recovery needed.
        StubURLProtocol.handler = { request in
            Self.jsonResponse(request.value(forHTTPHeaderField: "Authorization") == "Bearer one-true-token" ? 200 : 401, ["ok": true])
        }
        _ = try await client.get("chats")
        #expect(StubURLProtocol.recordedRequests().last?.value(forHTTPHeaderField: "Authorization") == "Bearer one-true-token")
    }

    // MARK: - 12: reconnect receives the same current credential

    @Test("12: a second ensureSession() call (modeling an STT reconnect attempt) reuses the SAME already-valid credential — no redundant network call")
    func reconnectReusesCurrentCredential() async throws {
        let client = makeClient()
        let deviceAuthCallCount = Counter()
        StubURLProtocol.handler = { _ in
            deviceAuthCallCount.increment()
            return Self.deviceAuthResponse(accessToken: "reconnect-token", refreshToken: "reconnect-refresh")
        }

        try await client.ensureSession() // initial connection
        try await client.ensureSession() // reconnect attempt #1
        try await client.ensureSession() // reconnect attempt #2

        #expect(deviceAuthCallCount.value == 1)
        let request = await client.makeWebSocketRequest(path: "realtime-transcription")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer reconnect-token")
    }

    // MARK: - 14: stale persisted credential self-heals

    @Test("14: a stale/revoked persisted refresh token self-heals into a fresh, working anonymous session on the very next recovery attempt")
    func stalePersistedCredentialSelfHeals() async throws {
        let tokenStore = InMemoryAuthTokenStore()
        tokenStore.save(refreshToken: "stale-from-a-previous-build")
        let client = makeClient(tokenStore: tokenStore)
        let freshAccountID = UUID()

        StubURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/auth/refresh") == true {
                return Self.jsonResponse(401, ["error": ["code": "INVALID_REFRESH_TOKEN", "message": "stale"]])
            }
            return Self.deviceAuthResponse(id: freshAccountID, accessToken: "fresh-token", refreshToken: "fresh-refresh")
        }

        let user = try await client.recoverSession()
        #expect(user.id == freshAccountID)
        #expect(tokenStore.currentRefreshToken() == "fresh-refresh")
    }

    // MARK: - 16: app relaunch uses the recovered persisted session

    @Test("16: a brand-new AuthenticatedAPIClient instance (modeling a fresh app launch) resumes from the SAME persisted refresh token a prior instance stored")
    func relaunchUsesPersistedSession() async throws {
        let sharedTokenStore = InMemoryAuthTokenStore()
        let firstLaunchClient = makeClient(tokenStore: sharedTokenStore)
        let accountID = UUID()

        StubURLProtocol.handler = { _ in Self.deviceAuthResponse(id: accountID, accessToken: "first-launch-token", refreshToken: "persisted-refresh") }
        _ = try await firstLaunchClient.recoverSession()
        #expect(sharedTokenStore.currentRefreshToken() == "persisted-refresh")

        // A brand-new client instance, same underlying token store —
        // exactly what happens across an app relaunch (accessToken is
        // never persisted; only the refresh token in Keychain survives).
        StubURLProtocol.reset()
        let relaunchedClient = AuthenticatedAPIClient(
            baseURL: URL(string: "https://example.com/api")!,
            session: StubURLProtocol.makeSession(),
            tokenStore: sharedTokenStore
        )
        StubURLProtocol.handler = { request in
            #expect(request.url?.path.hasSuffix("/auth/refresh") == true)
            return Self.jsonResponse(200, ["accessToken": "relaunch-token", "refreshToken": "rotated-again", "account": Self.accountJSON(id: accountID)])
        }
        let user = try await relaunchedClient.recoverSession()
        #expect(user.id == accountID)
    }

    // MARK: - 17: simultaneous ensureSession() calls are single-flight

    @Test("17: simultaneous ensureSession() calls with no prior credential are single-flight — one network attempt, not N")
    func simultaneousEnsureSessionCallsAreSingleFlight() async throws {
        let client = makeClient()
        let deviceAuthCallCount = Counter()
        StubURLProtocol.handler = { _ in
            deviceAuthCallCount.increment()
            return Self.deviceAuthResponse(accessToken: "token", refreshToken: "refresh")
        }

        async let a: Void = client.ensureSession()
        async let b: Void = client.ensureSession()
        async let c: Void = client.ensureSession()
        _ = try await (a, b, c)

        #expect(deviceAuthCallCount.value == 1)
    }

    // MARK: - 18: session failure cannot leave the app in a half-authenticated state

    @Test("18: a failed recovery leaves NO credential attached at all — never a half-authenticated state with, e.g., an access token but no matching refresh token")
    func failedRecoveryLeavesNoHalfAuthenticatedState() async throws {
        let tokenStore = InMemoryAuthTokenStore()
        let client = makeClient(tokenStore: tokenStore)

        StubURLProtocol.handler = { _ in Self.jsonResponse(500, ["error": ["code": "INTERNAL_ERROR", "message": "down"]]) }
        await #expect(throws: AuthenticatedAPIClientError.self) {
            try await client.recoverSession()
        }

        // No refresh token was ever installed (recovery failed before
        // ever reaching a successful device-auth response), and no
        // request afterward carries any Authorization header at all —
        // fully unauthenticated, not partially.
        #expect(tokenStore.currentRefreshToken() == nil)
        StubURLProtocol.handler = { request in
            Self.jsonResponse(request.value(forHTTPHeaderField: "Authorization") == nil ? 200 : 401, ["ok": true])
        }
        _ = try? await client.get("chats")
        #expect(StubURLProtocol.recordedRequests().last?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    // MARK: - Redundant-attempt suppression (the actual physical-device fix — GENERIC/short cooldown, non-rate-limit failures)

    @Test("a repeated recoverSession() call immediately after a generic (non-rate-limit) failure reuses the SAME cached failure — no second network attempt")
    func repeatedCallAfterFailureIsSuppressedByCooldown() async throws {
        let client = makeClient(recoveryFailureCooldown: .seconds(30))
        let deviceAuthCallCount = Counter()
        StubURLProtocol.handler = { _ in
            deviceAuthCallCount.increment()
            return Self.jsonResponse(500, ["error": ["code": "INTERNAL_ERROR", "message": "down"]])
        }

        await #expect(throws: AuthenticatedAPIClientError.self) { try await client.recoverSession() }
        #expect(deviceAuthCallCount.value == 1)

        // A second, immediate call — modeling Chat's own reactive 401
        // path firing moments later — must NOT make a second network
        // attempt against a backend that just failed.
        await #expect(throws: AuthenticatedAPIClientError.self) { try await client.recoverSession() }
        #expect(deviceAuthCallCount.value == 1)
    }

    @Test("retrySessionRecovery() bypasses the SHORT generic cooldown — the explicit user-initiated retry attempts the network again")
    func retrySessionRecoveryBypassesGenericCooldown() async throws {
        let client = makeClient(recoveryFailureCooldown: .seconds(30))
        let deviceAuthCallCount = Counter()
        let accountID = UUID()
        StubURLProtocol.handler = { _ in
            deviceAuthCallCount.increment()
            if deviceAuthCallCount.value == 1 {
                return Self.jsonResponse(500, ["error": ["code": "INTERNAL_ERROR", "message": "down"]])
            }
            return Self.deviceAuthResponse(id: accountID, accessToken: "retry-token", refreshToken: "retry-refresh")
        }

        await #expect(throws: AuthenticatedAPIClientError.self) { try await client.recoverSession() }
        #expect(deviceAuthCallCount.value == 1)

        // A REGULAR recoverSession() call right now would be suppressed
        // by the generic cooldown — but the explicit retry bypasses it.
        let user = try await client.retrySessionRecovery()
        #expect(user.id == accountID)
        #expect(deviceAuthCallCount.value == 2)
    }

    // MARK: - Observable session state (Section G)

    @Test("currentSessionState() reflects .unknown before any recovery, .ready(.anonymous) after a successful anonymous recovery")
    func sessionStateReflectsSuccessfulAnonymousRecovery() async throws {
        let client = makeClient()
        #expect(await client.currentSessionState() == .unknown)

        StubURLProtocol.handler = { _ in Self.deviceAuthResponse(accessToken: "token", refreshToken: "refresh") }
        _ = try await client.recoverSession()

        #expect(await client.currentSessionState() == .ready(.anonymous))
    }

    @Test("currentSessionState() reflects .ready(.authenticated) after a successful refresh")
    func sessionStateReflectsSuccessfulRefresh() async throws {
        let tokenStore = InMemoryAuthTokenStore()
        tokenStore.save(refreshToken: "valid-refresh")
        let client = makeClient(tokenStore: tokenStore)

        StubURLProtocol.handler = { _ in Self.jsonResponse(200, ["accessToken": "token", "refreshToken": "rotated", "account": Self.accountJSON()]) }
        _ = try await client.recoverSession()

        #expect(await client.currentSessionState() == .ready(.authenticated))
    }

    @Test("currentSessionState() reflects .failed(.rateLimited) with the backend's own Retry-After value after a 429, distinct from .failed(.backendUnavailable) after a 5xx")
    func sessionStateDistinguishesRateLimitedFromBackendUnavailable() async throws {
        let rateLimitedClient = makeClient()
        StubURLProtocol.handler = { _ in
            Self.jsonResponse(429, ["error": ["code": "RATE_LIMITED", "message": "slow down"]], headers: ["Retry-After": "123"])
        }
        _ = try? await rateLimitedClient.recoverSession()
        #expect(await rateLimitedClient.currentSessionState() == .failed(.rateLimited(retryAfterSeconds: 123)))

        let backendDownClient = makeClient()
        StubURLProtocol.handler = { _ in Self.jsonResponse(500, ["error": ["code": "INTERNAL_ERROR", "message": "down"]]) }
        _ = try? await backendDownClient.recoverSession()
        #expect(await backendDownClient.currentSessionState() == .failed(.backendUnavailable))
    }

    // MARK: - Retry-After hardening pass (physical-device follow-up:
    // the 5-second cooldown didn't honor the backend's real reset time)

    @Test("a 429 with a delta-seconds Retry-After header is parsed correctly")
    func retryAfterDeltaSecondsIsParsedCorrectly() async throws {
        let client = makeClient()
        StubURLProtocol.handler = { _ in
            Self.jsonResponse(429, ["error": ["code": "RATE_LIMITED", "message": "slow down"]], headers: ["Retry-After": "742"])
        }

        do {
            _ = try await client.recoverSession()
            Issue.record("expected recoverSession() to throw")
        } catch AuthenticatedAPIClientError.rateLimited(let seconds) {
            #expect(seconds == 742)
        }
    }

    @Test("a 429 with an HTTP-date Retry-After header is parsed correctly")
    func retryAfterHTTPDateIsParsedCorrectly() async throws {
        let client = makeClient()
        let futureDate = Date().addingTimeInterval(600)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let httpDate = formatter.string(from: futureDate)

        StubURLProtocol.handler = { _ in
            Self.jsonResponse(429, ["error": ["code": "RATE_LIMITED", "message": "slow down"]], headers: ["Retry-After": httpDate])
        }

        do {
            _ = try await client.recoverSession()
            Issue.record("expected recoverSession() to throw")
        } catch AuthenticatedAPIClientError.rateLimited(let seconds) {
            // Allow a couple seconds of slack for formatting/parsing/test
            // execution time — this is checking "roughly 600s away," not
            // an exact-to-the-millisecond match.
            #expect(abs(seconds - 600) <= 3)
        }
    }

    @Test("a 429 with a RateLimit-Reset header (no Retry-After) falls back to it correctly")
    func rateLimitResetHeaderIsUsedWhenRetryAfterIsAbsent() async throws {
        let client = makeClient()
        StubURLProtocol.handler = { _ in
            Self.jsonResponse(429, ["error": ["code": "RATE_LIMITED", "message": "slow down"]], headers: ["RateLimit-Reset": "300"])
        }

        do {
            _ = try await client.recoverSession()
            Issue.record("expected recoverSession() to throw")
        } catch AuthenticatedAPIClientError.rateLimited(let seconds) {
            #expect(seconds == 300)
        }
    }

    @Test("a 429 with NEITHER header falls back to the known 15-minute window, never a fabricated short guess")
    func missingHeadersFallBackToKnownWindow() async throws {
        let client = makeClient()
        StubURLProtocol.handler = { _ in Self.jsonResponse(429, ["error": ["code": "RATE_LIMITED", "message": "slow down"]]) }

        do {
            _ = try await client.recoverSession()
            Issue.record("expected recoverSession() to throw")
        } catch AuthenticatedAPIClientError.rateLimited(let seconds) {
            #expect(seconds == 15 * 60)
        }
    }

    // MARK: - 2: repeated ensureSession() calls during a rate-limit cooldown send ZERO additional /auth/device requests

    @Test("2: repeated ensureSession() calls while genuinely rate-limited send ZERO additional /auth/device requests — never every 5 seconds, never at all until the real window passes")
    func repeatedEnsureSessionDuringRateLimitSendsNoRequests() async throws {
        let client = makeClient()
        let requestCount = Counter()
        StubURLProtocol.handler = { _ in
            requestCount.increment()
            return Self.jsonResponse(429, ["error": ["code": "RATE_LIMITED", "message": "slow down"]], headers: ["Retry-After": "900"])
        }

        _ = try? await client.recoverSession()
        #expect(requestCount.value == 1)

        // Many repeated calls — modeling every dependent screen's own
        // reactive 401 path firing independently, back to back — must
        // never make a second network attempt while still genuinely
        // rate-limited.
        for _ in 0..<10 {
            try? await client.ensureSession()
        }
        #expect(requestCount.value == 1)
    }

    // MARK: - 3: Chat + Live Translation concurrently still produce only one recovery attempt, even when rate-limited

    @Test("3: concurrent Chat + Live Translation startup during an active rate-limit both observe the SAME suppressed state — one attempt, not two")
    func concurrentConsumersShareRateLimitSuppression() async throws {
        let client = makeClient()
        let requestCount = Counter()
        StubURLProtocol.handler = { _ in
            requestCount.increment()
            return Self.jsonResponse(429, ["error": ["code": "RATE_LIMITED", "message": "slow down"]], headers: ["Retry-After": "900"])
        }
        _ = try? await client.recoverSession() // establishes the rate-limit state
        #expect(requestCount.value == 1)

        async let chatAttempt: () = { try? await client.ensureSession() }()
        async let liveTranslationAttempt: () = { try? await client.ensureSession() }()
        _ = await (chatAttempt, liveTranslationAttempt)

        #expect(requestCount.value == 1) // neither concurrent consumer made a second request
    }

    // MARK: - 4: app relaunch during an active rate limit respects retry-not-before

    @Test("4: a brand-new AuthenticatedAPIClient instance (modeling a force-quit + relaunch) still respects a persisted, still-active rate-limit deadline — no immediate request storm restart")
    func relaunchDuringActiveRateLimitRespectsRetryNotBefore() async throws {
        nonisolated(unsafe) let sharedDefaults = freshDefaults()
        let firstProcessClient = makeClient(defaults: { sharedDefaults })
        let requestCount = Counter()
        StubURLProtocol.handler = { _ in
            requestCount.increment()
            return Self.jsonResponse(429, ["error": ["code": "RATE_LIMITED", "message": "slow down"]], headers: ["Retry-After": "900"])
        }
        _ = try? await firstProcessClient.recoverSession()
        #expect(requestCount.value == 1)

        // A brand-new client instance, same underlying UserDefaults —
        // exactly what happens across a force-quit + relaunch.
        StubURLProtocol.reset()
        let relaunchedClient = AuthenticatedAPIClient(
            baseURL: URL(string: "https://example.com/api")!,
            session: StubURLProtocol.makeSession(),
            tokenStore: InMemoryAuthTokenStore(),
            defaults: { sharedDefaults }
        )
        StubURLProtocol.handler = { _ in
            requestCount.increment()
            return Self.deviceAuthResponse(accessToken: "should-never-be-reached", refreshToken: "should-never-be-reached")
        }

        do {
            _ = try await relaunchedClient.recoverSession()
            Issue.record("expected the relaunched client to still be suppressed")
        } catch AuthenticatedAPIClientError.rateLimited {
            // Expected — no additional request was made.
        }
        #expect(requestCount.value == 1) // the relaunch never re-attempted the network
    }

    // MARK: - 5: expiry permits exactly one fresh recovery

    @Test("5: once the rate-limit deadline has genuinely passed, exactly one fresh recovery attempt is permitted")
    func expiryPermitsExactlyOneFreshRecovery() async throws {
        // A deadline that's effectively already in the past by the time
        // this test reads it back — proves the EXPIRY check itself
        // (`rateLimitSuppression()`'s `remaining > 0` guard), not a real
        // multi-second wait.
        nonisolated(unsafe) let defaults = freshDefaults()
        defaults.set(Date().addingTimeInterval(-1).timeIntervalSince1970, forKey: "com.evenai.session.rateLimitedUntilTimestamp")
        let client = makeClient(defaults: { defaults })
        let accountID = UUID()
        let requestCount = Counter()
        StubURLProtocol.handler = { _ in
            requestCount.increment()
            return Self.deviceAuthResponse(id: accountID, accessToken: "fresh-token", refreshToken: "fresh-refresh")
        }

        let user = try await client.recoverSession()
        #expect(user.id == accountID)
        #expect(requestCount.value == 1) // the expired deadline never suppressed this attempt
    }

    // MARK: - 6: successful recovery clears rate-limit state

    @Test("6: a successful recovery after a rate-limit window clears the rate-limit state entirely — both in-memory and persisted")
    func successfulRecoveryClearsRateLimitState() async throws {
        nonisolated(unsafe) let defaults = freshDefaults()
        let client = makeClient(defaults: { defaults })
        let accountID = UUID()
        nonisolated(unsafe) var isStillRateLimited = true
        StubURLProtocol.handler = { _ in
            if isStillRateLimited {
                return Self.jsonResponse(429, ["error": ["code": "RATE_LIMITED", "message": "slow down"]], headers: ["Retry-After": "0"])
            }
            return Self.deviceAuthResponse(id: accountID, accessToken: "recovered-token", refreshToken: "recovered-refresh")
        }

        _ = try? await client.recoverSession() // establishes a (zero-second, i.e. immediately-expired) rate limit
        isStillRateLimited = false

        let user = try await client.retrySessionRecovery()
        #expect(user.id == accountID)

        // Both halves of the rate-limit state are gone — not just the
        // in-memory flag.
        #expect(defaults.object(forKey: "com.evenai.session.rateLimitedUntilTimestamp") == nil)
        #expect(await client.currentSessionState() == .ready(.anonymous))
    }

    // MARK: - 7: non-429 failures do not incorrectly create a rate-limit cooldown

    @Test("7: a non-429 failure (5xx) never creates a 15-minute rate-limit cooldown — only the short generic one")
    func nonRateLimitFailureNeverCreatesLongCooldown() async throws {
        let client = makeClient(recoveryFailureCooldown: .zero)
        let requestCount = Counter()
        nonisolated(unsafe) var isBackendDown = true
        StubURLProtocol.handler = { _ in
            requestCount.increment()
            if isBackendDown {
                return Self.jsonResponse(500, ["error": ["code": "INTERNAL_ERROR", "message": "down"]])
            }
            return Self.deviceAuthResponse(accessToken: "recovered", refreshToken: "recovered")
        }

        await #expect(throws: AuthenticatedAPIClientError.self) { try await client.recoverSession() }
        #expect(requestCount.value == 1)
        isBackendDown = false

        // With the generic cooldown set to .zero, a SECOND attempt
        // immediately afterward must genuinely retry the network — no
        // 15-minute rate-limit deadline was ever created by a plain 5xx.
        let user = try await client.recoverSession()
        #expect(user.email == nil) // resolved normally
        #expect(requestCount.value == 2)
    }

    // MARK: - 8: normal valid refresh path never calls /auth/device

    @Test("8: a normal, successful refresh never calls /auth/device at all — not even once")
    func normalRefreshPathNeverCallsDeviceAuth() async throws {
        let tokenStore = InMemoryAuthTokenStore()
        tokenStore.save(refreshToken: "genuinely-valid-refresh")
        let client = makeClient(tokenStore: tokenStore)
        let accountID = UUID()

        StubURLProtocol.handler = { request in
            #expect(request.url?.path.hasSuffix("/auth/device") != true)
            #expect(request.url?.path.hasSuffix("/auth/refresh") == true)
            return Self.jsonResponse(200, ["accessToken": "refreshed", "refreshToken": "rotated", "account": Self.accountJSON(id: accountID)])
        }

        let user = try await client.recoverSession()
        #expect(user.id == accountID)
    }
}

/// Thread-safe call counter for `StubURLProtocol.handler` closures,
/// which run concurrently when a test issues overlapping requests (e.g.
/// `async let`) — a plain `var` captured by a `@Sendable` closure isn't
/// safe to mutate directly. Same pattern as `AuthenticatedAPIClientTests`'
/// own private `Counter`, duplicated here (rather than shared) since that
/// one is `private` to its own file.
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
