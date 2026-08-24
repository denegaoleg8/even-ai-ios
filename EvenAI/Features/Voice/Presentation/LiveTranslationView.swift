import SwiftUI

/// Thin control surface over the app-level `LiveTranslationService` — this
/// view owns no state of its own and does not stop the service on
/// disappear/navigation; the whole point of the app-level service is that
/// Live Translation keeps running when the user leaves this screen. See
/// `LiveTranslationService`'s doc comment for where it actually starts,
/// stops, and hosts the `Translation` framework session.
struct LiveTranslationView: View {
    @Environment(LiveTranslationService.self) private var liveTranslation
    @Environment(AppState.self) private var appState

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

            sourceLanguagePicker

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
                        // This screen is only reachable by pushing through
                        // Settings' own `.sheet`. `LiveTranslationService`'s
                        // one app-level `TranslationSession` is hosted on
                        // `RootView` (see its doc comment); the FIRST time
                        // the on-device Translation framework needs to show
                        // its own system UI (e.g. a language-resource
                        // download prompt) for a given phrase, it has to
                        // present on top of RootView — which it cannot do
                        // while Settings' sheet is still covering it
                        // ("Currently, only presenting a single sheet is
                        // supported"), so that translation call hangs
                        // forever waiting for an interaction the user can
                        // never make. Dismissing Settings here costs
                        // nothing — Live Translation is explicitly designed
                        // to keep running once you leave this screen.
                        appState.isSettingsPresented = false
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

    /// Source-language selector — "Auto | EN | DE | PL", per the product
    /// requirement: quick to use, no modal sheet (a plain inline row of
    /// toggle buttons, always visible on this screen — nothing here
    /// presents anything, so there's no risk of the sheet-presentation
    /// conflict `LiveTranslationView`'s own Settings-dismiss fix already
    /// deals with elsewhere), clearly visible selected state, works while
    /// a session is already listening (switching mid-session is exactly
    /// when glasses-use makes a modal picker impractical).
    private var sourceLanguagePicker: some View {
        HStack(spacing: AppMetrics.Spacing.sm) {
            ForEach(SourceLanguageMode.allCases, id: \.self) { mode in
                let isSelected = liveTranslation.sourceLanguageMode == mode
                Button {
                    liveTranslation.setSourceLanguageMode(mode)
                } label: {
                    Text(mode.displayLabel)
                        .font(AppTypography.chatPreview.weight(isSelected ? .semibold : .regular))
                        .padding(.horizontal, AppMetrics.Spacing.sm)
                        .padding(.vertical, AppMetrics.Spacing.xs)
                        .frame(minWidth: 44)
                        .background(isSelected ? AppColor.accent : AppColor.secondaryBackground)
                        .foregroundStyle(isSelected ? Color.white : AppColor.textPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: AppMetrics.Radius.medium))
                }
                .accessibilityIdentifier("liveTranslation.sourceLanguage.\(mode.rawValue)")
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
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
            .environment(AppState())
    }
}
