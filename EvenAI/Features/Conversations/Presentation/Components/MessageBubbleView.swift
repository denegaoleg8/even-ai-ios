import SwiftUI

struct MessageBubbleView: View {
    let message: Message

    private var isUser: Bool { message.role == .user }

    private var failureText: String {
        if isUser {
            return "Couldn't send"
        }
        return message.content.isEmpty ? "No response received" : "Response incomplete"
    }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: AppMetrics.Spacing.xl) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: AppMetrics.Spacing.xs) {
                VStack(alignment: .leading, spacing: AppMetrics.Spacing.xs) {
                    if !message.content.isEmpty {
                        Text(message.content)
                            .font(AppTypography.messageBody)
                            .foregroundStyle(isUser ? Color.white : AppColor.textPrimary)
                    }

                    if message.status == .failed {
                        Label(failureText, systemImage: "exclamationmark.triangle")
                            .font(AppTypography.timestamp)
                            .foregroundStyle(isUser ? Color.white : AppColor.destructive)
                    }
                }
                .padding(.horizontal, AppMetrics.Spacing.md)
                .padding(.vertical, AppMetrics.Spacing.sm)
                .background(isUser ? AppColor.bubbleUser : AppColor.bubbleAssistant)
                .clipShape(RoundedRectangle(cornerRadius: AppMetrics.Radius.bubble, style: .continuous))

                Text(message.createdAt, style: .time)
                    .font(AppTypography.timestamp)
                    .foregroundStyle(AppColor.textSecondary)
                    .padding(.horizontal, AppMetrics.Spacing.xs)
            }

            if !isUser { Spacer(minLength: AppMetrics.Spacing.xl) }
        }
    }
}

#Preview {
    ScrollView {
        VStack(spacing: AppMetrics.Spacing.sm) {
            MessageBubbleView(message: Message(chatID: UUID(), role: .user, content: "What's the weather in Tokyo?"))
            MessageBubbleView(message: Message(chatID: UUID(), role: .assistant, content: "Mild and rainy — pack a light jacket."))
            MessageBubbleView(message: Message(chatID: UUID(), role: .user, content: "Thanks!", status: .failed))
            MessageBubbleView(message: Message(chatID: UUID(), role: .assistant, content: "", status: .failed))
            MessageBubbleView(message: Message(chatID: UUID(), role: .assistant, content: "Mild and", status: .failed))
        }
        .padding()
    }
}
