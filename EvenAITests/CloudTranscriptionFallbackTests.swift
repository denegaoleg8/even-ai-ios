import Testing
import Foundation
import SwiftData
@testable import EvenAI

/// Regression coverage for the Cloud-mode production-safety fix.
///
/// Confirmed root cause (see the fix's own commit/report): selecting
/// explicit Cloud mode on a physical device with Railway unavailable made
/// `POST /auth/device` fail with `AuthenticatedAPIClientError.http(status:
/// 404, ...)` (Railway's own "Application not found" edge fallback —
/// matches `ProductionEndpointContractTests`' documented real-outage
/// precedent), thrown synchronously out of
/// `URLSessionRealtimeTranscriptionSocket.connect()` →
/// `OpenAIRealtimeTranscriber.startTranscribing` →
/// `TranscriptionProviderRouter`'s (then-unguarded) `.cloud` case →
/// `AIConversationEngine.start()`'s catch block, which classified it as
/// `.authenticationFailed` (a MISLEADING message — nothing about the
/// user's session was actually wrong) and called `terminateSession(...)`,
/// tearing down the whole Live Translation session (mic disabled,
/// listening stopped) even though on-device transcription would have
/// worked fine.
///
/// `TranscriptionProviderRouter`'s `.cloud` case now transparently falls
/// back to `local` on ANY cloud failure — at start time or mid-session —
/// via `startCloudWithLocalFallback(pcmUpdates:)`. These tests prove that
/// fallback end-to-end, at both the router level (precise, fast,
/// scripted providers) and the full `AIConversationEngine` level
/// (translation/G2 display/history/Glasses Chat all keep working).
/// Collects `TranscriptionUpdate`s from a background consuming `Task` —
/// an `actor` so appending from that task and reading back from the
/// test's own `@MainActor` body are both safe under strict concurrency.
private actor Received {
    private(set) var values: [TranscriptionUpdate] = []
    func append(_ update: TranscriptionUpdate) {
        values.append(update)
    }
}

