import Testing
import Foundation
@testable import EvenAI

/// `TranscriptionProviderRouter` is the local-first architecture pass's
/// central provider-selection type — these tests lock in its exact
/// contract (see the type's own doc comment): `.onDevice` never touches
/// cloud even on failure, `.cloud` always uses cloud, `.auto` prefers
/// local and falls back to cloud only if local can't start.
@MainActor
@Suite("TranscriptionProviderRouter")
struct TranscriptionProviderRouterTests {
    private func emptyPCMStream() -> AsyncStream<Data> {
        AsyncStream { $0.finish() }
    }

    @Test("On-device mode: uses local, never touches cloud")
    func onDeviceUsesLocalOnly() async throws {
        let local = FakeOnDeviceTranscriber(finals: ["hello"])
        let cloud = NeverCalledTranscriber()
        let router = TranscriptionProviderRouter(
            local: local,
            cloud: cloud,
            mode: { .onDevice },
            resolveLocale: { Locale(identifier: "en-US") }
        )

        _ = try await router.startTranscribing(pcmUpdates: emptyPCMStream())

        #expect(await local.startCallCount == 1)
        #expect(router.lastActiveProvider == .onDevice)
    }

    @Test("On-device mode: local failing to start THROWS — never silently falls back to cloud")
    func onDeviceNeverSilentlyFallsBackOnFailure() async throws {
        struct LocalUnavailable: Error {}
        let local = FakeOnDeviceTranscriber(startError: LocalUnavailable())
        let cloud = NeverCalledTranscriber()
        let router = TranscriptionProviderRouter(
            local: local,
            cloud: cloud,
            mode: { .onDevice },
            resolveLocale: { Locale(identifier: "en-US") }
        )

        await #expect(throws: LocalUnavailable.self) {
            _ = try await router.startTranscribing(pcmUpdates: emptyPCMStream())
        }
        // lastActiveProvider is still recorded as onDevice — the ATTEMPT
        // was on-device, even though it failed; cloud was never touched.
        #expect(router.lastActiveProvider == .onDevice)
    }

    @Test("Cloud mode: always uses cloud, never local")
    func cloudModeUsesCloudOnly() async throws {
        let local = FakeOnDeviceTranscriber(finals: ["should not be used"])
        let cloud = ScriptedContinuousTranscriber(finals: ["from cloud"])
        let router = TranscriptionProviderRouter(
            local: local,
            cloud: cloud,
            mode: { .cloud },
            resolveLocale: { Locale(identifier: "en-US") }
        )

        _ = try await router.startTranscribing(pcmUpdates: emptyPCMStream())

        #expect(await local.startCallCount == 0)
        #expect(router.lastActiveProvider == .cloud)
    }

    @Test("Auto mode: prefers local when it starts successfully — never touches cloud")
    func autoPrefersLocalWhenAvailable() async throws {
        let local = FakeOnDeviceTranscriber(finals: ["hello"])
        let cloud = NeverCalledTranscriber()
        let router = TranscriptionProviderRouter(
            local: local,
            cloud: cloud,
            mode: { .auto },
            resolveLocale: { Locale(identifier: "en-US") }
        )

        _ = try await router.startTranscribing(pcmUpdates: emptyPCMStream())

        #expect(await local.startCallCount == 1)
        #expect(router.lastActiveProvider == .onDevice)
    }

    @Test("Auto mode: falls back to cloud only when local fails to start, and cloud fallback is allowed")
    func autoFallsBackToCloudWhenLocalFails() async throws {
        struct LocalUnavailable: Error {}
        let local = FakeOnDeviceTranscriber(startError: LocalUnavailable())
        let cloud = ScriptedContinuousTranscriber(finals: ["from cloud"])
        let router = TranscriptionProviderRouter(
            local: local,
            cloud: cloud,
            mode: { .auto },
            resolveLocale: { Locale(identifier: "en-US") },
            cloudFallbackAllowed: { true }
        )

        _ = try await router.startTranscribing(pcmUpdates: emptyPCMStream())

        #expect(router.lastActiveProvider == .cloud)
    }

    @Test("Auto mode: local fails AND cloud fallback is disallowed (e.g. airplane mode) — surfaces the real local error, never hangs on a doomed network attempt")
    func autoSurfacesLocalErrorWhenCloudFallbackDisallowed() async throws {
        struct LocalUnavailable: Error {}
        let local = FakeOnDeviceTranscriber(startError: LocalUnavailable())
        let cloud = NeverCalledTranscriber()
        let router = TranscriptionProviderRouter(
            local: local,
            cloud: cloud,
            mode: { .auto },
            resolveLocale: { Locale(identifier: "en-US") },
            cloudFallbackAllowed: { false }
        )

        await #expect(throws: LocalUnavailable.self) {
            _ = try await router.startTranscribing(pcmUpdates: emptyPCMStream())
        }
    }

    @Test("resolveLocale() is applied to the local transcriber before every startTranscribing call")
    func localeIsAppliedBeforeStarting() async throws {
        let local = FakeOnDeviceTranscriber()
        let router = TranscriptionProviderRouter(
            local: local,
            cloud: NeverCalledTranscriber(),
            mode: { .onDevice },
            resolveLocale: { Locale(identifier: "de-DE") }
        )

        _ = try await router.startTranscribing(pcmUpdates: emptyPCMStream())

        #expect(await local.locale.identifier == "de-DE")
    }

    @Test("applyCurrentLocale() pushes the current resolveLocale() result into the local transcriber without starting a session")
    func applyCurrentLocalePushesLocaleLive() async throws {
        let local = FakeOnDeviceTranscriber(locale: Locale(identifier: "en-US"))
        let router = TranscriptionProviderRouter(
            local: local,
            cloud: NeverCalledTranscriber(),
            mode: { .onDevice },
            resolveLocale: { Locale(identifier: "pl-PL") }
        )

        router.applyCurrentLocale()

        #expect(await local.locale.identifier == "pl-PL")
        #expect(await local.startCallCount == 0) // no session was started
    }

    @Test("stopTranscribing() is safe to call on both providers even when only one was ever active")
    func stopIsSafeRegardlessOfWhichProviderRan() async throws {
        let local = FakeOnDeviceTranscriber(finals: ["hello"])
        let cloud = ScriptedContinuousTranscriber(finals: [])
        let router = TranscriptionProviderRouter(
            local: local,
            cloud: cloud,
            mode: { .onDevice },
            resolveLocale: { Locale(identifier: "en-US") }
        )

        _ = try await router.startTranscribing(pcmUpdates: emptyPCMStream())
        await router.stopTranscribing()

        #expect(await local.stopCallCount == 1)
        #expect(await cloud.stopCallCount == 1) // harmless no-op, never started
    }
}
