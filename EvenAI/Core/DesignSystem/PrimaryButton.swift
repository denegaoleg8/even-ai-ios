import SwiftUI

/// The app's single prominent call-to-action button style, used anywhere a
/// screen needs one clear primary action (empty states, onboarding, etc.).
struct PrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    /// Swaps the label for a spinner and disables the button, without
    /// changing its size — used by async actions (sign in, sign up) so
    /// the button doesn't jump around while its result is pending.
    var isLoading: Bool = false
    let action: () -> Void

    init(_ title: String, systemImage: String? = nil, isLoading: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.isLoading = isLoading
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                if isLoading {
                    ProgressView()
                        .tint(.white)
                } else {
                    Label {
                        Text(title)
                    } icon: {
                        if let systemImage {
                            Image(systemName: systemImage)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppMetrics.Spacing.sm)
        }
        .buttonStyle(.borderedProminent)
        .tint(AppColor.accent)
        .disabled(isLoading)
        .accessibilityLabel(isLoading ? "\(title), loading" : title)
    }
}

#Preview {
    PrimaryButton("Start New Chat", systemImage: "plus.bubble") {}
        .padding()
}
