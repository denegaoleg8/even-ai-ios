import SwiftUI

/// Text field + send button used at the bottom of the chat screen. Purely
/// presentational — the caller owns `text` and decides what "send" means.
struct MessageInputBar: View {
    @Binding var text: String
    var isSending: Bool = false
    var onSend: () -> Void

    private var isSendDisabled: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: AppMetrics.Spacing.sm) {
            TextField("Message", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(.horizontal, AppMetrics.Spacing.md)
                .padding(.vertical, AppMetrics.Spacing.sm)
                .background(AppColor.secondaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: AppMetrics.Radius.medium, style: .continuous))

            Button(action: onSend) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
            }
            .disabled(isSendDisabled)
        }
        .padding(AppMetrics.Spacing.sm)
    }
}

#Preview {
    MessageInputBar(text: .constant("Hello there"), onSend: {})
}
