import Testing
import Foundation
@testable import EvenAI

/// Tests for `FallbackPersonalAIModelProvider` — the provider-independent
/// router that replaced the old, hardcoded "Apple Foundation Models, or
/// else heuristic" chain baked into `OnDevicePersonalAIModelProvider`.
/// Mostly driven with `FakePersonalAIModelProvider` (deterministic, no
/// Apple Intelligence dependency); one test (`appleIntelligenceDisabledMapsToRouterFallback`)
/// exercises the real `OnDevicePersonalAIModelProvider` end to end, the
/// same way `FoundationModelsFallbackDiagnosticTests` does.
@Suite("Personal AI: provider router")
struct PersonalAIProviderRouterTests {

    private func request(_ context: PersonalAIContext = .empty, userMessage: String = "hello") -> PersonalAIGenerationRequest {
        PersonalAIGenerationRequest(personalContext: context, messages: [], userMessage: userMessage)
    }

    // MARK: 1 — primary succeeds → fallback not called

    @Test("a succeeding primary tier answers, and the fallback tier is never invoked")
    func primarySucceedsFallbackNotCalled() async throws {
        let primary = FakePersonalAIModelProvider(reply: "primary reply", provider: .onDeviceFoundationModel)
        let secondary = FakePersonalAIModelProvider(reply: "secondary reply", provider: .heuristic)
        let router = FallbackPersonalAIModelProvider(tiers: [
            .init(.onDeviceFoundationModel, primary), .init(.heuristic, secondary)
        ])
        let result = try await router.generate(request())
        #expect(result.text == "primary reply")
        #expect(result.provider == .onDeviceFoundationModel)
        #expect(await secondary.requests.isEmpty)
    }

    // MARK: 2 — primary unavailable → fallback called

    @Test("a primary tier throwing .unavailable falls through to the next tier")
    func primaryUnavailableFallsThrough() async throws {
        let primary = FakePersonalAIModelProvider(error: PersonalAIProviderOutcome.unavailable(reason: "not configured"))
        let secondary = FakePersonalAIModelProvider(reply: "fallback reply", provider: .heuristic)
        let router = FallbackPersonalAIModelProvider(tiers: [
            .init(.remoteCapableProvider, primary), .init(.heuristic, secondary)
        ])
        let result = try await router.generate(request())
        #expect(result.text == "fallback reply")
        #expect(result.provider == .heuristic)
        #expect(await secondary.requests.count == 1)
    }

    // MARK: 3 — primary transient failure → fallback called

    @Test("a primary tier throwing .transientFailure falls through to the next tier")
    func primaryTransientFailureFallsThrough() async throws {
        let primary = FakePersonalAIModelProvider(error: PersonalAIProviderOutcome.transientFailure(reason: "timed out"))
        let secondary = FakePersonalAIModelProvider(reply: "fallback reply", provider: .heuristic)
        let router = FallbackPersonalAIModelProvider(tiers: [
            .init(.remoteCapableProvider, primary), .init(.heuristic, secondary)
        ])
        let result = try await router.generate(request())
        #expect(result.text == "fallback reply")
        #expect(result.provider == .heuristic)
    }

    // MARK: 4 — deterministic provider order

    private actor CallOrderRecorder {
        private(set) var order: [String] = []
        func record(_ name: String) { order.append(name) }
    }

    private struct OrderRecordingProvider: PersonalAIModelProviding {
        let name: String
        let recorder: CallOrderRecorder
        let inner: any PersonalAIModelProviding
        func generate(_ request: PersonalAIGenerationRequest) async throws -> PersonalAIGenerationResult {
            await recorder.record(name)
            return try await inner.generate(request)
        }
    }

