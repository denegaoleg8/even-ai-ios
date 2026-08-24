import SwiftUI

/// First real version of the Glasses screen (Milestone 4 phase 2) — connect/
/// disconnect and a "Send Test Text" smoke test, entirely through
/// `GlassesTransport`. No Chat integration yet: this screen never reads or
/// sends chat messages, only the fixed test string below.
struct GlassesView: View {
    @State private var viewModel: GlassesViewModel

    init(transport: GlassesTransport) {
        _viewModel = State(initialValue: GlassesViewModel(transport: transport))
    }

    var body: some View {
        VStack(spacing: AppMetrics.Spacing.lg) {
            Spacer()

            Image(systemName: "eyeglasses")
                .font(.system(size: 44))
                .foregroundStyle(AppColor.textSecondary)

            VStack(spacing: AppMetrics.Spacing.xs) {
                Text("Even G2 Glasses")
                    .font(AppTypography.chatTitle)
                    .foregroundStyle(AppColor.textPrimary)
                Text(statusText)
                    .font(AppTypography.chatPreview)
                    .foregroundStyle(AppColor.textSecondary)
            }

            if case let .failed(message) = viewModel.connectionState {
                InlineErrorText(message: message)
                    .padding(.horizontal, AppMetrics.Spacing.lg)
            }

            VStack(spacing: AppMetrics.Spacing.sm) {
                PrimaryButton(connectButtonTitle, isLoading: isConnecting) {
                    Task { await handlePrimaryButtonTap() }
                }

                if viewModel.connectionState == .connected {
                    PrimaryButton(
                        "Send Test Text",
                        systemImage: "text.bubble",
                        isLoading: viewModel.isSendingTestText
                    ) {
                        Task { await viewModel.sendTestText() }
                    }

                    if let sendError = viewModel.sendError {
                        InlineErrorText(message: sendError)
                    }

                    // TEMPORARY — Display-First milestone physical-device
                    // primitive test (4 hard-coded pages, no STT/AI in
                    // the loop). Remove once the production G2 display
                    // path is physically confirmed.
                    PrimaryButton(
                        "Run Display Test (4 pages)",
                        systemImage: "rectangle.stack",
                        isLoading: viewModel.isRunningDisplayTest
                    ) {
                        Task { await viewModel.runHardCodedDisplayTest() }
                    }

                    if let displayTestError = viewModel.displayTestError {
                        InlineErrorText(message: displayTestError)
                    }
                }
            }
            .frame(maxWidth: 260)

            Spacer()
        }
        .padding(AppMetrics.Spacing.lg)
        .navigationTitle("Glasses")
        .navigationBarTitleDisplayMode(.inline)
        // Subscribing here does not, by itself, request Bluetooth
        // permission — MentraGlassesTransport reports `.disconnected`
        // without touching the underlying SDK until connect() is called
        // (see MentraGlassesTransport.isSDKStarted). Permission is only
        // ever requested once the user presses Connect below.
        .task {
            await viewModel.observeConnectionState()
        }
    }

    private var isConnecting: Bool {
        viewModel.connectionState == .scanning || viewModel.connectionState == .connecting
    }

    private var connectButtonTitle: String {
        viewModel.connectionState == .connected ? "Disconnect" : "Connect"
    }

    private var statusText: String {
        switch viewModel.connectionState {
        case .disconnected: "Disconnected"
        case .scanning, .connecting: "Connecting..."
        case .connected: "Connected"
        case .failed: "Error"
        }
    }

    private func handlePrimaryButtonTap() async {
        if viewModel.connectionState == .connected {
            await viewModel.disconnect()
        } else {
            await viewModel.connect()
        }
    }
}

#Preview {
    NavigationStack {
        GlassesView(transport: MockGlassesTransport())
    }
}
