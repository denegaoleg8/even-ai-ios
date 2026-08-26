import Testing
import Foundation
import SwiftData
@testable import EvenAI

/// End-to-end proof of the local-first architecture pass's core product
/// requirement: "G2 glasses must remain useful for live foreign-language
/// conversations even when Railway is unavailable, backend is offline,
/// the user has no paid server subscription, or OpenAI backend services
/// are temporarily unavailable." (§13 "offline test mode" / §14
/// "airplane-mode acceptance" / §18 items 1, 2, 3, 16, 17, 18.)
///
/// The proof strategy for "zero auth/Railway calls" is structural, not
/// behavioral interception: every test in this suite constructs its
/// `LiveTranslationService` graph from ONLY types that have no network
/// capability at all — `FakeOnDeviceTranscriber`/`ScriptedLanguageTranslator`
/// (both pure, in-memory fakes), `LocalGlassesChatStore` (SwiftData, no
/// network), `NoOpSuggestedReplyGenerator` (returns `[]`, never touches
/// anything). `AuthenticatedAPIClient`, `NetworkChatService`,
/// `OpenAIRealtimeTranscriber`, and `URLSessionRealtimeTranscriptionSocket`
/// — the only types in this codebase capable of making a network/Railway
/// call at all — are never imported, referenced, or constructed anywhere
/// in this file. There is therefore no code path by which any of these
/// tests COULD make a network call, auth call, or Railway call, which is
/// the strongest form of this guarantee a test can assert.
@MainActor
@Suite("Offline / local-first Live Translation (simulates BACKEND_OFFLINE = true)")
struct OfflineLocalFirstIntegrationTests {
    private static let propagationDelay: Duration = .milliseconds(150)