    @Test("three tiers are tried in exactly the configured order")
    func deterministicProviderOrder() async throws {
        let recorder = CallOrderRecorder()
        let tier1 = OrderRecordingProvider(name: "tier1", recorder: recorder, inner: FakePersonalAIModelProvider(error: FakePersonalAIError(message: "1 down")))
        let tier2 = OrderRecordingProvider(name: "tier2", recorder: recorder, inner: FakePersonalAIModelProvider(error: FakePersonalAIError(message: "2 down")))
        let tier3 = OrderRecordingProvider(name: "tier3", recorder: recorder, inner: FakePersonalAIModelProvider(reply: "third", provider: .heuristic))
        let router = FallbackPersonalAIModelProvider(tiers: [
            .init(.onDeviceFoundationModel, tier1), .init(.remoteCapableProvider, tier2), .init(.heuristic, tier3)
        ])
        let result = try await router.generate(request())
        #expect(result.text == "third")
        #expect(await recorder.order == ["tier1", "tier2", "tier3"])
    }

    // MARK: 5 — cancellation preserved

    @Test("a cancellation from a tier propagates and does not fall through to the next tier")
    func cancellationPreserved() async throws {
        let primary = FakePersonalAIModelProvider(error: CancellationError())
        let secondary = FakePersonalAIModelProvider(reply: "should never be reached", provider: .heuristic)
        let router = FallbackPersonalAIModelProvider(tiers: [
            .init(.onDeviceFoundationModel, primary), .init(.heuristic, secondary)
        ])
        await #expect(throws: CancellationError.self) {
            _ = try await router.generate(request())
        }
        #expect(await secondary.requests.isEmpty)
    }

    // MARK: 6 — no duplicate response generation

    @Test("a full service turn through the router appends exactly one assistant message")
    @MainActor
    func noDuplicateResponse() async throws {
        let store = InMemoryPersonalMemoryStore()
        let primary = FakePersonalAIModelProvider(error: FakePersonalAIError(message: "down"))
        let secondary = FakePersonalAIModelProvider(reply: "the one reply", provider: .heuristic)
        let router = FallbackPersonalAIModelProvider(tiers: [
            .init(.onDeviceFoundationModel, primary), .init(.heuristic, secondary)
        ])
        let svc = PersonalAIService(
            store: store,
            contextBuilder: DefaultPersonalAIContextBuilder(store: store),
            modelProvider: router,
            conversationStore: InMemoryPersonalAIConversationStore()
        )
        await svc.send("hello")
        let assistantMessages = svc.messages.filter { $0.role == .assistant }
        #expect(assistantMessages.count == 1)
        #expect(assistantMessages.first?.text == "the one reply")
    }

    // MARK: 7 — final provider metadata correct

    @Test("the returned result names whichever tier actually answered")
    func finalProviderMetadataCorrect() async throws {
        let primary = FakePersonalAIModelProvider(error: FakePersonalAIError(message: "down"))
        let secondary = FakePersonalAIModelProvider(reply: "ok", provider: .heuristic)
        let router = FallbackPersonalAIModelProvider(tiers: [
            .init(.onDeviceFoundationModel, primary), .init(.heuristic, secondary)
        ])
        let result = try await router.generate(request())
        #expect(result.provider == .heuristic)
    }

    // MARK: 8 — memory context passed unchanged to fallback

    @Test("the exact same request reaches the fallback tier, unmodified by the router")
    func memoryContextUnchangedAcrossTiers() async throws {
        let context = PersonalAIContext(
            activeRules: [], relevantMemories: [], relevantProjects: [], relevantPeople: [],
            historicalExcerpts: [], styleInstructions: "keep it short.",
            systemPromptText: "some rendered block", memoryDisabled: false, buildTrace: ["retrieved=2/2"]
        )
        let req = request(context, userMessage: "does this survive the hop?")
        let primary = FakePersonalAIModelProvider(error: FakePersonalAIError(message: "down"))
        let secondary = FakePersonalAIModelProvider(reply: "ok", provider: .heuristic)
        let router = FallbackPersonalAIModelProvider(tiers: [
            .init(.onDeviceFoundationModel, primary), .init(.heuristic, secondary)
        ])
        _ = try await router.generate(req)
        let received = try #require(await secondary.requests.last)
        #expect(received == req)
    }

    // MARK: 9 — profile-memory request still contains retrieved context through fallback

    @Test("a profile question's retrieved memory still reaches the fallback tier")
    func profileMemoryReachesFallback() async throws {
        let store = InMemoryPersonalMemoryStore()
        _ = await MemoryCommandProcessor().process(message: "Запам'ятай: мене звати Олег.", conversationID: UUID(), messageID: UUID(), store: store)
        let context = await DefaultPersonalAIContextBuilder(store: store).buildContext(
            PersonalAIContextRequest(surface: .personalChat, userMessage: "What is my name?")
        )
        let primary = FakePersonalAIModelProvider(error: FakePersonalAIError(message: "down"))
        let secondary = FakePersonalAIModelProvider(reply: "ok", provider: .heuristic)
        let router = FallbackPersonalAIModelProvider(tiers: [
            .init(.onDeviceFoundationModel, primary), .init(.heuristic, secondary)
        ])
        _ = try await router.generate(request(context, userMessage: "What is my name?"))
        let received = try #require(await secondary.requests.last)
        #expect(received.personalContext.relevantMemories.contains { $0.category == .profile && $0.canonicalContent.contains("Олег") })
    }

    // MARK: 10 — memoryDisabled behavior unchanged

    @Test("memoryDisabled is passed through the router unchanged")
    func memoryDisabledUnchanged() async throws {
        let context = PersonalAIContext(
            activeRules: [], relevantMemories: [], relevantProjects: [], relevantPeople: [],
            historicalExcerpts: [], styleInstructions: "",
            systemPromptText: "Personal memory is turned off …", memoryDisabled: true, buildTrace: ["memoryDisabled"]
        )
        let primary = FakePersonalAIModelProvider(error: FakePersonalAIError(message: "down"))
        let secondary = FakePersonalAIModelProvider(reply: "ok", provider: .heuristic)
        let router = FallbackPersonalAIModelProvider(tiers: [
            .init(.onDeviceFoundationModel, primary), .init(.heuristic, secondary)
        ])
        _ = try await router.generate(request(context))
        let received = try #require(await secondary.requests.last)
        #expect(received.personalContext.memoryDisabled)
    }

    // MARK: 11 — owner isolation unchanged

    @Test("owner B's router-composed service cannot surface owner A's memory")
    @MainActor
    func ownerIsolationUnchanged() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("router-owner-iso-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let storeA = LocalPersonalMemoryStore(directory: dir, ownerID: "A")
        await storeA.upsert([MemoryRecord(category: .profile, canonicalContent: "Мене звати Олег.", importance: 0.65)])

        let storeB = LocalPersonalMemoryStore(directory: dir, ownerID: "B")
        let router = FallbackPersonalAIModelProvider(tiers: [
            .init(.onDeviceFoundationModel, FakePersonalAIModelProvider(error: FakePersonalAIError(message: "down"))),
            .init(.heuristic, HeuristicPersonalAIModelProvider())
        ])
        let svcB = PersonalAIService(
            store: storeB,
            contextBuilder: DefaultPersonalAIContextBuilder(store: storeB),
            modelProvider: router,
            conversationStore: InMemoryPersonalAIConversationStore()
        )
        await svcB.send("What is my name?")
        let reply = svcB.messages.last { $0.role == .assistant }?.text ?? ""
        #expect(reply.contains("Олег") == false)
    }

    // MARK: 12 — tombstones/deleted memory not resurrected

    @Test("a deleted memory does not resurface through the router-composed service")
    @MainActor
    func tombstonesNotResurrected() async throws {
        let store = InMemoryPersonalMemoryStore()
        let rec = MemoryRecord(category: .profile, canonicalContent: "Мене звати Олег.", importance: 0.65)
        await store.upsert([rec])
        await store.setMemoryStatus(id: rec.id, status: .deleted)

        let router = FallbackPersonalAIModelProvider(tiers: [
            .init(.onDeviceFoundationModel, FakePersonalAIModelProvider(error: FakePersonalAIError(message: "down"))),
            .init(.heuristic, HeuristicPersonalAIModelProvider())
        ])
        let svc = PersonalAIService(
            store: store,
            contextBuilder: DefaultPersonalAIContextBuilder(store: store),
            modelProvider: router,
            conversationStore: InMemoryPersonalAIConversationStore()
        )
        await svc.send("What is my name?")
        let reply = svc.messages.last { $0.role == .assistant }?.text ?? ""
        #expect(reply.contains("Олег") == false)
    }

    // MARK: 13, 14, 15 — diagnostics: metadata present, content-free

    @Test("router diagnostics carry provider/failure metadata and never raw user text, memory, or system prompt")
    func diagnosticsAreCompleteAndContentFree() async throws {
        let distinctiveUserText = "ZebraQuokkaMarmoset the exact question"
        let distinctiveMemory = "PlatypusOcelotFlamingo the user's name is Oleg"
        let distinctivePrompt = "Known facts about the user — the user is asking about themselves"
        let context = PersonalAIContext(
            activeRules: [], relevantMemories: [], relevantProjects: [], relevantPeople: [],
            historicalExcerpts: [], styleInstructions: "",
            systemPromptText: "\(distinctivePrompt): \(distinctiveMemory)",
            memoryDisabled: false, buildTrace: ["retrieved=1/1", "knownProfile=1"]
        )
        let primary = FakePersonalAIModelProvider(error: PersonalAIProviderOutcome.unavailable(reason: "not configured"))
        let secondary = FakePersonalAIModelProvider(reply: "ok", provider: .heuristic)
        let router = FallbackPersonalAIModelProvider(tiers: [
            .init(.remoteCapableProvider, primary), .init(.heuristic, secondary)
        ])

        let captured = await StdoutCapture.capture {
            _ = try? await router.generate(request(context, userMessage: distinctiveUserText))
        }

        // 13 — provider/failure metadata present
        #expect(captured.contains("PERSONAL_AI_PROVIDER_ROUTER"))
        #expect(captured.contains("tier=remoteCapableProvider"))
        #expect(captured.contains("outcome=failed"))
        #expect(captured.contains("category=unavailable"))
        #expect(captured.contains("nextTier=heuristic"))
        #expect(captured.contains("tier=heuristic outcome=success selected=heuristic"))

        // 14, 15 — content-free
        #expect(captured.contains(distinctiveUserText) == false)
        #expect(captured.contains(distinctiveMemory) == false)
        #expect(captured.contains(distinctivePrompt) == false)
        #expect(captured.contains("Oleg") == false)
    }

    // MARK: 16 — Apple Intelligence disabled physical-trace condition maps cleanly to router fallback

    @Test("the shipping router composition falls back to heuristic when the real on-device tier can't answer, exactly as the physical trace showed")
    @MainActor
    func appleIntelligenceDisabledMapsToRouterFallback() async throws {
        let router = FallbackPersonalAIModelProvider(tiers: [
            .init(.onDeviceFoundationModel, OnDevicePersonalAIModelProvider()),
            .init(.heuristic, HeuristicPersonalAIModelProvider())
        ])
        let captured: String
        var result: PersonalAIGenerationResult?
        captured = await StdoutCapture.capture {
            result = try? await router.generate(request(userMessage: "hello"))
        }
        let unwrapped = try #require(result)
        #expect(unwrapped.provider == .heuristic)
        #expect(unwrapped.text.isEmpty == false)
        #expect(captured.contains("tier=onDeviceFoundationModel outcome=failed"))
        #expect(captured.contains("nextTier=heuristic"))
        #expect(captured.contains("tier=heuristic outcome=success selected=heuristic"))
    }
}
