import Foundation
import Observation

/// Form state + validation for `SignUpView`. Same "no `AuthServicing` of
/// its own, always go through `AuthState`" reasoning as `LoginViewModel`.
@MainActor
@Observable
final class SignUpViewModel {
    var email: String = ""
    var password: String = ""
    var confirmPassword: String = ""
    var displayName: String = ""
    private(set) var isSubmitting = false
    private(set) var errorMessage: String?

    private var didAttemptSubmit = false

    /// Matches the backend's own minimum (`MIN_PASSWORD_LENGTH` in
    /// `src/auth/routes.js`) — failing fast client-side beats a round
    /// trip just to learn the same thing.
    private static let minimumPasswordLength = 8

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedDisplayName: String { displayName.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var isEmailValid: Bool {
        !trimmedEmail.isEmpty && trimmedEmail.contains("@") && trimmedEmail.contains(".")
    }

    private var isPasswordValid: Bool {
        password.count >= Self.minimumPasswordLength
    }

    private var doPasswordsMatch: Bool {
        password == confirmPassword
    }

    var emailValidationMessage: String? {
        guard didAttemptSubmit, !isEmailValid else { return nil }
        return trimmedEmail.isEmpty ? "Email is required." : "Enter a valid email address."
    }

    var passwordValidationMessage: String? {
        guard didAttemptSubmit, !isPasswordValid else { return nil }
        return "Password must be at least \(Self.minimumPasswordLength) characters."
    }

    var confirmPasswordValidationMessage: String? {
        guard didAttemptSubmit, isPasswordValid, !doPasswordsMatch else { return nil }
        return "Passwords don't match."
    }

    var canSubmit: Bool {
        isEmailValid && isPasswordValid && doPasswordsMatch && !isSubmitting
    }

    @discardableResult
    func submit(using authState: AuthState) async -> Bool {
        didAttemptSubmit = true
        errorMessage = nil
        guard canSubmit else { return false }

        isSubmitting = true
        defer { isSubmitting = false }

        do {
            _ = try await authState.signUp(
                email: trimmedEmail,
                password: password,
                displayName: trimmedDisplayName.isEmpty ? nil : trimmedDisplayName
            )
            return true
        } catch {
            errorMessage = Self.friendlyMessage(for: error)
            return false
        }
    }

    private static func friendlyMessage(for error: Error) -> String {
        (error as? AuthError)?.errorDescription ?? AuthError.unknown.errorDescription ?? "Something went wrong."
    }
}
