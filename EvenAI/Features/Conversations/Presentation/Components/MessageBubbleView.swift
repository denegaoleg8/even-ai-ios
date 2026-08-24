import SwiftUI

/// Glasses Chat persists each finalized live-translation turn as one
/// plain-text message: `"<source>\n→ <Ukrainian translation>"` (see
/// `LiveTranslationService.processTurn(...)`'s Glasses Chat append). A
/// flat `Text(message.content)` rendered that as one undifferentiated
/// paragraph — genuinely hard to scan back through as history (Section F,
/// "focused usability/performance cleanup"). This parser recovers the two
/// parts so `MessageBubbleView` can render them as clearly separated
/// rows, without requiring a schema change to `Message`/the backend: any
/// message that happens to match the exact separator renders this way;
/// anything else (normal Chat messages, which never contain "\n→ ")
/// falls back to the plain flat rendering unchanged.
enum GlassesChatMessageContent {
    static let separator = "\n→ "

    struct Parsed {
        let source: String
        let translation: String
    }

    static func parse(_ content: String) -> Parsed? {
        // Reject anything with more than one separator — a message that
        // doesn't match this exact one-turn shape (e.g. a normal Chat
        // message that happens to contain "→" in prose) should fall back
        // to plain rendering rather than being mis-split.
        let components = content.components(separatedBy: separator)
        guard components.count == 2 else { return nil }
        let source = components[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let translation = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !translation.isEmpty else { return nil }
        return Parsed(source: source, translation: translation)
    }
}

struct MessageBubbleView: View {
    let message: Message

    private var isUser: Bool { message.role == .user }

    private var glassesChatTurn: GlassesChatMessageContent.Parsed? {
        GlassesChatMessageContent.parse(message.content)
    }

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
                    if let turn = glassesChatTurn {
                        glassesChatTurnContent(turn)
                    } else if !message.content.isEmpty {
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

    /// Clear visual grouping for one Glasses Chat turn — source phrase,
    /// then a labeled Ukrainian translation row, instead of one flat
    /// paragraph (Section F).
    private func glassesChatTurnContent(_ turn: GlassesChatMessageContent.Parsed) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(turn.source)
                .font(AppTypography.messageBody)
                .foregroundStyle(isUser ? Color.white : AppColor.textPrimary)
            Text("UA: \(turn.translation)")
                .font(AppTypography.messageBody)
                .foregroundStyle(isUser ? Color.white.opacity(0.85) : AppColor.textSecondary)
        }
    }
}

#Preview {
    ScrollView {
        VStack(spacing: AppMetrics.Spacing.sm) {
            MessageBubbleView(message: Message(chatID: UUID(), role: .user, content: "What's the weather in Tokyo?"))
            MessageBubbleView(message: Message(chatID: UUID(), role: .user, content: "Guten Tag\n→ Добрий день"))
            MessageBubbleView(message: Message(chatID: UUID(), role: .assistant, content: "Mild and rainy — pack a light jacket."))
            MessageBubbleView(message: Message(chatID: UUID(), role: .user, content: "Thanks!", status: .failed))
            MessageBubbleView(message: Message(chatID: UUID(), role: .assistant, content: "", status: .failed))
            MessageBubbleView(message: Message(chatID: UUID(), role: .assistant, content: "Mild and", status: .failed))
        }
        .padding()
    }
}
