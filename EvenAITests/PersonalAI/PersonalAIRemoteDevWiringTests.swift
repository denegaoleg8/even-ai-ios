import Testing
import Foundation
@testable import EvenAI

/// Tests for wiring the remote Personal AI provider into
/// `PersonalAIContainer.live` behind `PersonalAIRemoteDevFlag` — the
/// DEBUG-only, default-OFF gate that lets a physical device try the
/// already-deployed, already end-to-end-tested remote path when Apple
/// Intelligence is unavailable. Every test here uses
/// `PersonalAIProviderComposition.tiers` directly — the exact function
/// `PersonalAIContainer.make` calls — with fakes standing in for the real
/// Apple/remote/heuristic tiers, so these are true shipping-composition
/// regressions, not a reimplementation of the router's own logic (already
/// covered by `PersonalAIProviderRouterTests`/`RemotePersonalAIProviderTests`).
@Suite("Personal AI: remote dev-flag wiring")
struct PersonalAIRemoteDevWiringTests {

    private func request(_ context: PersonalAIContext = .empty, userMessage: String = "hello", messages: [PersonalAIChatMessage] = []) -> PersonalAIGenerationRequest {
        PersonalAIGenerationRequest(personalContext: context, messages: messages, userMessage: userMessage)
    }

    // MARK: 1 — flag OFF: current shipping behavior unchanged

    @Test("flag OFF: exactly today's 2-tier chain — Apple, then heuristic, no remote tier at all")
    func flagOffPreservesShippingShape() async throws {
        let apple = FakePersonalAIModelProvider(reply: "apple answer", provider: .onDeviceFoundationModel)
        let heuristic = FakePersonalAIModelProvider(reply: "heuristic answer", provider: .heuristic)
        let tiers = PersonalAIProviderComposition.tiers(
            appleProvider: apple,
            remoteEnabled: false,
            remoteAuth: FakePersonalAIRemoteAuth(),
            remoteTransport: FakePersonalAIRemoteTransport(),
            heuristicProvider: heuristic
        )
        #expect(tiers.count == 2)
        #expect(tiers[0].identity == .onDeviceFoundationModel)
        #expect(tiers[1].identity == .heuristic)

        let router = FallbackPersonalAIModelProvider(tiers: tiers)
        let result = try await router.generate(request())
        #expect(result.text == "apple answer")
    }

    @Test("flag OFF even when remoteAuth/remoteTransport ARE supplied — the flag alone gates the tier's existence")
    func flagOffIgnoresSuppliedCredentialsToo() {
        let tiers = PersonalAIProviderComposition.tiers(
            appleProvider: FakePersonalAIModelProvider(),
            remoteEnabled: false,
            remoteAuth: FakePersonalAIRemoteAuth(token: "would-be-valid"),
            remoteTransport: FakePersonalAIRemoteTransport(),
            heuristicProvider: FakePersonalAIModelProvider(provider: .heuristic)
        )
        #expect(tiers.count == 2)
        #expect(tiers.map(\.identity) == [.onDeviceFoundationModel, .heuristic])
    }

    // MARK: 2 — flag ON, credential unavailable -> fails closed, not unsafe construction

    @Test("flag ON, no credential (nil auth/transport) -> remote tier is not even added; heuristic answers")
    func flagOnNoCredentialParamsFailsClosed() async throws {
        let apple = FakePersonalAIModelProvider(error: FakePersonalAIError(message: "apple down"))
        let heuristic = FakePersonalAIModelProvider(reply: "heuristic answer", provider: .heuristic)
        let tiers = PersonalAIProviderComposition.tiers(
            appleProvider: apple,
            remoteEnabled: true,
            remoteAuth: nil,
            remoteTransport: nil,
            heuristicProvider: heuristic
        )
        #expect(tiers.count == 2, "no auth/transport supplied -> remote tier must not be constructed at all")
        let result = try await FallbackPersonalAIModelProvider(tiers: tiers).generate(request())
        #expect(result.provider == .heuristic)
    }

