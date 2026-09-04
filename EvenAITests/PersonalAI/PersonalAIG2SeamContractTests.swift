import Testing
import Foundation
@testable import EvenAI

/// The Phase 1 G2 seam: a protocol contract, proven identical for both
/// surfaces, and proven unable to touch the AI Conversation core.
@MainActor
@Suite("Personal AI: G2 integration seam")
struct PersonalAIG2SeamContractTests {

    // MARK: Scenario 22 — the G2 seam uses the SAME PersonalAIContextBuilding contract

    @Test("Personal AI Chat and the G2 seam call one shared context builder, differing only by surface")
    func sameContractBothSurfaces() async {
        let store = InMemoryPersonalMemoryStore()
        _ = await MemoryCommandProcessor().process(message: "Remember I'm building EvenAI for Even G2 glasses.", conversationID: UUID(), messageID: UUID(), store: store)

        let recorder = RecordingContextBuilder(wrapping: DefaultPersonalAIContextBuilder(store: store))
        let service = PersonalAIService(
            store: store, contextBuilder: recorder,
            modelProvider: FakePersonalAIModelProvider(),
            conversationStore: InMemoryPersonalAIConversationStore()
        )

        // Chat surface.
        await service.open()
        await service.send("How's EvenAI going?")

        // G2 seam surface — same object, same builder.
        let g2Context = await service.personalContext(
            for: .g2Replies,
            message: "Wie läuft das EvenAI-Projekt?",
            recentTurns: []
        )

        let requests = await recorder.requests
        #expect(requests.count == 2)
        #expect(await recorder.surfaces == [.personalChat, .g2Replies])
        // The same builder produced a usable context for the G2 surface.
        #expect(g2Context.hasPersonalization)
        #expect(g2Context.relevantProjects.contains { $0.canonicalContent.contains("EvenAI") })
    }

    @Test("PersonalAIContextRequest for both surfaces is the exact same type")
    func requestTypeIsShared() {
        let chat = PersonalAIContextRequest(surface: .personalChat, userMessage: "x")
        let g2 = PersonalAIContextRequest(surface: .g2Replies, userMessage: "x")
        #expect(type(of: chat) == type(of: g2))
    }

    // MARK: Scenario 23 — Personal AI failure cannot affect AI Conversation core

    @Test("a failing Personal AI running alongside a live AIConversationEngine session does not affect translation or local replies")
    func personalAIFailureCannotAffectAIConversation() async {
        // A Personal AI that fails at every layer.
        let failingStore = InMemoryPersonalMemoryStore()
        let failingService = PersonalAIService(
            store: failingStore,
            contextBuilder: DefaultPersonalAIContextBuilder(store: failingStore),
            modelProvider: FakePersonalAIModelProvider(error: FakePersonalAIError(message: "down")),
            conversationStore: InMemoryPersonalAIConversationStore(),
            extractor: ThrowingMemoryExtractor()
        )
        await failingService.open()
        await failingService.send("this will fail")
        if case .failed = failingService.status {} else { Issue.record("expected the Personal AI to be in a failed state") }

        // Meanwhile, a full AIConversationEngine session runs untouched.
        let spy = SpyGlassesTransport()
        let engine = AIConversationEngine(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["Do you want to come with us tomorrow?"]),
            translator: ScriptedLanguageTranslator(
                languageCodes: ["Do you want to come with us tomorrow?": "en"],
                translation: "Ти хочеш піти з нами завтра?"
            ),
            replyGenerator: FakeSuggestedReplyGenerator(defaultReplies: [
                SuggestedReply(originalLanguageText: "Yes, sure.", ukrainianText: "Так, звісно.", ordering: 0),
            ]),
            defaults: UserDefaults(suiteName: "G2SeamTest.\(UUID().uuidString)")!
        )
        await engine.start()
        try? await Task.sleep(for: .milliseconds(200))

        let displayed = await spy.displayedPageSets
        #expect(displayed.isEmpty == false)
        #expect(displayed.first?.first?.contains("Ти хочеш піти з нами завтра?") == true)
        #expect(displayed.last?.first?.contains("Yes, sure.") == true)
        await engine.stop()
    }

    // MARK: Scenario 24 — local fallback reply behaviour remains intact

    @Test("the shipping provider router falls back from a failing on-device tier to heuristic and still produces a non-empty, context-using reply")
    func localFallbackRemainsIntact() async throws {
        let store = InMemoryPersonalMemoryStore()
        _ = await MemoryCommandProcessor().process(message: "Remember I'm building EvenAI for G2 glasses, and I'm currently stuck on the suggested replies.", conversationID: UUID(), messageID: UUID(), store: store)
        let context = await DefaultPersonalAIContextBuilder(store: store).buildContext(
            PersonalAIContextRequest(surface: .personalChat, userMessage: "The suggested replies are broken.")
        )

        // Force the on-device tier to fail; the router (not the on-device
        // provider itself any more — see `FallbackPersonalAIModelProvider`)
        // must fall through to heuristic. Same shipping composition as
        // `PersonalAIContainer.live`.
        let router = FallbackPersonalAIModelProvider(tiers: [
            .init(.onDeviceFoundationModel, OnDevicePersonalAIModelProvider(
                onDeviceOverride: FakePersonalAIModelProvider(error: FakePersonalAIError(message: "fm unavailable"))
            )),
            .init(.heuristic, HeuristicPersonalAIModelProvider())
        ])
        let result = try await router.generate(PersonalAIGenerationRequest(
            personalContext: context, messages: [], userMessage: "The suggested replies are broken."
        ))
        #expect(result.provider == .heuristic)
        #expect(result.text.isEmpty == false)
        #expect(result.text.localizedCaseInsensitiveContains("EvenAI"))
    }
}
