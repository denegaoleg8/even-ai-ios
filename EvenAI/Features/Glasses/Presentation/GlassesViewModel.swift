import Foundation
import Observation

@MainActor
@Observable
final class GlassesViewModel {
    private(set) var connectionState: GlassesTransportState = .disconnected
    private(set) var isSendingTestText = false
    private(set) var sendError: String?
    /// TEMPORARY — Display-First milestone. Proves "APP → G2 → visible
    /// text" using the existing `GlassesTransport.displayPages(_:)` and
    /// pagination path, with no STT/translation/AI in the loop at all.
    /// Remove once the production G2 display path is physically
    /// confirmed working end-to-end.
    private(set) var isRunningDisplayTest = false
    private(set) var displayTestError: String?

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
        // Clear any stale error from a previous session — a fresh connect
        // attempt shouldn't leave an old "Send Test Text" failure visible.
        sendError = nil
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
        // Set directly rather than only waiting on the transport's own
        // broadcast — guarantees a manual disconnect always leaves this
        // view model in `.disconnected`, deterministically, regardless of
        // how quickly (or whether) the transport's own state stream catches
        // up (see `MentraGlassesTransport.disconnect()`).
        connectionState = .disconnected
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

    /// TEMPORARY — Display-First milestone hard-coded 4-page test. Exact
    /// pages required by the physical-device acceptance test: an English
    /// translation-style line, its Ukrainian counterpart, an English
    /// suggested reply, and its Ukrainian meaning — proving the primitive
    /// the production turn-display path (Milestone 6's
    /// `GlassesPresentationLayer`) will eventually reuse, without any
    /// STT/translation/AI involved. Internal (not private) so
    /// `GlassesViewModelTests` can assert on the exact page list without
    /// duplicating it.
    static let displayTestPages = [
        "HELLO FROM EVENAI",
        "Привіт від EvenAI",
        "Sure, that works.",
        "Так, це підходить.",
    ]

    func runHardCodedDisplayTest() async {
        guard !isRunningDisplayTest else { return }
        isRunningDisplayTest = true
        defer { isRunningDisplayTest = false }
        displayTestError = nil
        do {
            try await transport.displayPages(Self.displayTestPages)
        } catch {
            displayTestError = error.localizedDescription
        }
    }
}