    @Test("flag ON, auth/transport supplied but token missing -> the real RemotePersonalAIModelProvider fails closed (.unavailable), heuristic answers")
    func flagOnMissingTokenFailsClosed() async throws {
        let apple = FakePersonalAIModelProvider(error: FakePersonalAIError(message: "apple down"))
        let remoteTransport = FakePersonalAIRemoteTransport(reply: "should never be reached")
        let heuristic = FakePersonalAIModelProvider(reply: "heuristic answer", provider: .heuristic)
        let tiers = PersonalAIProviderComposition.tiers(
            appleProvider: apple,
            remoteEnabled: true,
            remoteAuth: FakePersonalAIRemoteAuth(token: nil),
            remoteTransport: remoteTransport,
            heuristicProvider: heuristic
        )
        #expect(tiers.count == 3)
        let result = try await FallbackPersonalAIModelProvider(tiers: tiers).generate(request())
        #expect(result.provider == .heuristic)
        #expect(await remoteTransport.requests.isEmpty, "no token -> the transport must never be called")
    }

    // MARK: 3 — Apple available: Apple still wins

    @Test("Apple available -> Apple answers, remote and heuristic are never invoked")
    func appleAvailableWins() async throws {
        let apple = FakePersonalAIModelProvider(reply: "apple answer", provider: .onDeviceFoundationModel)
        let remoteTransport = FakePersonalAIRemoteTransport(reply: "should never be reached")
        let heuristic = FakePersonalAIModelProvider(reply: "should never be reached", provider: .heuristic)
        let tiers = PersonalAIProviderComposition.tiers(
            appleProvider: apple,
            remoteEnabled: true,
            remoteAuth: FakePersonalAIRemoteAuth(),
            remoteTransport: remoteTransport,
            heuristicProvider: heuristic
        )
        let result = try await FallbackPersonalAIModelProvider(tiers: tiers).generate(request())
        #expect(result.provider == .onDeviceFoundationModel)
        #expect(await remoteTransport.requests.isEmpty)
        #expect(await heuristic.requests.isEmpty)
    }

    // MARK: 4/5 — Apple unavailable (appleIntelligenceNotEnabled, specifically) -> remote attempted, heuristic not invoked

    @Test("Apple unavailable with the real appleIntelligenceNotEnabled condition -> remote is attempted and answers; heuristic is never invoked")
    func appleIntelligenceDisabledRoutesToRemote() async throws {
        // The REAL OnDevicePersonalAIModelProvider, forced (via its own
        // test seam) to fail exactly the way a physical device with
        // Apple Intelligence off does — not a generic fake failure.
        let apple = OnDevicePersonalAIModelProvider(
            onDeviceOverride: FakePersonalAIModelProvider(error: PersonalAIError.modelUnavailable(reason: "Apple Intelligence is off"))
        )
        let remoteTransport = FakePersonalAIRemoteTransport(reply: "remote answered")
        let heuristic = FakePersonalAIModelProvider(reply: "should never be reached", provider: .heuristic)
        let tiers = PersonalAIProviderComposition.tiers(
            appleProvider: apple,
            remoteEnabled: true,
            remoteAuth: FakePersonalAIRemoteAuth(),
            remoteTransport: remoteTransport,
            heuristicProvider: heuristic
        )
        let result = try await FallbackPersonalAIModelProvider(tiers: tiers).generate(request())
        #expect(result.text == "remote answered")
        #expect(result.provider == .cloud)
        #expect(await remoteTransport.requests.count == 1, "appleIntelligenceNotEnabled must not be treated as terminal — remote must be attempted")
        #expect(await heuristic.requests.isEmpty)
    }

    // MARK: 6 — Apple unavailable, remote fails -> heuristic fallback still works

