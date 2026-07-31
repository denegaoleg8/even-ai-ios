import SwiftUI

/// A labeled text field for auth-style forms (email, password, display
/// name). `isSecure` adds a show/hide toggle rather than a permanently
/// masked field — masked-forever password fields are what cause most
/// sign-up typos. Purely presentational: validation and error text live
/// in the caller's view model, surfaced separately via `InlineErrorText`.
struct FormTextField: View {
    let title: String
    @Binding var text: String
    var isSecure: Bool = false
    var textContentType: UITextContentType? = nil
    var keyboardType: UIKeyboardType = .default
    var textInputAutocapitalization: TextInputAutocapitalization = .sentences
    var autocorrectionDisabled: Bool = false
    var submitLabel: SubmitLabel = .next
    var onSubmit: (() -> Void)? = nil
    /// Applied to the actual `TextField`/`SecureField`, not this view's
    /// outer container — `FormTextField` renders as a label + control (+
    /// an optional reveal button), so an identifier set on the container
    /// from a call site would never reach the one element XCUITest's
    /// `.textFields[...]`/`.secureTextFields[...]` queries actually look
    /// for.
    var identifier: String? = nil

    @FocusState private var isFocused: Bool
    @State private var isRevealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetrics.Spacing.xs) {
            Text(title)
                .font(AppTypography.timestamp)
                .foregroundStyle(AppColor.textSecondary)

            HStack(spacing: AppMetrics.Spacing.sm) {
                Group {
                    if isSecure && !isRevealed {
                        SecureField(title, text: $text)
                    } else {
                        TextField(title, text: $text)
                    }
                }
                .focused($isFocused)
                .textContentType(textContentType)
                .keyboardType(keyboardType)
                .textInputAutocapitalization(textInputAutocapitalization)
                .autocorrectionDisabled(autocorrectionDisabled)
                .submitLabel(submitLabel)
                .onSubmit { onSubmit?() }
                .labelsHidden()
                .accessibilityLabel(title)
                .accessibilityIdentifier(identifier ?? "")

                if isSecure {
                    Button {
                        isRevealed.toggle()
                    } label: {
                        Image(systemName: isRevealed ? "eye.slash" : "eye")
                            .foregroundStyle(AppColor.textSecondary)
                    }
                    .accessibilityLabel(isRevealed ? "Hide \(title.lowercased())" : "Show \(title.lowercased())")
                }
            }
            .padding(.horizontal, AppMetrics.Spacing.md)
            .padding(.vertical, AppMetrics.Spacing.sm)
            .background(AppColor.secondaryBackground)
            .clipShape(RoundedRectangle(cornerRadius: AppMetrics.Radius.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppMetrics.Radius.medium, style: .continuous)
                    .strokeBorder(isFocused ? AppColor.accent : .clear, lineWidth: 1.5)
            )
        }
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

#Preview {
    @Previewable @State var email = ""
    @Previewable @State var password = "correct horse battery staple"

    VStack(spacing: AppMetrics.Spacing.md) {
        FormTextField(
            title: "Email",
            text: $email,
            textContentType: .emailAddress,
            keyboardType: .emailAddress,
            textInputAutocapitalization: .never,
            autocorrectionDisabled: true
        )
        FormTextField(title: "Password", text: $password, isSecure: true, textContentType: .password, submitLabel: .go)
    }
    .padding()
}
