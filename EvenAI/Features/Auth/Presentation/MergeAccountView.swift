import SwiftUI

/// Shown right after a sign-in that returns `mergeAvailableFrom` (this
/// device already had its own anonymous account with local chats), and
/// reachable again later from Settings if the user skips it here — see
/// `AuthState.mergeAvailableFrom`.
struct MergeAccountView: View {
    let fromAccountID: User.ID
    /// Called whether the user merges or skips — both are a complete,
    /// intentional resolution of this screen, not just one of them.
    var onFinished: () -> Void

    @Environment(AuthState.self) private var authState
    @Environment(AppState.self) private var appState
    @State private var viewModel: MergeAccountViewModel

    init(fromAccountID: User.ID, onFinished: @escaping () -> Void) {
        self.fromAccountID = fromAccountID
        self.onFinished = onFinished
        _viewModel = State(initialValue: MergeAccountViewModel(fromAccountID: fromAccountID))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: AppMetrics.Spacing.xl) {
                Spacer()

                VStack(spacing: AppMetrics.Spacing.md) {
                    Image(systemName: "arrow.triangle.merge")
                        .font(.system(size: 48))
                        .foregroundStyle(AppColor.accent)
                        .accessibilityHidden(true)

                    VStack(spacing: AppMetrics.Spacing.xs) {
                        Text("Merge Your Conversations?")
                            .font(AppTypography.screenTitle)
                        Text("We found conversations on this device from before you signed in. They can be merged into your account — nothing is lost either way.")
                            .font(AppTypography.chatPreview)
                            .foregroundStyle(AppColor.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, AppMetrics.Spacing.lg)
                    }
                }

                if let errorMessage = viewModel.errorMessage {
                    InlineErrorText(message: errorMessage)
                        .padding(.horizontal, AppMetrics.Spacing.lg)
                        .accessibilityIdentifier("merge.errorText")
                }

                Spacer()

                VStack(spacing: AppMetrics.Spacing.sm) {
                    PrimaryButton("Merge", isLoading: viewModel.isMerging) {
                        Task { await merge() }
                    }
                    .accessibilityIdentifier("merge.mergeButton")

                    Button("Skip for Now") {
                        onFinished()
                    }
                    .disabled(viewModel.isMerging)
                    .accessibilityIdentifier("merge.skipButton")
                }
                .padding(.horizontal, AppMetrics.Spacing.lg)
                .padding(.bottom, AppMetrics.Spacing.lg)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppColor.background)
            // Merging is quick and idempotent-safe to retry, but a swipe-
            // to-dismiss mid-request would leave the user unsure whether
            // it actually happened — block it only while in flight.
            .interactiveDismissDisabled(viewModel.isMerging)
            .animation(.easeOut(duration: 0.2), value: viewModel.errorMessage)
        }
    }

    private func merge() async {
        await viewModel.merge(using: authState, appState: appState)
        if viewModel.didMergeSuccessfully {
            onFinished()
        }
    }
}

#Preview {
    MergeAccountView(fromAccountID: UUID(), onFinished: {})
        .environment(AuthState())
        .environment(AppState())
}
