import Testing
@testable import EvenAI

/// Direct coverage of `MentraGlassesTransport.failureMessage(forCode:rawMessage:)`
/// — the Phase 2 fix for the `pairNeedDisconnect` failure mode — without
/// needing a real `MentraBluetoothSDK`/`CBCentralManager` instance.
@Suite("MentraGlassesTransport failure-message mapping")
struct MentraGlassesTransportTests {
    @Test("pair_failure is mapped to a clear, actionable message, not the SDK's raw internal slug")
    func pairFailureGetsCleanMessage() {
        let message = MentraGlassesTransport.failureMessage(
            forCode: "pair_failure",
            rawMessage: "errors:pairNeedDisconnect"
        )

        #expect(message != "errors:pairNeedDisconnect")
        #expect(message.contains("Bluetooth"))
    }

    @Test("any other failure code passes its message through unchanged")
    func otherFailuresPassThrough() {
        let message = MentraGlassesTransport.failureMessage(
            forCode: "bluetooth_powered_off",
            rawMessage: "Turn on phone Bluetooth to scan for glasses."
        )

        #expect(message == "Turn on phone Bluetooth to scan for glasses.")
    }
}
