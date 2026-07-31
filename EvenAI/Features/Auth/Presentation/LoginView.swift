import SwiftUI

struct LoginView: View {
    /// Called on a successful sign-in. Deliberately not `@Environment(\.dismiss)`:
    /// this view is reached by pushing onto `AuthWelcomeView`'s
    /// `NavigationStack`, where `dismiss()` would only pop this one
    /// screen back to Welcome — the whole auth sheet needs to close, all
    /// the way back to Settings, which only the sheet's presenter knows
    /// how to do.
    var onAuthenticated: () -> Void

    @Environment(AuthState.self) private var authState
    @State private var viewModel = LoginViewModel()
    @State private var isForgotPasswordPresented = false

    private enum Field: Hashable { case email, password }
    @FocusState private var focusedField: Field?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppMetrics.Spacing.lg) {
                VStack(alignment: .leading, spacing: AppMetrics.Spacing.xs) {
                    Text("Welcome Back")
                        .font(AppTypography.screenTitle)
                    Text("Sign in to sync your conversations across devices.")
                        .font(AppTypography.chatPreview)
                        .foregroundStyle(AppColor.textSecondary)
                }

                VStack(alignment: .leading, spacing: AppMetrics.Spacing.md) {
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
                            identifier: "login.emailField"
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
                            textContentType: .password,
                            submitLabel: .go,
                            onSubmit: { Task { await submit() } },
                            identifier: "login.passwordField"
                        )
                        .focused($focusedField, equals: .password)

                        if let message = viewModel.passwordValidationMessage {
                            InlineErrorText(message: message)
                        }
                    }

                    Button("Forgot Password?") {
                        isForgotPasswordPresented = true
                    }
                    .font(AppTypography.chatPreview)
                    .foregroundStyle(AppColor.accent)
                }

                if let errorMessage = viewModel.errorMessage {
                    InlineErrorText(message: errorMessage)
                        .accessibilityIdentifier("login.errorText")
                }

                PrimaryButton("Sign In", isLoading: viewModel.isSubmitting) {
                    Task { await submit() }
                }
                .disabled(!viewModel.canSubmit)
                .accessibilityIdentifier("login.submitButton")

                HStack {
                    Spacer()
                    Text("Don't have an account?")
                        .foregroundStyle(AppColor.textSecondary)
                    NavigationLink("Sign Up") {
                        SignUpView(onAuthenticated: onAuthenticated)
                    }
                    .accessibilityIdentifier("login.signUpLink")
                    Spacer()
                }
                .font(AppTypography.chatPreview)
            }
            .padding(AppMetrics.Spacing.lg)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Sign In")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isForgotPasswordPresented) {
            ForgotPasswordView()
        }
        .animation(.easeOut(duration: 0.2), value: viewModel.errorMessage)
    }

    private func submit() async {
        focusedField = nil
        guard await viewModel.submit(using: authState) else { return }
        onAuthenticated()
    }
}

#Preview {
    NavigationStack {
        LoginView(onAuthenticated: {})
    }
    .environment(AuthState())
    .environment(AppState())
}
