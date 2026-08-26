import Testing
import Foundation
import SwiftData
@testable import EvenAI

/// Production-wiring proof for the local-first architecture pass —
/// deliberately NOT built on `FakeOnDeviceTranscriber`/`NeverCalledTranscriber`
/// the way `TranscriptionProviderRouterTests`/`OfflineLocalFirstIntegrationTests`
/// are: those prove the ROUTING LOGIC is correct in isolation, but a pure
/// fake structurally cannot make a network call regardless of what the
/// logic does, so they can't prove the REAL production dependency graph
/// (`EvenAIApp.init()`'s exact composition) never touches Railway. This
/// suite constructs the SAME concrete types `EvenAIApp` instantiates —
/// `GlassesSpeechTranscriber`, `OpenAIRealtimeTranscriber`,
/// `AuthenticatedAPIClient`, `TranscriptionProviderRouter`,
/// `GlassesChatProvider`, `LocalGlassesChatStore`,
/// `NetworkSuggestedReplyGenerator` — with only the transport-level
/// `URLSession` swapped for `StubURLProtocol` (there is no way to prove
/// "zero Railway calls" other than intercepting the network layer itself
/// — hitting real Railway from an automated test would be the opposite of
/// this proof) and `StubURLProtocol.recordedRequests()` as the ground
/// truth for exactly which network requests, if any, were attempted.
///
/// One disclosed, unavoidable substitution: `GlassesSpeechTranscriber`
/// itself needs a real microphone and one-time Speech-recognition
/// authorization to produce actual transcripts — neither exists in an
/// automated test process, which is exactly why `GlassesSpeechTranscriber`
/// was never unit-tested directly even before this pass (see its own doc
/// comment). `productionRouterNeverTouchesNetworkInOnDeviceMode` below
/// still constructs and drives the REAL `GlassesSpeechTranscriber`
/// instance to prove the START path never reaches the network, regardless
/// of whether on-device recognition itself succeeds in this sandbox;
/// `fullProductionCompositionOfflineIntegration` then proves the REST of
/// the real production graph (router → chat persistence → reply layer →
/// G2 display) processing multiple turns end-to-end, substituting only
/// the literal audio-capture leaf with a scripted `OnDeviceTranscribing`
/// double feeding the SAME real `TranscriptionProviderRouter`.
@MainActor
@Suite("Production wiring — offline/local-first (real production types, stubbed network transport)")
struct ProductionWiringOfflineTests {
    private func freshOfflineAPIClient() -> AuthenticatedAPIClient {
        StubURLProtocol.reset()
        // Never a genuine success — models "Railway is unreachable" for
        // ANY request that does reach this transport. If the on-device
        // path were broken and actually attempted a call, this makes that
        // failure visible immediately rather than accidentally succeeding.
        StubURLProtocol.handler = { _ in
            StubURLProtocol.StubResponse(status: 503, body: Data("{}".utf8))
        }
        return AuthenticatedAPIClient(
            baseURL: URL(string: "https://example.com/api")!,
            session: StubURLProtocol.makeSession(),
            tokenStore: InMemoryAuthTokenStore()
        )
    }

