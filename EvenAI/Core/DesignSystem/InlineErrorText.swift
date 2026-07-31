import SwiftUI

/// Inline, friendly error message for forms — auth screens' one place to
/// surface `AuthError.errorDescription` (never a raw backend message; see
/// `AuthError`, whose every case already has a safe, user-facing string).
struct InlineErrorText: View {
    let message: String

    var body: some View {
        Label {
            Text(message)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(AppTypography.chatPreview)
        .foregroundStyle(AppColor.destructive)
        .accessibilityElement(children: .combine)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

#Preview {
    InlineErrorText(message: "Invalid email or password.")
        .padding()
}
