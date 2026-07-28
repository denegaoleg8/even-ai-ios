import SwiftUI

/// The app's single prominent call-to-action button style, used anywhere a
/// screen needs one clear primary action (empty states, onboarding, etc.).
struct PrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    let action: () -> Void

    init(_ title: String, systemImage: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label {
                Text(title)
            } icon: {
                if let systemImage {
                    Image(systemName: systemImage)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppMetrics.Spacing.sm)
        }
        .buttonStyle(.borderedProminent)
        .tint(AppColor.accent)
    }
}

#Preview {
    PrimaryButton("Start New Chat", systemImage: "plus.bubble") {}
        .padding()
}
