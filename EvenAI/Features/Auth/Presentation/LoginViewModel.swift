import Foundation
import Observation

/// Form state + validation for `LoginView`. Deliberately holds no
/// `AuthServicing` of its own — `AuthState` already owns every
/// auth action and is the single place `currentUser` gets updated (see
/// its doc comment); this view model only ever calls through it, the
/// same way `ChatListViewModel` only ever calls through `ChatServicing`.
@MainActor
@Observable
final class LoginViewModel {
    var email: String = ""
    var password: String = ""
    private(set) var isSubmitting = false
    private(set) var errorMessage: String?

    /// Validation messages only appear after a submit attempt — showing
    /// "Email is required" while someone is still typing their first
    /// character would be nagging, not helpful.
    private var didAttemptSubmit = false

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var isEmailValid: Bool {
        !trimmedEmail.isEmpty && trimmedEmail.contains("@") && trimmedEmail.contains(".")
    }

    var emailValidationMessage: String? {
        guard didAttemptSubmit, !isEmailValid else { return nil }
        return trimmedEmail.isEmpty ? "Email is required." : "Enter a valid email address."
    }

    var passwordValidationMessage: String? {
        guard didAttemptSubmit, password.isEmpty else { return nil }
        return "Password is required."
    }

    var canSubmit: Bool {
        isEmailValid && !password.isEmpty && !isSubmitting
    }

    /// Returns `true` on success, so the view can dismiss itself — errors
    /// are already captured in `errorMessage` and never thrown back out,
    /// matching every other screen's "never crash on an auth failure"
    /// contract.
    @discardableResult
    func submit(using authState: AuthState) async -> Bool {
        didAttemptSubmit = true
        errorMessage = nil
        guard canSubmit else { return false }

        isSubmitting = true
        defer { isSubmitting = false }

        do {
            _ = try await authState.signIn(email: trimmedEmail, password: password)
            return true
        } catch {
            errorMessage = Self.friendlyMessage(for: error)
            return false
        }
    }

    /// `AuthError.errorDescription` is already written to be safe to show
    /// directly (see that type) — never a raw backend message. This only
    /// exists to give a non-`AuthError` (which shouldn't happen, since
    /// every `AuthServicing` implementation maps to one, but `signIn`'s
    /// signature doesn't statically guarantee it) the same safe fallback.
    private static func friendlyMessage(for error: Error) -> String {
        (error as? AuthError)?.errorDescription ?? AuthError.unknown.errorDescription ?? "Something went wrong."
    }
}
