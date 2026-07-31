import Testing
import Foundation
@testable import EvenAI

@MainActor
@Suite("LoginViewModel")
struct LoginViewModelTests {
    @Test("canSubmit is false until both fields are valid")
    func canSubmitGating() {
        let viewModel = LoginViewModel()
        #expect(viewModel.canSubmit == false)

        viewModel.email = "ada@example.com"
        #expect(viewModel.canSubmit == false) // still no password

        viewModel.password = "correct horse battery staple"
        #expect(viewModel.canSubmit == true)
    }

    @Test("validation messages stay nil until a submit attempt")
    func validationMessagesAreQuiedUntilSubmit() async {
        let viewModel = LoginViewModel()
        viewModel.email = "not-an-email"
        #expect(viewModel.emailValidationMessage == nil)
        #expect(viewModel.passwordValidationMessage == nil)

        _ = await viewModel.submit(using: AuthState(authService: MockAuthService()))

        #expect(viewModel.emailValidationMessage != nil)
        #expect(viewModel.passwordValidationMessage != nil) // password was also empty
    }

    @Test("submit with correct credentials succeeds and updates AuthState")
    func submitSucceeds() async throws {
        let mock = MockAuthService()
        _ = try await mock.signUp(email: "ada@example.com", password: "correct horse battery staple", displayName: nil)
        try await mock.signOut() // back to a fresh anonymous account, as if on a different device

        let authState = AuthState(authService: mock)
        let viewModel = LoginViewModel()
        viewModel.email = "ada@example.com"
        viewModel.password = "correct horse battery staple"

        let succeeded = await viewModel.submit(using: authState)

        #expect(succeeded == true)
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.isSubmitting == false)
        #expect(authState.currentUser?.email == "ada@example.com")
    }

    @Test("submit with the wrong password fails with a friendly, non-leaking error")
    func submitFailsWithFriendlyError() async throws {
        let mock = MockAuthService()
        _ = try await mock.signUp(email: "ada@example.com", password: "correct horse battery staple", displayName: nil)
        try await mock.signOut()

        let authState = AuthState(authService: mock)
        let viewModel = LoginViewModel()
        viewModel.email = "ada@example.com"
        viewModel.password = "wrong password"

        let succeeded = await viewModel.submit(using: authState)

        #expect(succeeded == false)
        #expect(viewModel.errorMessage == AuthError.invalidCredentials.errorDescription)
        #expect(authState.currentUser == nil)
    }

    @Test("submit never calls through when the form is invalid")
    func submitSkipsInvalidForm() async {
        let authState = AuthState(authService: FailingAuthService())
        let viewModel = LoginViewModel()
        viewModel.email = "" // empty — invalid

        let succeeded = await viewModel.submit(using: authState)

        #expect(succeeded == false)
        #expect(authState.currentUser == nil)
    }

    @Test("a server-unavailable failure surfaces the corresponding friendly message")
    func serverUnavailableSurfacesFriendlyMessage() async {
        let authState = AuthState(authService: FailingAuthService(errorToThrow: .serverUnavailable))
        let viewModel = LoginViewModel()
        viewModel.email = "ada@example.com"
        viewModel.password = "correct horse battery staple"

        _ = await viewModel.submit(using: authState)

        #expect(viewModel.errorMessage == AuthError.serverUnavailable.errorDescription)
    }
}