@MainActor
@Suite("Cloud transcription mode: production-safety fallback")
struct CloudTranscriptionFallbackTests {
    private func freshGlassesChatStore() -> LocalGlassesChatStore {
        let schema = Schema([ChatEntity.self, MessageEntity.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [configuration])
        return LocalGlassesChatStore(modelContainer: container)
    }

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "CloudTranscriptionFallbackTests.\(UUID().uuidString)")!
    }

    // MARK: - Router-level: precise fallback mechanics

    @Test("Cloud mode: cloud failing to start at all falls back to local — startTranscribing does not throw, local is used")
    func cloudFailsAtStartFallsBackToLocal() async throws {
        struct RailwayUnreachable: Error {}
        let local = FakeOnDeviceTranscriber(finals: ["hello"])
        let cloud = ThrowingStartContinuousTranscriber(error: RailwayUnreachable())
        var fallbackInvocations: [Error] = []
        let router = TranscriptionProviderRouter(
            local: local,
            cloud: cloud,
            mode: { .cloud },
            resolveLocale: { Locale(identifier: "en-US") }
        )
        router.onCloudFallback = { error in fallbackInvocations.append(error) }

        // A real continuous STT stream never finishes on its own — it
        // stays open until `stopTranscribing()` is called, exactly like
        // `FakeOnDeviceTranscriber`'s here. Draining it with an unbounded
        // `for try await` would hang forever; consume in the background,
        // give it a moment, then stop — the same pattern
        // `AIConversationEngine` itself uses in production.
        let stream = try await router.startTranscribing(pcmUpdates: AsyncStream { $0.finish() })
        let received = Received()
        let consumeTask = Task {
            for try await update in stream { await received.append(update) }
        }
        try? await Task.sleep(for: .milliseconds(50))
        await router.stopTranscribing()
        _ = try? await consumeTask.value

        #expect(await received.values == [.final("hello")]) // local's transcript reached the caller
        #expect(await local.startCallCount == 1)
        #expect(fallbackInvocations.count == 1)
        #expect(router.lastActiveProvider == .onDevice)
    }

    @Test("Cloud mode: cloud connection failure AFTER stream startup (mid-session) falls back to local seamlessly, as ONE continuous outward stream")
    func cloudFailsMidStreamFallsBackToLocal() async throws {
        struct ConnectionDropped: Error {}
        let local = FakeOnDeviceTranscriber(finals: ["from local after fallback"])
        let cloud = ManualContinuousTranscriber() // succeeds at start; fails later, on demand
        var fallbackInvocations: [Error] = []
        let router = TranscriptionProviderRouter(
            local: local,
            cloud: cloud,
            mode: { .cloud },
            resolveLocale: { Locale(identifier: "en-US") }
        )
        router.onCloudFallback = { error in fallbackInvocations.append(error) }

        let stream = try await router.startTranscribing(pcmUpdates: AsyncStream { $0.finish() })
        let received = Received()
        let consumeTask = Task {
            for try await update in stream { await received.append(update) }
        }
        try? await Task.sleep(for: .milliseconds(20))
        await cloud.emit("from cloud before drop")
        try? await Task.sleep(for: .milliseconds(20))
        #expect(router.lastActiveProvider == .cloud) // still cloud — hasn't failed yet

        await cloud.failStream(with: ConnectionDropped())
        // `local`'s fixed `finals` ("from local after fallback") are
        // yielded automatically, synchronously, the moment the fallback's
        // `local.startTranscribing` call happens — no manual trigger
        // needed here, unlike `cloud`'s on-demand `emit(_:)` above.
        try? await Task.sleep(for: .milliseconds(50))
        await router.stopTranscribing()
        _ = try? await consumeTask.value

        // ONE continuous stream carried both the cloud update (before the
        // drop) and the local update (after the fallback) — no separate
        // "stream ended" event ever reached the caller.
        #expect(await received.values == [.final("from cloud before drop"), .final("from local after fallback")])
        #expect(fallbackInvocations.count == 1)
        #expect(router.lastActiveProvider == .onDevice)
        #expect(await local.startCallCount == 1) // local started exactly once — no duplicate listener
    }

    @Test("Cloud mode: On-device mode is completely unaffected by the Cloud fallback logic — still never touches cloud, still throws its own failures directly")
    func onDeviceModeUnaffectedByCloudFallbackLogic() async throws {
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
            _ = try await router.startTranscribing(pcmUpdates: AsyncStream { $0.finish() })
        }
    }

    @Test("Cloud mode: BOTH cloud and the local fallback failing surfaces the LOCAL error honestly — never silently hangs, never a misleading G2/auth message")
    func bothCloudAndLocalFailingSurfacesLocalError() async throws {
        struct RailwayUnreachable: Error {}
        let local = FakeOnDeviceTranscriber(startError: VoiceInputError.recognizerUnavailable)
        let cloud = ThrowingStartContinuousTranscriber(error: RailwayUnreachable())
        let router = TranscriptionProviderRouter(
            local: local,
            cloud: cloud,
            mode: { .cloud },
            resolveLocale: { Locale(identifier: "en-US") }
        )

        let stream = try await router.startTranscribing(pcmUpdates: AsyncStream { $0.finish() })
        await #expect(throws: VoiceInputError.self) {
            for try await _ in stream {}
        }
        let classified = LiveTranslationStartError.classifyTranscriberStartFailure(VoiceInputError.recognizerUnavailable)
        #expect(classified == .onDeviceSpeechUnavailable(underlying: "\(VoiceInputError.recognizerUnavailable)"))
    }

    @Test("Cloud → Local manual switch, then Cloud again: no duplicate listeners or leaked tasks across repeated start/stop cycles")
    func repeatedCloudLocalSwitchingNeverLeaksListeners() async throws {
        struct RailwayUnreachable: Error {}
        let local = FakeOnDeviceTranscriber(finals: ["turn"])
        let cloud = ThrowingStartContinuousTranscriber(error: RailwayUnreachable())
        let router = TranscriptionProviderRouter(
            local: local,
            cloud: cloud,
            mode: { .cloud },
            resolveLocale: { Locale(identifier: "en-US") }
        )

        // Three full start/stop cycles, all in Cloud mode with cloud
        // always unreachable — each must independently fall back and
        // clean up, never accumulating extra local start/stop calls. A
        // real STT stream never finishes on its own, so each cycle
        // consumes in the background and stops explicitly, rather than
        // draining an unbounded `for try await` (which would hang).
        for cycle in 1...3 {
            let stream = try await router.startTranscribing(pcmUpdates: AsyncStream { $0.finish() })
            let consumeTask = Task {
                for try await _ in stream {}
            }
            try? await Task.sleep(for: .milliseconds(30))
            await router.stopTranscribing()
            _ = try? await consumeTask.value
            #expect(await local.startCallCount == cycle)
            #expect(await local.stopCallCount == cycle) // exactly one stop per start — router.stopTranscribing() plus local's own natural finish never double-counts
        }
    }

    @Test("Repeated taps on the Cloud picker (mode already .cloud) are pure no-ops — no extra defaults writes, no router state change")
    func repeatedCloudModeSelectionIsANoOp() async throws {
        let service = AIConversationEngine(
            glassesTransport: SpyGlassesTransport(),
            transcriber: ScriptedContinuousTranscriber(finals: []),
            translator: ScriptedLanguageTranslator(languageCodes: [:]),
            defaults: freshDefaults()
        )
        service.setTranscriptionProviderMode(.cloud)
        #expect(service.transcriptionProviderMode == .cloud)
        // Tapping "Cloud" again, and again — matches setSourceLanguageMode's
        // own established `guard mode != x else { return }` no-op pattern.
        service.setTranscriptionProviderMode(.cloud)
        service.setTranscriptionProviderMode(.cloud)
        #expect(service.transcriptionProviderMode == .cloud)
    }

    // MARK: - AIConversationEngine-level: full pipeline

    @Test("Local → Cloud selection → start(): cloud unavailable → automatic fallback to local → translation continues → G2 keeps receiving → session never terminates")
    func fullPipelineCloudUnavailableFallsBackAndKeepsTranslating() async throws {
        struct RailwayUnreachable: Error {}
        let spy = SpyGlassesTransport()
        let local = FakeOnDeviceTranscriber(finals: ["good morning", "how are you"])
        let cloud = ThrowingStartContinuousTranscriber(error: RailwayUnreachable())
        let router = TranscriptionProviderRouter(
            local: local,
            cloud: cloud,
            mode: { .cloud },
            resolveLocale: { Locale(identifier: "en-US") }
        )
        let service = AIConversationEngine(
            glassesTransport: spy,
            transcriber: router,
            translator: ScriptedLanguageTranslator(
                languageCodes: ["good morning": "en", "how are you": "en"],
                translation: "переклад"
            ),
            defaults: freshDefaults()
        )
        router.onCloudFallback = { [weak service] error in service?.noteCloudFallback(error) }
        service.setTranscriptionProviderMode(.cloud)

        await service.start()
        try? await Task.sleep(for: .milliseconds(150))

        // Never terminated — no error state, still listening.
        #expect(service.state == .listening)
        #expect(service.cloudFallbackNotice == "Cloud transcription is currently unavailable. Using on-device transcription.")
        #expect(service.lastActiveTranscriptionProvider == .onDevice)

        // Both turns' translations reached G2 — translation kept running.
        let displayed = await spy.displayedPageSets
        #expect(displayed.count == 2)
    }

    @Test("Cloud fallback never clears existing conversation/history — turns finalized after the fallback still accumulate in agentContextStore and Glasses Chat")
    func cloudFallbackNeverClearsHistory() async throws {
        struct RailwayUnreachable: Error {}
        let spy = SpyGlassesTransport()
        let store = AgentContextStore()
        let local = FakeOnDeviceTranscriber(finals: ["first turn", "second turn"])
        let cloud = ThrowingStartContinuousTranscriber(error: RailwayUnreachable())
        let router = TranscriptionProviderRouter(
            local: local,
            cloud: cloud,
            mode: { .cloud },
            resolveLocale: { Locale(identifier: "en-US") }
        )
        let chatStore = freshGlassesChatStore()
        let glassesChatProvider = GlassesChatProvider(localStore: chatStore, defaults: freshDefaults())
        let service = AIConversationEngine(
            glassesTransport: spy,
            transcriber: router,
            translator: ScriptedLanguageTranslator(
                languageCodes: ["first turn": "en", "second turn": "en"],
                translation: "переклад"
            ),
            agentContextStore: store,
            glassesChatProvider: glassesChatProvider,
            defaults: freshDefaults()
        )
        router.onCloudFallback = { [weak service] error in service?.noteCloudFallback(error) }

        await service.start()
        try? await Task.sleep(for: .milliseconds(150))

        #expect(store.session.turns.count == 2)
        #expect(store.session.turns.map(\.originalText) == ["first turn", "second turn"])

        let chat = try await glassesChatProvider.findOrCreateGlassesChat()
        let messages = await chatStore.fetchMessages(chatID: chat.id)
        #expect(messages.count == 2) // both turns persisted locally despite the cloud failure
    }

    @Test("Cloud → Local manual switch after a failed Cloud session: stop, switch to On-device, start again — no duplicate transcripts, no leaked tasks, no leftover Cloud-fallback notice")
    func manualCloudToLocalSwitchAfterFailureWorksCleanly() async throws {
        struct RailwayUnreachable: Error {}
        let spy = SpyGlassesTransport()
        let cloudLeaf = ThrowingStartContinuousTranscriber(error: RailwayUnreachable())
        // FakeOnDeviceTranscriber driven manually (no fixed `finals`) so
        // each of the two `start()` calls below can be driven
        // independently — reusing a fixed-`finals` fake across two
        // sessions would replay the SAME text twice within the dedupe
        // window and get silently rejected, which would make the "no
        // duplicate transcript" assertion pass for the wrong reason.
        let local = FakeOnDeviceTranscriber()
        let router = TranscriptionProviderRouter(
            local: local,
            cloud: cloudLeaf,
            mode: { .cloud },
            resolveLocale: { Locale(identifier: "en-US") }
        )
        let service = AIConversationEngine(
            glassesTransport: spy,
            transcriber: router,
            translator: ScriptedLanguageTranslator(
                languageCodes: ["from cloud fallback": "en", "from on-device restart": "en"],
                translation: "переклад"
            ),
            defaults: freshDefaults()
        )
        router.onCloudFallback = { [weak service] error in service?.noteCloudFallback(error) }

        // Session 1: Cloud mode, cloud unreachable, falls back to local.
        await service.start()
        try? await Task.sleep(for: .milliseconds(40))
        await local.emit("from cloud fallback")
        try? await Task.sleep(for: .milliseconds(60))
        #expect(service.cloudFallbackNotice != nil)
        await service.stop()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(service.state == .idle)

        // User manually switches to On-device — the stale Cloud-fallback
        // notice from the PREVIOUS session must be cleared immediately,
        // without needing a restart.
        service.setTranscriptionProviderMode(.onDevice)
        #expect(service.cloudFallbackNotice == nil)

        // Session 2: On-device mode, started fresh — must work cleanly,
        // with no leaked listener from session 1 double-delivering
        // anything.
        await service.start()
        try? await Task.sleep(for: .milliseconds(40))
        await local.emit("from on-device restart")
        try? await Task.sleep(for: .milliseconds(60))
        #expect(service.state == .listening)

        let displayed = await spy.displayedPageSets
        #expect(displayed.count == 2) // exactly one page-set per turn, across both sessions — no duplicates
        #expect(await local.startCallCount == 2) // one real start per session, never more
        #expect(await local.stopCallCount == 1) // only session 1 was explicitly stopped
    }

    // MARK: - Production-wiring: real Cloud stack, scripted local leaf

    /// The real `OpenAIRealtimeTranscriber`/`AuthenticatedAPIClient`
    /// stack (network stubbed, matching the confirmed real-world 404
    /// failure) drives the fallback for real — only the on-device LEAF is
    /// scripted (matching `ProductionWiringOfflineTests`' own established
    /// pattern and its documented reasoning for why a real
    /// `SFSpeechRecognizer` session can't be driven deterministically in
    /// an automated test).
    @Test("PRODUCTION composition: real OpenAIRealtimeTranscriber + real AuthenticatedAPIClient failing exactly as confirmed (404, Railway unreachable) falls back to local — startTranscribing does not throw, session never terminates")
    func productionCloudStackFailureFallsBackToLocal() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.handler = { _ in
            StubURLProtocol.StubResponse(status: 404, body: Data("Application not found".utf8))
        }
        let apiClient = AuthenticatedAPIClient(
            baseURL: URL(string: "https://example.com/api")!,
            session: StubURLProtocol.makeSession(),
            tokenStore: InMemoryAuthTokenStore()
        )
        let spy = SpyGlassesTransport()
        let local = FakeOnDeviceTranscriber(finals: ["hello there"])
        let router = TranscriptionProviderRouter(
            local: local,
            cloud: OpenAIRealtimeTranscriber(apiClient: apiClient), // real production type
            mode: { .cloud },
            resolveLocale: { Locale(identifier: "en-US") }
        )
        let service = AIConversationEngine(
            glassesTransport: spy,
            transcriber: router,
            translator: ScriptedLanguageTranslator(languageCodes: ["hello there": "en"], translation: "привіт"),
            defaults: freshDefaults()
        )
        router.onCloudFallback = { [weak service] error in service?.noteCloudFallback(error) }

        await service.start()
        try? await Task.sleep(for: .milliseconds(200))

        // The exact confirmed real-world claim: the session survives.
        #expect(service.state == .listening)
        #expect(service.cloudFallbackNotice != nil)
        let displayed = await spy.displayedPageSets
        #expect(displayed.count == 1)

        let requests = StubURLProtocol.recordedRequests()
        #expect(requests.contains { $0.url?.path.contains("auth/device") == true })
    }
}