    @Test("Apple unavailable, remote also fails -> heuristic still answers")
    func appleAndRemoteBothFailHeuristicAnswers() async throws {
        let apple = OnDevicePersonalAIModelProvider(
            onDeviceOverride: FakePersonalAIModelProvider(error: PersonalAIError.modelUnavailable(reason: "Apple Intelligence is off"))
        )
        let remoteTransport = FakePersonalAIRemoteTransport(error: FakePersonalAIError(message: "remote down"))
        let heuristic = FakePersonalAIModelProvider(reply: "heuristic answer", provider: .heuristic)
        let tiers = PersonalAIProviderComposition.tiers(
            appleProvider: apple,
            remoteEnabled: true,
            remoteAuth: FakePersonalAIRemoteAuth(),
            remoteTransport: remoteTransport,
            heuristicProvider: heuristic
        )
        let result = try await FallbackPersonalAIModelProvider(tiers: tiers).generate(request())
        #expect(result.provider == .heuristic)
        #expect(result.text == "heuristic answer")
    }

    // MARK: 7 — cancellation during Apple or remote propagates, never becomes fallback success

    @Test("cancellation from Apple propagates; remote and heuristic are never invoked")
    func cancellationDuringAppleIsNotSwallowed() async throws {
        let apple = FakePersonalAIModelProvider(error: CancellationError())
        let remoteTransport = FakePersonalAIRemoteTransport(reply: "should never be reached")
        let heuristic = FakePersonalAIModelProvider(reply: "should never be reached", provider: .heuristic)
        let tiers = PersonalAIProviderComposition.tiers(
            appleProvider: apple,
            remoteEnabled: true,
            remoteAuth: FakePersonalAIRemoteAuth(),
            remoteTransport: remoteTransport,
            heuristicProvider: heuristic
        )
        await #expect(throws: CancellationError.self) {
            _ = try await FallbackPersonalAIModelProvider(tiers: tiers).generate(request())
        }
        #expect(await remoteTransport.requests.isEmpty)
        #expect(await heuristic.requests.isEmpty)
    }

    @Test("cancellation from the remote transport propagates; heuristic is never invoked")
    func cancellationDuringRemoteIsNotSwallowed() async throws {
        let apple = OnDevicePersonalAIModelProvider(
            onDeviceOverride: FakePersonalAIModelProvider(error: PersonalAIError.modelUnavailable(reason: "Apple Intelligence is off"))
        )
        let remoteTransport = FakePersonalAIRemoteTransport(error: CancellationError())
        let heuristic = FakePersonalAIModelProvider(reply: "should never be reached", provider: .heuristic)
        let tiers = PersonalAIProviderComposition.tiers(
            appleProvider: apple,
            remoteEnabled: true,
            remoteAuth: FakePersonalAIRemoteAuth(),
            remoteTransport: remoteTransport,
            heuristicProvider: heuristic
        )
        await #expect(throws: CancellationError.self) {
            _ = try await FallbackPersonalAIModelProvider(tiers: tiers).generate(request())
        }
        #expect(await heuristic.requests.isEmpty)
    }

    // MARK: 8 — memory disabled: no stored memory in the remote request

    @Test("memory disabled -> the remote request carries no stored fact, through the 3-tier dev composition")
    @MainActor
    func memoryDisabledNoLeakThroughDevComposition() async throws {
        let store = InMemoryPersonalMemoryStore()
        _ = await MemoryCommandProcessor().process(message: "Запам'ятай: мене звати Олег.", conversationID: UUID(), messageID: UUID(), store: store)
        await store.setMemoryEnabledGlobally(false)

        let remoteTransport = FakePersonalAIRemoteTransport(reply: "ok")
        let tiers = PersonalAIProviderComposition.tiers(
            appleProvider: OnDevicePersonalAIModelProvider(onDeviceOverride: FakePersonalAIModelProvider(error: FakePersonalAIError(message: "down"))),
            remoteEnabled: true,
            remoteAuth: FakePersonalAIRemoteAuth(),
            remoteTransport: remoteTransport,
            heuristicProvider: HeuristicPersonalAIModelProvider()
        )
        let svc = PersonalAIService(
            store: store,
            contextBuilder: DefaultPersonalAIContextBuilder(store: store),
            modelProvider: FallbackPersonalAIModelProvider(tiers: tiers),
            conversationStore: InMemoryPersonalAIConversationStore()
        )
        await svc.send("What is my name?")

        let sent = try #require(await remoteTransport.lastRequest)
        #expect(sent.contextText.contains("Олег") == false)
    }

    // MARK: 9 — profile-memory shipping composition: stored fact reaches the provider-neutral request

    @Test("\"Запам'ятай: мене звати Олег.\" -> new conversation -> \"What is my name?\": Oleg reaches the remote request through the dev composition")
    @MainActor
    func profileMemoryReachesRemoteThroughDevComposition() async throws {
        let store = InMemoryPersonalMemoryStore()
        let remoteTransport = FakePersonalAIRemoteTransport(reply: "Your name is Олег.")
        let tiers = PersonalAIProviderComposition.tiers(
            appleProvider: OnDevicePersonalAIModelProvider(onDeviceOverride: FakePersonalAIModelProvider(error: FakePersonalAIError(message: "down"))),
            remoteEnabled: true,
            remoteAuth: FakePersonalAIRemoteAuth(),
            remoteTransport: remoteTransport,
            heuristicProvider: HeuristicPersonalAIModelProvider()
        )
        let svc = PersonalAIService(
            store: store,
            contextBuilder: DefaultPersonalAIContextBuilder(store: store),
            modelProvider: FallbackPersonalAIModelProvider(tiers: tiers),
            conversationStore: InMemoryPersonalAIConversationStore()
        )

        await svc.send("Запам'ятай: мене звати Олег.")
        await svc.startNewConversation()
        await svc.send("What is my name?")

        let reply = svc.messages.last { $0.role == .assistant }?.text ?? ""
        #expect(reply.contains("Олег"))
        let sent = try #require(await remoteTransport.lastRequest)
        #expect(sent.contextText.contains("Олег"))
    }

    // MARK: 10 — stale remote completion cannot overwrite a newer turn

    @Test("a slow remote tier cannot let a second send() race in — the existing status-guard already prevents overlapping turns")
    @MainActor
    func slowRemoteCannotRaceWithASecondTurn() async throws {
        let store = InMemoryPersonalMemoryStore()
        let slowRemote = FakePersonalAIRemoteTransport(reply: "slow remote reply", delay: .milliseconds(200))
        let tiers = PersonalAIProviderComposition.tiers(
            appleProvider: OnDevicePersonalAIModelProvider(onDeviceOverride: FakePersonalAIModelProvider(error: FakePersonalAIError(message: "down"))),
            remoteEnabled: true,
            remoteAuth: FakePersonalAIRemoteAuth(),
            remoteTransport: slowRemote,
            heuristicProvider: HeuristicPersonalAIModelProvider()
        )
        let svc = PersonalAIService(
            store: store,
            contextBuilder: DefaultPersonalAIContextBuilder(store: store),
            modelProvider: FallbackPersonalAIModelProvider(tiers: tiers),
            conversationStore: InMemoryPersonalAIConversationStore()
        )

        let firstTurn = Task { await svc.send("first turn, still in flight") }
        try await Task.sleep(for: .milliseconds(30))   // let the first turn reach `.thinking` and start the slow remote call
        #expect(svc.status == .thinking)

        await svc.send("second turn attempted while the first is still in flight")
        // a same-instance send() while `.thinking` is a documented no-op —
        // no second user message should have been appended.
        #expect(svc.messages.filter { $0.role == .user }.count == 1)

        await firstTurn.value
        #expect(svc.messages.filter { $0.role == .user }.count == 1)
        #expect(svc.messages.last { $0.role == .assistant }?.text == "slow remote reply")
    }

    // MARK: 11 — default (no flag) composition matches today's shipping shape

    @Test("the composition PersonalAIContainer.make actually calls, with the flag's real (test-process) value, matches today's shipping shape")
    func defaultCompositionMatchesShippingShapeInThisTestProcess() {
        // This test process never passes -EvenAIDevRemotePersonalAI, so
        // PersonalAIRemoteDevFlag.isEnabled reflects the same "off by
        // default" state a Release build hardcodes unconditionally.
        #expect(PersonalAIRemoteDevFlag.isEnabled == false)
        let tiers = PersonalAIProviderComposition.tiers(
            appleProvider: FakePersonalAIModelProvider(),
            remoteEnabled: PersonalAIRemoteDevFlag.isEnabled,
            remoteAuth: PersonalAIRemoteDevFlag.auth,
            remoteTransport: PersonalAIRemoteDevFlag.transport,
            heuristicProvider: FakePersonalAIModelProvider(provider: .heuristic)
        )
        #expect(tiers.count == 2)
        #expect(tiers.map(\.identity) == [.onDeviceFoundationModel, .heuristic])
    }

    // MARK: 12 — no secret literal in the dev-flag source itself (regression guard)

    @Test("PersonalAIRemoteDevFlag.swift contains no hardcoded secret-shaped literal")
    func devFlagSourceContainsNoSecretLiteral() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("EvenAI/App/DI/PersonalAIRemoteDevFlag.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        #expect(src.contains("EVENAI_DEV_APP_PROXY_SHARED_SECRET"), "should read the credential from this named environment variable")
        #expect(src.contains("ProcessInfo.processInfo.environment"), "should read from the environment, not a literal")
        #expect(src.range(of: #"sk-[a-zA-Z0-9]{10,}"#, options: .regularExpression) == nil, "no OpenAI-key-shaped literal")
        #expect(src.contains("APP_PROXY_SHARED_SECRET =") == false, "no hardcoded assignment of the shared secret")
    }

    // MARK: Live-composition regression (explicit section) — Apple unavailable -> remote wins; remote fails -> heuristic

    @Test("live-composition regression: Apple unavailable (appleIntelligenceNotEnabled) -> remote selected, heuristic call count 0")
    func liveCompositionRemoteSelected() async throws {
        let apple = OnDevicePersonalAIModelProvider(
            onDeviceOverride: FakePersonalAIModelProvider(error: PersonalAIError.modelUnavailable(reason: "Apple Intelligence is off"))
        )
        let remoteTransport = FakePersonalAIRemoteTransport(reply: "remote reply")
        let heuristic = FakePersonalAIModelProvider(reply: "should never be reached", provider: .heuristic)
        let tiers = PersonalAIProviderComposition.tiers(
            appleProvider: apple,
            remoteEnabled: true,
            remoteAuth: FakePersonalAIRemoteAuth(),
            remoteTransport: remoteTransport,
            heuristicProvider: heuristic
        )
        let result = try await FallbackPersonalAIModelProvider(tiers: tiers).generate(request())
        #expect(result.provider == .cloud)
        #expect(await heuristic.requests.count == 0)
    }

    @Test("live-composition regression: Apple unavailable -> remote error -> heuristic succeeds")
    func liveCompositionHeuristicFallback() async throws {
        let apple = OnDevicePersonalAIModelProvider(
            onDeviceOverride: FakePersonalAIModelProvider(error: PersonalAIError.modelUnavailable(reason: "Apple Intelligence is off"))
        )
        let remoteTransport = FakePersonalAIRemoteTransport(error: FakePersonalAIError(message: "remote error"))
        let heuristic = FakePersonalAIModelProvider(reply: "heuristic reply", provider: .heuristic)
        let tiers = PersonalAIProviderComposition.tiers(
            appleProvider: apple,
            remoteEnabled: true,
            remoteAuth: FakePersonalAIRemoteAuth(),
            remoteTransport: remoteTransport,
            heuristicProvider: heuristic
        )
        let result = try await FallbackPersonalAIModelProvider(tiers: tiers).generate(request())
        #expect(result.provider == .heuristic)
        #expect(result.text == "heuristic reply")
    }
}