    private func freshGlassesChatStore() -> LocalGlassesChatStore {
        let schema = Schema([ChatEntity.self, MessageEntity.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [configuration])
        return LocalGlassesChatStore(modelContainer: container)
    }

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "OfflineLocalFirstIntegrationTests.\(UUID().uuidString)")!
    }

    /// §18 item 16 / §14: a simulated airplane-mode session — local STT,
    /// local translation, local Glasses Chat, no reply provider — completes
    /// MULTIPLE turns end-to-end and every one reaches G2 display and
    /// Glasses Chat history.
    @Test("a fully local session (simulated airplane mode) completes multiple turns: STT → translation → G2 display → Glasses Chat, all local")
    func airplaneModeSessionCompletesMultipleTurns() async throws {
        let spy = SpyGlassesTransport()
        let transcriber = FakeOnDeviceTranscriber(finals: ["good morning", "how are you"])
        let store = freshGlassesChatStore()
        let provider = GlassesChatProvider(localStore: store, defaults: freshDefaults())
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: transcriber,
            translator: ScriptedLanguageTranslator(
                languageCodes: ["good morning": "en", "how are you": "en"],
                translation: "переклад"
            ),
            // NoOpSuggestedReplyGenerator (the default) — Layer 2 simply
            // absent, exactly as it would be with backend unreachable.
            glassesChatProvider: provider
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(service.state == .listening)
        let displayed = await spy.displayedPageSets
        #expect(displayed.count == 2) // both turns reached G2

        let chat = try await provider.findOrCreateGlassesChat()
        let messages = await store.fetchMessages(chatID: chat.id)
        #expect(messages.count == 2) // both turns reached Glasses Chat history
        #expect(messages.map(\.content).contains { $0.contains("good morning") })
        #expect(messages.map(\.content).contains { $0.contains("how are you") })
    }

    /// §18 items 1/2/17: starting and running a fully local session
    /// constructs and touches NOTHING from `Infrastructure/Networking` or
    /// `Infrastructure/Auth` — see this suite's own doc comment for why
    /// that absence, provable at compile/construction time, is the actual
    /// guarantee "zero auth calls, zero Railway calls" means here.
    @Test("local Live Translation start requires no AuthenticatedAPIClient, no ChatServicing, no cloud transcriber to even exist")
    func localStartRequiresNoNetworkCapableTypeToExist() async throws {
        let spy = SpyGlassesTransport()
        let transcriber = FakeOnDeviceTranscriber(finals: ["hallo"])
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: transcriber,
            translator: ScriptedLanguageTranslator(languageCodes: ["hallo": "de"], translation: "привіт")
            // No glassesChatProvider, no replyGenerator override, no
            // apiClient anywhere in this construction graph at all.
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(service.state == .listening)
        #expect(await spy.displayedPageSets == [["hallo\n\nUA: привіт"]])
    }

    /// §18 item 3: a reply generator that always fails (models the backend
    /// being unreachable) never stops, delays, or degrades local
    /// translation — every turn still displays.
    @Test("backend/replies being completely unreachable does not stop local translation from continuing")
    func backendUnreachableRepliesNeverStopLocalTranslation() async throws {
        let spy = SpyGlassesTransport()
        let transcriber = FakeOnDeviceTranscriber(finals: ["first", "second", "third"])
        struct BackendUnreachable: Error {}
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: transcriber,
            translator: ScriptedLanguageTranslator(
                languageCodes: ["first": "en", "second": "en", "third": "en"],
                translation: "переклад"
            ),
            replyGenerator: FakeSuggestedReplyGenerator(error: BackendUnreachable())
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(service.state == .listening) // session never terminated
        let displayed = await spy.displayedPageSets
        #expect(displayed.count == 3) // all three turns' translations reached G2
        // No reply page ever appears — replies simply absent, not an error state.
        #expect(!displayed.contains { pages in pages.contains { $0.contains("Reply") } })
    }

    /// §9/§18 item 13: Meeting Mode continues to function as translated
    /// subtitles/history purely locally, with replies fully absent
    /// (backend unreachable) — not just suppressed-from-display the way
    /// Meeting Mode normally suppresses them.
    @Test("Meeting Mode works fully offline: continuous local translation and history, with no reply provider at all")
    func meetingModeWorksOfflineWithNoReplyProvider() async throws {
        let spy = SpyGlassesTransport()
        let store = AgentContextStore()
        let transcriber = FakeOnDeviceTranscriber(finals: ["welcome everyone", "let's begin"])
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: transcriber,
            translator: ScriptedLanguageTranslator(
                languageCodes: ["welcome everyone": "en", "let's begin": "en"],
                translation: "переклад"
            ),
            agentContextStore: store,
            // replyGenerator defaults to NoOpSuggestedReplyGenerator — no
            // reply provider at all, the most degraded "offline" case.
            // Isolated `defaults:` — `setConversationMode(.meeting)` below
            // persists to whatever `UserDefaults` this instance was given;
            // without an isolated suite here, that write would leak into
            // `UserDefaults.standard` and silently poison every OTHER
            // test in this process that constructs a `LiveTranslationService`
            // without its own explicit `defaults:` override (several
            // `LiveTranslationServiceG2DisplayTests` do exactly that,
            // assuming the untouched `.standard` conversation mode).
            defaults: freshDefaults()
        )
        service.setConversationMode(.meeting)

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(service.state == .listening)
        #expect(store.session.turns.count == 2) // full translated timeline persisted
        #expect(store.session.turns.map(\.originalText) == ["welcome everyone", "let's begin"])
        let displayed = await spy.displayedPageSets
        #expect(displayed.count == 2) // subtitles/history still reach G2
    }

    /// §18 item 18: switching `transcriptionProviderMode` while a session
    /// is already running never wedges/hangs the session — it's a
    /// take-effect-on-next-start preference change (see
    /// `setTranscriptionProviderMode`'s own doc comment), so the CURRENT
    /// session must keep running normally afterward.
    @Test("switching transcription provider mode mid-session never wedges the current session")
    func providerModeSwitchMidSessionNeverWedgesSession() async throws {
        let spy = SpyGlassesTransport()
        let transcriber = FakeOnDeviceTranscriber(finals: ["before switch", "after switch"])
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: transcriber,
            translator: ScriptedLanguageTranslator(
                languageCodes: ["before switch": "en", "after switch": "en"],
                translation: "переклад"
            ),
            defaults: freshDefaults()
        )

        await service.start()
        try? await Task.sleep(for: .milliseconds(60))
        #expect(service.transcriptionProviderMode == .auto) // default

        service.setTranscriptionProviderMode(.cloud)
        #expect(service.transcriptionProviderMode == .cloud)

        try? await Task.sleep(for: .milliseconds(60))

        // The already-running local session (started under the OLD mode)
        // is completely undisturbed — no restart, no hang, still listening.
        #expect(service.state == .listening)
        let displayed = await spy.displayedPageSets
        #expect(displayed.count == 2) // both turns, before and after the switch, still reached G2
    }
}
