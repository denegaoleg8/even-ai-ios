import SwiftUI

struct ChatRowView: View {
    let chat: Chat

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetrics.Spacing.xs) {
            HStack {
                Text(chat.title)
                    .font(AppTypography.chatTitle)
                    .lineLimit(1)
                Spacer()
                Text(chat.updatedAt, style: .relative)
                    .font(AppTypography.timestamp)
                    .foregroundStyle(AppColor.textSecondary)
            }

            if let preview = chat.lastMessagePreview {
                Text(preview)
                    .font(AppTypography.chatPreview)
                    .foregroundStyle(AppColor.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, AppMetrics.Spacing.xs)
    }
}

#Preview {
    List {
        ChatRowView(chat: Chat(title: "Trip planning", lastMessagePreview: "Sure, here's a packing list..."))
        ChatRowView(chat: Chat(title: "New Chat"))
    }
}
