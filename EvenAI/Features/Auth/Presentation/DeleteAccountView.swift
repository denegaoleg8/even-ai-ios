import SwiftUI

/// Account deletion is genuinely not implemented — there is no
/// `/api/auth/*` endpoint for it (see `even-ai-assistant-asr/src/auth/routes.js`),
/// and Phase 3.7 explicitly scopes this to a placeholder rather than a
/// backend change. Same reasoning as `ForgotPasswordView`: state that
/// plainly instead of a dead button.
struct DeleteAccountView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            EmptyStateView(
                systemImage: "person.crop.circle.badge.xmark",
                title: "Account Deletion Isn't Available Yet",
                subtitle: "This version of Even AI doesn't support deleting your account. Sign out if you'd like to stop using it on this device."
            )
            .navigationTitle("Delete Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("deleteAccount.doneButton")
                }
            }
        }
    }
}

#Preview {
    DeleteAccountView()
}
