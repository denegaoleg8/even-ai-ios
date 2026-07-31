import Testing
import Foundation
@testable import EvenAI

@MainActor
@Suite("MergeAccountViewModel")
struct MergeAccountViewModelTests {
    @Test("a successful merge bumps AppState's chat refresh token and reports success")
    func mergeSucceeds() async throws {
        let mock = MockAuthService()
        _ = try await mock.signUp(email: "ada@example.com", password: "correct horse battery staple", displayName: nil)
        let authState = AuthState(authService: mock)
        await authState.restoreSession()
        let appState = AppState()
        let fromAccountID = UUID()

        let viewModel = MergeAccountViewModel(fromAccountID: fromAccountID)
        #expect(appState.chatListRefreshToken == 0)

        await viewModel.merge(using: authState, appState: appState)

        #expect(viewModel.didMergeSuccessfully == true)
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.isMerging == false)
        #expect(appState.chatListRefreshToken == 1)
    }

    @Test("a successful merge clears AuthState's pending merge offer")
    func mergeClearsPendingOffer() async throws {
        let mock = MockAuthService()
        _ = try await mock.signUp(email: "ada@example.com", password: "correct horse battery staple", displayName: nil)
        try await mock.signOut()

        let authState = AuthState(authService: mock)
        let result = try await authState.signIn(email: "ada@example.com", password: "correct horse battery staple")
        #expect(result.mergeAvailableFrom != nil)
        #expect(authState.mergeAvailableFrom != nil)

        let viewModel = MergeAccountViewModel(fromAccountID: result.mergeAvailableFrom!)
        await viewModel.merge(using: authState, appState: AppState())

        #expect(authState.mergeAvailableFrom == nil)
    }

    @Test("a failed merge surfaces a friendly error and never bumps the refresh token")
    func mergeFailureSurfacesError() async {
        let authState = AuthState(authService: FailingAuthService(errorToThrow: .serverUnavailable))
        let appState = AppState()
        let viewModel = MergeAccountViewModel(fromAccountID: UUID())

        await viewModel.merge(using: authState, appState: appState)

        #expect(viewModel.didMergeSuccessfully == false)
        #expect(viewModel.errorMessage == AuthError.serverUnavailable.errorDescription)
        #expect(appState.chatListRefreshToken == 0)
    }

    @Test("skipping never calls merge — the offer stays available for later")
    func skipLeavesOfferPending() async throws {
        // "Skip" isn't a view-model action at all: LoginView/MergeAccountView
        // simply don't call merge(). This test documents that contract by
        // confirming AuthState's offer survives untouched when nothing
        // merges — i.e. there is no separate cleanup path to forget.
        let mock = MockAuthService()
        _ = try await mock.signUp(email: "ada@example.com", password: "correct horse battery staple", displayName: nil)
        try await mock.signOut()

        let authState = AuthState(authService: mock)
        let result = try await authState.signIn(email: "ada@example.com", password: "correct horse battery staple")

        #expect(authState.mergeAvailableFrom == result.mergeAvailableFrom)
        #expect(authState.mergeAvailableFrom != nil)
        // No merge() call here — Skip. The offer is still there afterward.
        #expect(authState.mergeAvailableFrom != nil)
    }
}
