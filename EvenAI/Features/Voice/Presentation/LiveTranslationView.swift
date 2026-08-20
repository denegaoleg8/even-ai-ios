import SwiftUI

/// Thin control surface over the app-level `LiveTranslationService` — this
/// view owns no state of its own and does not stop the service on
/// disappear/navigation; the whole point of the app-level service is that
/// Live Translation keeps running when the user leaves this screen. See
/// `LiveTranslationService`'s doc comment for where it actually starts,
/// stops, and hosts the `Translation` framework session.
struct LiveTranslationView: View {
    @Environment(LiveTranslationService.self) private var liveTranslation

    var body: some View {
        VStack(spacing: AppMetrics.Spacing.lg) {
            Spacer()

            Image(systemName: "globe")
                .font(.system(size: 44))
                .foregroundStyle(AppColor.textSecondary)

            Text(statusText)
                .font(AppTypography.chatPreview)
                .foregroundStyle(AppColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppMetrics.Spacing.lg)

            if let lastTranslation = liveTranslation.lastTranslation {
                Text(lastTranslation)
                    .font(AppTypography.chatTitle)
                    .padding(AppMetrics.Spacing.sm)
                    .background(AppColor.secondaryBackground)
                    .clipShape(RoundedRectangle(cornerRadius: AppMetrics.Radius.medium))
                    .padding(.horizontal, AppMetrics.Spacing.lg)
            }

            if case let .error(message) = liveTranslation.state {
                InlineErrorText(message: message)
                    .padding(.horizontal, AppMetrics.Spacing.lg)
            }

            PrimaryButton(
                buttonTitle,
                systemImage: liveTranslation.state == .listening ? "stop.circle" : "play.circle"
            ) {
                Task {
                    if liveTranslation.state == .listening {
                        await liveTranslation.stop()
                    } else {
                        await liveTranslation.start()
                    }
                }
            }
            .frame(maxWidth: 260)

            if liveTranslation.state == .listening {
                Text("Live Translation keeps running if you leave this screen.")
                    .font(.footnote)
                    .foregroundStyle(AppColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, AppMetrics.Spacing.lg)
            }

            Spacer()
        }
        .padding(AppMetrics.Spacing.lg)
        .navigationTitle("Live Translation")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var statusText: String {
        switch liveTranslation.state {
        case .idle: "Start Live Translation to see foreign phrases translated on your glasses"
        case .listening: "Listening..."
        case .error: "Something went wrong"
        }
    }

    private var buttonTitle: String {
        liveTranslation.state == .listening ? "Stop" : "Start Live Translation"
    }
}

#Preview {
    NavigationStack {
        LiveTranslationView()
            .environment(
                LiveTranslationService(
                    glassesTransport: MockGlassesTransport(),
                    transcriber: GlassesSpeechTranscriber(),
                    translator: AppleLanguageTranslator()
                )
            )
    }
}
