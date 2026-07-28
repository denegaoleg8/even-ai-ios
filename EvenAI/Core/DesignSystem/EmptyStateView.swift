import SwiftUI

/// Generic empty/placeholder state: icon, title, optional subtitle and
/// action. Reused for "no chat selected," "no messages yet," and every
/// future-module placeholder screen (Voice, Vision, Glasses).
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    var subtitle: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: AppMetrics.Spacing.md) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(AppColor.textSecondary)

            VStack(spacing: AppMetrics.Spacing.xs) {
                Text(title)
                    .font(AppTypography.chatTitle)
                    .foregroundStyle(AppColor.textPrimary)

                if let subtitle {
                    Text(subtitle)
                        .font(AppTypography.chatPreview)
                        .foregroundStyle(AppColor.textSecondary)
                        .multilineTextAlignment(.center)
                }
            }

            if let actionTitle, let action {
                PrimaryButton(actionTitle, action: action)
                    .frame(maxWidth: 240)
                    .padding(.top, AppMetrics.Spacing.xs)
            }
        }
        .padding(AppMetrics.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    EmptyStateView(
        systemImage: "bubble.left.and.bubble.right",
        title: "No Chat Selected",
        subtitle: "Choose a chat from the list or start a new one.",
        actionTitle: "New Chat",
        action: {}
    )
}
