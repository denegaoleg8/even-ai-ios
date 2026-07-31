import SwiftUI

/// Password reset is genuinely not implemented — the backend has no
/// `/api/auth/*` endpoint for it (see `even-ai-assistant-asr/src/auth/routes.js`).
/// Rather than a dead, unexplained "Forgot Password?" link, tapping it
/// opens this screen so that's stated plainly instead of discovered by
/// trial and error.
struct ForgotPasswordView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            EmptyStateView(
                systemImage: "lock.slash",
                title: "Password Reset Isn't Available Yet",
                subtitle: "This version of Even AI doesn't support resetting your password. Double-check your email and password, or create a new account."
            )
            .navigationTitle("Forgot Password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("forgotPassword.doneButton")
                }
            }
        }
    }
}

#Preview {
    ForgotPasswordView()
}
