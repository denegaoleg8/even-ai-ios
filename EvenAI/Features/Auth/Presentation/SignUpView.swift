import SwiftUI

struct SignUpView: View {
    /// See `LoginView.onAuthenticated` — same reasoning, same contract.
    var onAuthenticated: () -> Void

    @Environment(AuthState.self) private var authState
    @State private var viewModel = SignUpViewModel()

    private enum Field: Hashable { case displayName, email, password, confirmPassword }
    @FocusState private var focusedField: Field?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppMetrics.Spacing.lg) {
                VStack(alignment: .leading, spacing: AppMetrics.Spacing.xs) {
                    Text("Create Account")
                        .font(AppTypography.screenTitle)
                    Text("Your existing conversations on this device stay right where they are.")
                        .font(AppTypography.chatPreview)
                        .foregroundStyle(AppColor.textSecondary)
                }

                VStack(alignment: .leading, spacing: AppMetrics.Spacing.md) {
                    FormTextField(
                        title: "Name (optional)",
                        text: $viewModel.displayName,
                        textContentType: .name,
                        submitLabel: .next,
                        onSubmit: { focusedField = .email },
                        identifier: "signup.displayNameField"
                    )
                    .focused($focusedField, equals: .displayName)

                    VStack(alignment: .leading, spacing: AppMetrics.Spacing.xs) {
                        FormTextField(
                            title: "Email",
                            text: $viewModel.email,
                            textContentType: .emailAddress,
                            keyboardType: .emailAddress,
                            textInputAutocapitalization: .never,
                            autocorrectionDisabled: true,
                            submitLabel: .next,
                            onSubmit: { focusedField = .password },
                            identifier: "signup.emailField"
                        )
                        .focused($focusedField, equals: .email)

                        if let message = viewModel.emailValidationMessage {
                            InlineErrorText(message: message)
                        }
                    }

                    VStack(alignment: .leading, spacing: AppMetrics.Spacing.xs) {
                        FormTextField(
                            title: "Password",
                            text: $viewModel.password,
                            isSecure: true,
                            textContentType: .newPassword,
                            submitLabel: .next,
                            onSubmit: { focusedField = .confirmPassword },
                            identifier: "signup.passwordField"
                        )
                        .focused($focusedField, equals: .password)

                        if let message = viewModel.passwordValidationMessage {
                            InlineErrorText(message: message)
                        }
                    }

                    VStack(alignment: .leading, spacing: AppMetrics.Spacing.xs) {
                        FormTextField(
                            title: "Confirm Password",
                            text: $viewModel.confirmPassword,
                            isSecure: true,
                            textContentType: .newPassword,
                            submitLabel: .go,
                            onSubmit: { Task { await submit() } },
                            identifier: "signup.confirmPasswordField"
                        )
                        .focused($focusedField, equals: .confirmPassword)

                        if let message = viewModel.confirmPasswordValidationMessage {
                            InlineErrorText(message: message)
                        }
                    }
                }

                if let errorMessage = viewModel.errorMessage {
                    InlineErrorText(message: errorMessage)
                        .accessibilityIdentifier("signup.errorText")
                }

                PrimaryButton("Create Account", isLoading: viewModel.isSubmitting) {
                    Task { await submit() }
                }
                .disabled(!viewModel.canSubmit)
                .accessibilityIdentifier("signup.submitButton")

                Text("By creating an account you agree to sync this device's conversations to it.")
                    .font(AppTypography.timestamp)
                    .foregroundStyle(AppColor.textSecondary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
            .padding(AppMetrics.Spacing.lg)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Create Account")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.easeOut(duration: 0.2), value: viewModel.errorMessage)
    }

    private func submit() async {
        focusedField = nil
        if await viewModel.submit(using: authState) {
            onAuthenticated()
        }
    }
}

#Preview {
    NavigationStack {
        SignUpView(onAuthenticated: {})
    }
    .environment(AuthState())
}
