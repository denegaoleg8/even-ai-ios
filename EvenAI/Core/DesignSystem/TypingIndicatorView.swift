import SwiftUI

/// Animated "assistant is typing" indicator, shown while waiting for the
/// first token of a streaming reply.
struct TypingIndicatorView: View {
    @State private var animate = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(AppColor.textSecondary)
                    .frame(width: 6, height: 6)
                    .scaleEffect(animate ? 1 : 0.5)
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.15),
                        value: animate
                    )
            }
        }
        .padding(.horizontal, AppMetrics.Spacing.md)
        .padding(.vertical, AppMetrics.Spacing.sm)
        .background(AppColor.bubbleAssistant)
        .clipShape(RoundedRectangle(cornerRadius: AppMetrics.Radius.bubble, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { animate = true }
    }
}

#Preview {
    TypingIndicatorView()
        .padding()
}
