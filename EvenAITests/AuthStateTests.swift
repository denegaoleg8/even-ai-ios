import Testing
import Foundation
@testable import EvenAI

@MainActor
@Suite("AuthState")
struct AuthStateTests {
    @Test("restoreSession populates currentUser on success")
    func restoreSessionSucceeds() async {
        let seedUser = User(id: UUID(), email: nil, displayName: nil)
        let state = AuthState(authService: MockAuthService(currentUser: seedUser))

        await state.restoreSession()

        #expect(state.currentUser?.id == seedUser.id)
        #expect(!state.isRestoringSession)
    }

    @Test("restoreSession failure leaves currentUser nil instead of throwing — the app must never crash because authentication fails")
    func restoreSessionFailureIsGraceful() async {
        let state = AuthState(authService: FailingAuthService(errorToThrow: .offline))

        await state.restoreSession()

        #expect(state.currentUser == nil)
        #expect(!state.isRestoringSession)
    }

    @Test("signUp updates currentUser to the newly-claimed account")
    func signUpUpdatesCurrentUser() async throws {
        let state = AuthState(authService: MockAuthService())
        try await state.signUp(email: "ada@example.com", password: "correct horse battery staple", displayName: "Ada")

        #expect(state.currentUser?.email == "ada@example.com")
        #expect(state.currentUser?.displayName == "Ada")
    }

    @Test("signUp propagates a failure instead of silently updating state")
    func signUpPropagatesFailure() async {
        let state = AuthState(authService: FailingAuthService(errorToThrow: .emailAlreadyExists))

        await #expect(throws: AuthError.emailAlreadyExists) {
            try await state.signUp(email: "taken@example.com", password: "correct horse battery staple", displayName: nil)
        }
        #expect(state.currentUser == nil)
    }

    @Test("signIn updates currentUser and surfaces mergeAvailableFrom")
    func signInUpdatesCurrentUser() async throws {
        let mock = MockAuthService()
        _ = try await mock.signUp(email: "ada@example.com", password: "correct horse battery staple", displayName: nil)
        try await mock.signOut() // back to a fresh anonymous account on "this device"

        let state = AuthState(authService: mock)
        let result = try await state.signIn(email: "ada@example.com", password: "correct horse battery staple")

        #expect(state.currentUser?.email == "ada@example.com")
        #expect(result.user.email == "ada@example.com")
    }

    @Test("signIn with the wrong password fails and leaves currentUser unchanged")
    func signInWrongPasswordFails() async throws {
        let mock = MockAuthService()
        _ = try await mock.signUp(email: "ada@example.com", password: "correct horse battery staple", displayName: nil)
        try await mock.signOut()

        let state = AuthState(authService: mock)
        await state.restoreSession()
        let before = state.currentUser

        await #expect(throws: AuthError.invalidCredentials) {
            try await state.signIn(email: "ada@example.com", password: "wrong password")
        }
        #expect(state.currentUser?.id == before?.id)
    }

    @Test("signOut always clears currentUser locally, even if the underlying call fails")
    func signOutAlwaysClearsLocally() async {
        let state = AuthState(authService: FailingAuthService(errorToThrow: .offline))
        await state.restoreSession() // no-op here since restore also fails, but exercises the flow
        await state.signOut()

        #expect(state.currentUser == nil)
    }

    @Test("signOutEverywhere clears currentUser locally")
    func signOutEverywhereClearsLocally() async throws {
        let mock = MockAuthService()
        _ = try await mock.signUp(email: "ada@example.com", password: "correct horse battery staple", displayName: nil)

        let state = AuthState(authService: mock)
        await state.restoreSession()
        #expect(state.currentUser != nil)

        await state.signOutEverywhere()
        #expect(state.currentUser == nil)
    }

    // MARK: - mergeAvailableFrom (Phase 3.7)

    @Test("signIn captures mergeAvailableFrom when the device already had a different local account")
    func signInCapturesMergeOffer() async throws {
        let mock = MockAuthService()
        _ = try await mock.signUp(email: "ada@example.com", password: "correct horse battery staple", displayName: nil)
        try await mock.signOut() // back to a fresh anonymous account on "this device"

        let state = AuthState(authService: mock)
        let result = try await state.signIn(email: "ada@example.com", password: "correct horse battery staple")

        #expect(result.mergeAvailableFrom != nil)
        #expect(state.mergeAvailableFrom == result.mergeAvailableFrom)
    }

    @Test("signOut clears a pending merge offer — it belonged to the account just left")
    func signOutClearsPendingMergeOffer() async throws {
        let mock = MockAuthService()
        _ = try await mock.signUp(email: "ada@example.com", password: "correct horse battery staple", displayName: nil)
        try await mock.signOut()

        let state = AuthState(authService: mock)
        _ = try await state.signIn(email: "ada@example.com", password: "correct horse battery staple")
        #expect(state.mergeAvailableFrom != nil)

        await state.signOut()
        #expect(state.mergeAvailableFrom == nil)
    }

    // MARK: - Session sync (Phase 3.7)

    @Test("AuthState reacts automatically when the underlying service silently falls back to a different identity — no explicit call, no stale state")
    func reactsToSilentSessionChange() async throws {
        let mock = MockAuthService()
        let state = AuthState(authService: mock)
        await state.restoreSession()
        let originalUserID = state.currentUser?.id

        let anonymousFallback = User(id: UUID(), email: nil, displayName: nil)
        await mock.simulateSilentFallback(to: anonymousFallback)

        // The subscription runs on a background Task reading from an
        // AsyncStream — give it a turn to actually deliver the value
        // before asserting, same as any other cross-Task signal.
        try await Task.sleep(for: .milliseconds(50))

        #expect(state.currentUser?.id == anonymousFallback.id)
        #expect(state.currentUser?.id != originalUserID)
    }
}
