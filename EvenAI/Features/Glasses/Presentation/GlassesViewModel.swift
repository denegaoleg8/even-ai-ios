import Foundation
import Observation

@MainActor
@Observable
final class GlassesViewModel {
    private(set) var connectionState: GlassesTransportState = .disconnected
    private(set) var isSendingTestText = false
    private(set) var sendError: String?

    private let transport: GlassesTransport

    /// No default — `transport` always comes from whoever constructs this
    /// (`GlassesView`, itself given it via `@Environment(\.glassesTransport)`,
    /// or a test's own fake directly). Never resolved from `AppContainer.live`
    /// here: `Features` may only reach `Infrastructure` through injection
    /// (see `ARCHITECTURE.md`'s Dependency Rule).
    init(transport: GlassesTransport) {
        self.transport = transport
    }

    /// Long-running: iterates the transport's state stream for as long as
    /// the caller keeps awaiting it. Meant to be driven by the view's
    /// `.task`, which cancels this automatically on disappear.
    func observeConnectionState() async {
        for await state in await transport.connectionStateUpdates() {
            connectionState = state
        }
    }

    func connect() async {
        do {
            try await transport.connect()
        } catch {
            // A scan/connect attempt that fails to even start (e.g.
            // Bluetooth powered off) throws here directly rather than
            // arriving through connectionStateUpdates() — surface it the
            // same way either path would.
            connectionState = .failed(error.localizedDescription)
        }
    }

    func disconnect() async {
        await transport.disconnect()
    }

    func sendTestText() async {
        guard !isSendingTestText else { return }
        isSendingTestText = true
        defer { isSendingTestText = false }
        sendError = nil
        do {
            try await transport.sendText("Hello from EvenAI")
        } catch {
            sendError = error.localizedDescription
        }
    }
}
