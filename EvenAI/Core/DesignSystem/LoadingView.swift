import SwiftUI

struct LoadingView: View {
    var label: String = "Loading..."

    var body: some View {
        VStack(spacing: AppMetrics.Spacing.sm) {
            ProgressView()
            Text(label)
                .font(AppTypography.chatPreview)
                .foregroundStyle(AppColor.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    LoadingView()
}
