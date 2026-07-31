import Testing
import Foundation
@testable import EvenAI

@MainActor
@Suite("SignUpViewModel")
struct SignUpViewModelTests {
    @Test("canSubmit requires a valid email, an 8+ character password, and matching confirmation")
    func canSubmitGating() {
        let viewModel = SignUpViewModel()
        viewModel.email = "ada@example.com"
        viewModel.password = "short"
        viewModel.confirmPassword = "short"
        #expect(viewModel.canSubmit == false) // too short

        viewModel.password = "correct horse battery staple"
        viewModel.confirmPassword = "different"
        #expect(viewModel.canSubmit == false) // doesn't match

        viewModel.confirmPassword = "correct horse battery staple"
        #expect(viewModel.canSubmit == true)
    }

    @Test("mismatched-password validation message only appears once the password itself is valid")
    func confirmPasswordMessageWaitsOnPasswordValidity() async {
        let viewModel = SignUpViewModel()
        viewModel.email = "ada@example.com"
        viewModel.password = "short"
        viewModel.confirmPassword = "different"

        _ = await viewModel.submit(using: AuthState(authService: MockAuthService()))

        #expect(viewModel.passwordValidationMessage != nil)
        // The password itself is already invalid, so the mismatch message
        // would be redundant noise — one error at a time.
        #expect(viewModel.confirmPasswordValidationMessage == nil)
    }

    @Test("submit claims the current anonymous account and updates AuthState")
    func submitSucceeds() async {
        let authState = AuthState(authService: MockAuthService())
        let viewModel = SignUpViewModel()
        viewModel.email = "ada@example.com"
        viewModel.password = "correct horse battery staple"
        viewModel.confirmPassword = "correct horse battery staple"
        viewModel.displayName = "Ada"

        let succeeded = await viewModel.submit(using: authState)

        #expect(succeeded == true)
        #expect(viewModel.isSubmitting == false)
        #expect(authState.currentUser?.email == "ada@example.com")
        #expect(authState.currentUser?.displayName == "Ada")
    }

    @Test("an empty display name is sent as nil, not an empty string")
    func blankDisplayNameBecomesNil() async {
        let mock = MockAuthService()
        let authState = AuthState(authService: mock)
        let viewModel = SignUpViewModel()
        viewModel.email = "ada@example.com"
        viewModel.password = "correct horse battery staple"
        viewModel.confirmPassword = "correct horse battery staple"
        viewModel.displayName = "   "

        _ = await viewModel.submit(using: authState)

        #expect(authState.currentUser?.displayName == nil)
    }

    @Test("a duplicate email fails with a friendly, non-leaking error")
    func duplicateEmailFails() async {
        let authState = AuthState(authService: FailingAuthService(errorToThrow: .emailAlreadyExists))
        let viewModel = SignUpViewModel()
        viewModel.email = "taken@example.com"
        viewModel.password = "correct horse battery staple"
        viewModel.confirmPassword = "correct horse battery staple"

        let succeeded = await viewModel.submit(using: authState)

        #expect(succeeded == false)
        #expect(viewModel.errorMessage == AuthError.emailAlreadyExists.errorDescription)
    }
}
