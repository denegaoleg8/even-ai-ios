import Testing
import Foundation
@testable import EvenAI

/// Phase 2 connection-lifecycle hardening: manual connect/disconnect/
/// reconnect must be reliable, and every failure mode must reach a clean,
/// terminal state — never a stuck "connecting" appearance.
@MainActor
@Suite("GlassesViewModel connection lifecycle")
struct GlassesViewModelTests {
    /// Short enough to keep the suite fast, long enough for the actor-hop
    /// through `connectionStateUpdates()`'s `AsyncStream` to land — same
    /// pattern `AuthStateSessionSyncTests` uses for its own background
    /// subscription task.
    private static let propagationDelay: Duration = .milliseconds(20)

    @Test("a) a successful connect transitions the view model to .connected")
    func successfulConnect() async {
        let viewModel = GlassesViewModel(transport: MockGlassesTransport())
        let observation = Task { await viewModel.observeConnectionState() }
        try? await Task.sleep(for: Self.propagationDelay)

        await viewModel.connect()
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(viewModel.connectionState == .connected)
        observation.cancel()
    }

    @Test("b) disconnect after connected returns to .disconnected immediately, with no stale connected state")
    func disconnectAfterConnected() async {
        let viewModel = GlassesViewModel(transport: MockGlassesTransport())
        let observation = Task { await viewModel.observeConnectionState() }
        try? await Task.sleep(for: Self.propagationDelay)

        await viewModel.connect()
        try? await Task.sleep(for: Self.propagationDelay)
        #expect(viewModel.connectionState == .connected)

        await viewModel.disconnect()
        // Asserted with no sleep: `disconnect()` sets `connectionState`
        // directly, so this must already be true the instant it returns.
        #expect(viewModel.connectionState == .disconnected)
        observation.cancel()
    }

    @Test("c) a subsequent manual connect works correctly after a disconnect")
    func reconnectAfterDisconnect() async {
        let viewModel = GlassesViewModel(transport: MockGlassesTransport())
        let observation = Task { await viewModel.observeConnectionState() }
        try? await Task.sleep(for: Self.propagationDelay)

        await viewModel.connect()
        try? await Task.sleep(for: Self.propagationDelay)
        await viewModel.disconnect()
        #expect(viewModel.connectionState == .disconnected)

        await viewModel.connect()
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(viewModel.connectionState == .connected)
        observation.cancel()
    }

    @Test("d) a pairNeedDisconnect-style failure reaches a clean, terminal .failed state, never stuck connecting")
    func pairFailureSurfacesCleanly() async {
        let viewModel = GlassesViewModel(transport: PairFailureGlassesTransport())
        let observation = Task { await viewModel.observeConnectionState() }
        try? await Task.sleep(for: Self.propagationDelay)

        await viewModel.connect()
        try? await Task.sleep(for: Self.propagationDelay)

        guard case .failed(let message) = viewModel.connectionState else {
            Issue.record("Expected a terminal .failed state, got \(viewModel.connectionState)")
            observation.cancel()
            return
        }
        #expect(message == PairFailureGlassesTransport.message)
        #expect(!message.contains("errors:")) // never the SDK's raw internal slug
        observation.cancel()
    }

    @Test("e) sendText while disconnected is harmless: a friendly error, no crash, connection state untouched")
    func sendTextWhileDisconnectedIsHarmless() async {
        let viewModel = GlassesViewModel(transport: MockGlassesTransport())
        // Never connected.
        await viewModel.sendTestText()

        #expect(viewModel.sendError != nil)
        #expect(!viewModel.isSendingTestText)
        #expect(viewModel.connectionState == .disconnected)
    }

    // MARK: - Display-First milestone: temporary hard-coded display test

    @Test("f) the hard-coded display test page list is exactly the required 4 pages, in order")
    func displayTestPagesAreExact() {
        #expect(GlassesViewModel.displayTestPages == [
            "HELLO FROM EVENAI",
            "Привіт від EvenAI",
            "Sure, that works.",
            "Так, це підходить.",
        ])
    }

    @Test("g) running the display test while connected sends the exact 4-page set through displayPages(_:)")
    func displayTestSendsExactPagesWhenConnected() async {
        let spy = SpyGlassesTransport()
        let viewModel = GlassesViewModel(transport: spy)
        let observation = Task { await viewModel.observeConnectionState() }
        try? await Task.sleep(for: Self.propagationDelay)
        await viewModel.connect()
        try? await Task.sleep(for: Self.propagationDelay)

        await viewModel.runHardCodedDisplayTest()

        #expect(await spy.displayedPageSets == [GlassesViewModel.displayTestPages])
        #expect(viewModel.displayTestError == nil)
        #expect(!viewModel.isRunningDisplayTest)
        observation.cancel()
    }

    @Test("h) running the display test while disconnected surfaces a friendly error, no crash")
    func displayTestWhileDisconnectedIsHarmless() async {
        let viewModel = GlassesViewModel(transport: MockGlassesTransport())
        // Never connected.
        await viewModel.runHardCodedDisplayTest()

        #expect(viewModel.displayTestError != nil)
        #expect(!viewModel.isRunningDisplayTest)
        #expect(viewModel.connectionState == .disconnected)
    }
}