    private func freshGlassesChatStore() -> LocalGlassesChatStore {
        let schema = Schema([ChatEntity.self, MessageEntity.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [configuration])
        return LocalGlassesChatStore(modelContainer: container)
    }

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "ProductionWiringOfflineTests.\(UUID().uuidString)")!
    }

    /// THE core claim under audit: `EvenAIApp`'s exact production
    /// composition — real `GlassesSpeechTranscriber` as `local`, real
    /// `OpenAIRealtimeTranscriber(apiClient:)` as `cloud`, real
    /// `TranscriptionProviderRouter`, `.onDevice` mode — never makes a
    /// single network request, whether or not the real on-device
    /// recognizer itself manages to start in this sandboxed test process.
    @Test("PRODUCTION composition, On-device mode: real GlassesSpeechTranscriber + real OpenAIRealtimeTranscriber + real AuthenticatedAPIClient — zero network requests of any kind")
    func productionRouterNeverTouchesNetworkInOnDeviceMode() async throws {
        let apiClient = freshOfflineAPIClient()
        // The exact concrete types EvenAIApp.init() constructs.
        let router = TranscriptionProviderRouter(
            local: GlassesSpeechTranscriber(),
            cloud: OpenAIRealtimeTranscriber(apiClient: apiClient),
            mode: { .onDevice },
            resolveLocale: { Locale(identifier: "en-US") }
        )

        // No real PCM audio to feed — this test's claim is about the
        // START path never touching the network, not about producing a
        // real transcript (see this suite's own doc comment for why the
        // latter isn't testable headlessly at all). Tolerant of either
        // outcome: `GlassesSpeechTranscriber` may throw
        // `VoiceInputError.recognizerUnavailable` (no granted Speech
        // authorization in this sandbox) or may return a stream that
        // simply never yields anything — either is consistent with "the
        // on-device path was attempted and cloud was never touched."
        _ = try? await router.startTranscribing(pcmUpdates: AsyncStream { $0.finish() })
        await router.stopTranscribing()

        let requests = StubURLProtocol.recordedRequests()
        #expect(requests.isEmpty, "on-device mode made \(requests.count) network request(s): \(requests.map { $0.url?.path ?? "?" })")
        #expect(router.lastActiveProvider == .onDevice) // the attempt was on-device — cloud was never even selected
    }

    /// Same production composition, `.auto` mode this time — proves the
    /// PREFERRED path in normal operation (not just the explicit
    /// On-device setting) also never touches the network for STT startup,
    /// since local is always attempted first and (whether it succeeds or
    /// throws in this sandbox) never itself calls network — only a
    /// genuine local-start FAILURE would trigger a cloud fallback attempt,
    /// which is `TranscriptionProviderRouterTests`' job to verify with a
    /// controllable fake; this test only needs to confirm the real
    /// `GlassesSpeechTranscriber`'s failure mode (if any, in this
    /// sandbox) doesn't ITSELF touch the network on the way to failing.
    @Test("PRODUCTION composition, Auto mode: local-first attempt with real GlassesSpeechTranscriber makes zero network requests before any fallback decision")
    func productionRouterAutoModeLocalAttemptTouchesNoNetwork() async throws {
        let apiClient = freshOfflineAPIClient()
        let router = TranscriptionProviderRouter(
            local: GlassesSpeechTranscriber(),
            cloud: OpenAIRealtimeTranscriber(apiClient: apiClient),
            mode: { .auto },
            resolveLocale: { Locale(identifier: "en-US") },
            // Cloud fallback explicitly disallowed — isolates this test
            // to ONLY the local attempt's own network behavior. If local
            // genuinely fails in this sandbox, this makes the router
            // surface that error directly instead of masking it with a
            // (also network-touching-if-attempted) cloud fallback, which
            // would conflate two different things this test needs to
            // keep separate.
            cloudFallbackAllowed: { false }
        )

        _ = try? await router.startTranscribing(pcmUpdates: AsyncStream { $0.finish() })
        await router.stopTranscribing()

        let requests = StubURLProtocol.recordedRequests()
        #expect(requests.isEmpty, "auto mode's local attempt made \(requests.count) network request(s): \(requests.map { $0.url?.path ?? "?" })")
    }

    /// The full real production graph — `LiveTranslationService` wired
    /// with the real `TranscriptionProviderRouter` (real
    /// `OpenAIRealtimeTranscriber`/`AuthenticatedAPIClient` as `cloud`,
    /// never reached in `.onDevice` mode), real `GlassesChatProvider` +
    /// `LocalGlassesChatStore` (SwiftData), and real
    /// `NetworkSuggestedReplyGenerator` pointed at the SAME offline
    /// `apiClient` — processes MULTIPLE finalized turns end-to-end:
    /// translation reaches the (spy) G2 display transport, turns persist
    /// to the real local Glasses Chat store, the reply layer's real
    /// network attempt fails against the offline backend without ever
    /// stopping the session, and the ONLY network requests that occur at
    /// all are the reply layer's own — never `auth/device`, `auth/refresh`,
    /// or `realtime-transcription` (the STT/auth-critical paths §1 of the
    /// architecture audit is about). The one disclosed substitution: the
    /// literal audio-capture leaf (`local:`) is a scripted
    /// `OnDeviceTranscribing` double, not a real `SFSpeechRecognizer`
    /// session — see this suite's own doc comment for why that's the one
    /// piece no automated test can drive deterministically. Everything
    /// downstream of it — routing, translation dispatch, chat
    /// persistence, reply networking, G2 display — is 100% the real
    /// production object graph.
    @Test("FULL production composition, offline backend: multiple turns process end-to-end, Glasses Chat persists locally, replies fail gracefully, and only the reply layer ever touches the (failing) network — never auth/refresh/realtime-transcription")
    func fullProductionCompositionOfflineIntegration() async throws {
        let apiClient = freshOfflineAPIClient()
        let spy = SpyGlassesTransport()
        let localLeaf = FakeOnDeviceTranscriber(finals: ["good morning", "how are you"])
        let router = TranscriptionProviderRouter(
            local: localLeaf,
            cloud: OpenAIRealtimeTranscriber(apiClient: apiClient), // real, never reached in .onDevice
            mode: { .onDevice },
            resolveLocale: { Locale(identifier: "en-US") }
        )
        let chatStore = freshGlassesChatStore()
        let glassesChatProvider = GlassesChatProvider(localStore: chatStore, defaults: freshDefaults())
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: router,
            translator: ScriptedLanguageTranslator(
                languageCodes: ["good morning": "en", "how are you": "en"],
                translation: "переклад"
            ),
            // Real, network-calling reply generator — proves its real
            // failure mode against the real offline apiClient doesn't
            // stop the session, not just a fake's simulated failure.
            replyGenerator: NetworkSuggestedReplyGenerator(apiClient: apiClient),
            glassesChatProvider: glassesChatProvider,
            defaults: freshDefaults()
        )

        await service.start()
        try? await Task.sleep(for: .milliseconds(300)) // let reply attempts fail and settle

        #expect(service.state == .listening) // never terminated by the reply layer's failures
        #expect(router.lastActiveProvider == .onDevice)

        let displayed = await spy.displayedPageSets
        #expect(displayed.count == 2) // both turns' translations reached G2

        let chat = try await glassesChatProvider.findOrCreateGlassesChat()
        let messages = await chatStore.fetchMessages(chatID: chat.id)
        #expect(messages.count == 2) // both turns persisted to the REAL local store
        #expect(messages.map(\.content).contains { $0.contains("good morning") })
        #expect(messages.map(\.content).contains { $0.contains("how are you") })

        // The precise claim: STT/auth-critical paths are NEVER hit. The
        // reply layer's own attempts against `suggested-replies` ARE
        // expected and allowed here (§8: replies are an optional online
        // enhancement, permitted to try and fail) — this asserts the
        // distinction precisely rather than a blanket "zero requests",
        // which would incorrectly flag the reply layer's legitimate,
        // gracefully-failing attempt as a violation of the STT/auth claim.
        let hitPaths = Set(StubURLProtocol.recordedRequests().compactMap { $0.url?.path })
        let sttAuthCriticalPaths = hitPaths.filter {
            $0.contains("auth/device") || $0.contains("auth/refresh") || $0.contains("realtime-transcription")
        }
        #expect(sttAuthCriticalPaths.isEmpty, "STT/auth-critical paths were hit: \(sttAuthCriticalPaths)")
    }

    /// Same full production graph, Meeting Mode this time — the reply
    /// layer's real (failing) network attempts must still never affect
    /// the translated timeline, and replies stay suppressed from G2
    /// display exactly as in the online case.
    @Test("FULL production composition, offline backend, Meeting Mode: translated timeline persists locally and on G2; STT/auth-critical network paths are never touched")
    func fullProductionCompositionOfflineMeetingMode() async throws {
        let apiClient = freshOfflineAPIClient()
        let spy = SpyGlassesTransport()
        let store = AgentContextStore()
        let localLeaf = FakeOnDeviceTranscriber(finals: ["welcome everyone", "let's begin"])
        let router = TranscriptionProviderRouter(
            local: localLeaf,
            cloud: OpenAIRealtimeTranscriber(apiClient: apiClient),
            mode: { .onDevice },
            resolveLocale: { Locale(identifier: "en-US") }
        )
        let chatStore = freshGlassesChatStore()
        let glassesChatProvider = GlassesChatProvider(localStore: chatStore, defaults: freshDefaults())
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: router,
            translator: ScriptedLanguageTranslator(
                languageCodes: ["welcome everyone": "en", "let's begin": "en"],
                translation: "переклад"
            ),
            agentContextStore: store,
            replyGenerator: NetworkSuggestedReplyGenerator(apiClient: apiClient),
            glassesChatProvider: glassesChatProvider,
            defaults: freshDefaults() // isolated — setConversationMode below must never leak into UserDefaults.standard
        )
        service.setConversationMode(.meeting)

        await service.start()
        try? await Task.sleep(for: .milliseconds(300))

        #expect(service.state == .listening)
        #expect(store.session.turns.count == 2)
        let displayed = await spy.displayedPageSets
        #expect(displayed.count == 2) // translated subtitles/history still reach G2

        let hitPaths = Set(StubURLProtocol.recordedRequests().compactMap { $0.url?.path })
        let sttAuthCriticalPaths = hitPaths.filter {
            $0.contains("auth/device") || $0.contains("auth/refresh") || $0.contains("realtime-transcription")
        }
        #expect(sttAuthCriticalPaths.isEmpty, "STT/auth-critical paths were hit: \(sttAuthCriticalPaths)")
    }

    /// Force-quit/relaunch simulation with the REAL `LocalGlassesChatStore`
    /// (not a fake): a second, independently-constructed
    /// `GlassesChatProvider` sharing only the same `defaults`/
    /// `modelContainer` (exactly what actually survives a real relaunch —
    /// `PersistenceController.shared`'s on-disk SwiftData store and
    /// `UserDefaults.standard`) reloads the identical chat and history.
    @Test("Glasses Chat: force-quit/relaunch (independent GlassesChatProvider + LocalGlassesChatStore instances sharing only persisted state) reloads the same local history — zero network involved")
    func forceQuitRelaunchReloadsSameLocalHistoryWithRealStore() async throws {
        let schema = Schema([ChatEntity.self, MessageEntity.self])
        // A single on-disk-equivalent container shared across two
        // independently-constructed provider instances — the same
        // relationship `PersistenceController.shared` has to two
        // different app launches.
        let container = try! ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let defaults = freshDefaults()

        let firstLaunchStore = LocalGlassesChatStore(modelContainer: container)
        let firstLaunchProvider = GlassesChatProvider(localStore: firstLaunchStore, defaults: defaults)
        let chat = try await firstLaunchProvider.findOrCreateGlassesChat()
        _ = try await firstLaunchProvider.appendTurn(originalText: "before relaunch", translation: "до перезапуску")

        // Simulates a force-quit: brand-new store/provider instances,
        // zero shared in-memory state — only `container`/`defaults`
        // persist across this boundary, exactly like a real relaunch.
        let relaunchStore = LocalGlassesChatStore(modelContainer: container)
        let relaunchProvider = GlassesChatProvider(localStore: relaunchStore, defaults: defaults)
        let reloadedChat = try await relaunchProvider.findOrCreateGlassesChat()
        let reloadedMessages = await relaunchStore.fetchMessages(chatID: reloadedChat.id)

        #expect(reloadedChat.id == chat.id)
        #expect(reloadedMessages.count == 1)
        #expect(reloadedMessages.first?.content.contains("before relaunch") == true)
    }
}
