import Testing
import Foundation
@testable import EvenAI

@MainActor
@Suite("SettingsViewModel")
struct SettingsViewModelTests {
    private struct FakeDeviceIdentityStore: DeviceIdentityStoring {
        let id: UUID
        func currentDeviceID() -> UUID { id }
    }

    @Test("deviceID reflects the injected device identity store, not a fabricated value")
    func deviceIDReflectsStore() {
        let expectedID = UUID()
        let viewModel = SettingsViewModel(deviceIdentityStore: FakeDeviceIdentityStore(id: expectedID))

        #expect(viewModel.deviceID == expectedID.uuidString)
    }

    @Test("subscriptionTier is the one real tier that exists today")
    func subscriptionTierIsFree() {
        let viewModel = SettingsViewModel()
        #expect(viewModel.subscriptionTier == "Free")
    }

    @Test("appearance defaults to system")
    func appearanceDefaultsToSystem() {
        let viewModel = SettingsViewModel()
        #expect(viewModel.appearance == .system)
    }
}
