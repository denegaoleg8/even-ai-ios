import SwiftUI

/// Entry point into the auth flow, presented as a sheet from Settings'
/// Account section — never shown automatically or on launch. Even AI is
/// anonymous-by-default (every device already has a working, if
/// unclaimed, account the moment it's installed), so there is nothing
/// here that gates the rest of the app; this screen only exists for
/// someone who deliberately chose to create an account or sign into an
/// existing one.
struct AuthWelcomeView: View {
    /// Threaded down to `LoginView`/`SignUpView` — see their own doc
    /// comments for why this isn't just `@Environment(\.dismiss)`.
    var onAuthenticated: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: AppMetrics.Spacing.xl) {
                Spacer()

                VStack(spacing: AppMetrics.Spacing.md) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(AppColor.accent)
                        .accessibilityHidden(true)

                    VStack(spacing: AppMetrics.Spacing.xs) {
                        Text("Even AI")
                            .font(AppTypography.screenTitle)
                        Text("Create an account to sync your conversations across every device.")
                            .font(AppTypography.chatPreview)
                            .foregroundStyle(AppColor.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, AppMetrics.Spacing.lg)
                    }
                }

                Spacer()

                VStack(spacing: AppMetrics.Spacing.sm) {
                    NavigationLink {
                        SignUpView(onAuthenticated: onAuthenticated)
                    } label: {
                        Text("Create Account")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, AppMetrics.Spacing.sm)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppColor.accent)
                    .accessibilityIdentifier("welcome.createAccountButton")

                    NavigationLink {
                        LoginView(onAuthenticated: onAuthenticated)
                    } label: {
                        Text("Sign In")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, AppMetrics.Spacing.sm)
                    }
                    .buttonStyle(.bordered)
                    .tint(AppColor.accent)
                    .accessibilityIdentifier("welcome.signInButton")
                }
                .padding(.horizontal, AppMetrics.Spacing.lg)
                .padding(.bottom, AppMetrics.Spacing.lg)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppColor.background)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("welcome.cancelButton")
                }
            }
        }
    }
}

#Preview {
    AuthWelcomeView(onAuthenticated: {})
        .environment(AuthState())
}
