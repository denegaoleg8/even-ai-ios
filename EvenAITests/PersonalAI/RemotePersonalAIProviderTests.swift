import Testing
import Foundation
@testable import EvenAI

/// Tests for the remote Personal AI provider seam: `RemotePersonalAIModelProvider`,
/// `PersonalAIRemoteTransport`, `PersonalAIRemoteAuthorizing`, and its
/// integration into `FallbackPersonalAIModelProvider`. No conformer used
/// anywhere here is "live" — `FakePersonalAIRemoteTransport`/
/// `FakePersonalAIRemoteAuth` only, never a vendor SDK, never a real
/// credential. `PersonalAIContainer.live` is untouched by this seam.
@Suite("Personal AI: remote provider seam")
struct RemotePersonalAIProviderTests {

    private func request(_ context: PersonalAIContext = .empty, userMessage: String = "hello", messages: [PersonalAIChatMessage] = []) -> PersonalAIGenerationRequest {
        PersonalAIGenerationRequest(personalContext: context, messages: messages, userMessage: userMessage)
    }

    // MARK: 1 — remote provider success

    @Test("a successful transport call answers with provider .cloud")
    func remoteProviderSuccess() async throws {
        let transport = FakePersonalAIRemoteTransport(reply: "hello from remote")
        let provider = RemotePersonalAIModelProvider(providerID: "fake", auth: FakePersonalAIRemoteAuth(), transport: transport)
        let result = try await provider.generate(request())
        #expect(result.text == "hello from remote")
        #expect(result.provider == .cloud)
    }

    // MARK: 2 — remote unavailable (no credential)

    @Test("no credential configured throws .unavailable and never calls the transport")
    func remoteUnavailableNoCredential() async throws {
        let transport = FakePersonalAIRemoteTransport(reply: "should never be reached")
        let provider = RemotePersonalAIModelProvider(providerID: "fake", auth: FakePersonalAIRemoteAuth(token: nil), transport: transport)
        await #expect(throws: PersonalAIProviderOutcome.self) {
            _ = try await provider.generate(request())
        }
        #expect(await transport.requests.isEmpty)
    }

    // MARK: 3 — remote transient failure

    @Test("an opaque transport error is classified as .transientFailure")
    func remoteTransientFailure() async throws {
        struct SomeNetworkError: Error {}
        let transport = FakePersonalAIRemoteTransport(error: SomeNetworkError())
        let provider = RemotePersonalAIModelProvider(providerID: "fake", auth: FakePersonalAIRemoteAuth(), transport: transport)
        do {
            _ = try await provider.generate(request())
            Issue.record("expected a thrown error")
        } catch let outcome as PersonalAIProviderOutcome {
            guard case .transientFailure = outcome else {
                Issue.record("expected .transientFailure, got \(outcome)")
                return
            }
        }
    }

    // MARK: 4 — cancellation preserved

    @Test("a cancellation from the transport propagates as CancellationError, not wrapped")
    func cancellationPreserved() async throws {
        let transport = FakePersonalAIRemoteTransport(error: CancellationError())
        let provider = RemotePersonalAIModelProvider(providerID: "fake", auth: FakePersonalAIRemoteAuth(), transport: transport)
        await #expect(throws: CancellationError.self) {
            _ = try await provider.generate(request())
        }
    }

    // MARK: 5 — timeout behavior

    @Test("a transport slower than the configured timeout is treated as .transientFailure, without waiting for it")
    func timeoutBehavior() async throws {
        let transport = FakePersonalAIRemoteTransport(reply: "too late", delay: .seconds(5))
        let provider = RemotePersonalAIModelProvider(
            providerID: "fake", auth: FakePersonalAIRemoteAuth(), transport: transport, timeout: .milliseconds(50)
        )
        let start = Date()
        do {
            _ = try await provider.generate(request())
            Issue.record("expected a timeout error")
        } catch let outcome as PersonalAIProviderOutcome {
            guard case .transientFailure = outcome else {
                Issue.record("expected .transientFailure, got \(outcome)")
                return
            }
        }
        #expect(Date().timeIntervalSince(start) < 2.0, "should not have waited for the full 5s delay")
    }

    // MARK: 6 — request mapping

    @Test("the request reaching the transport carries context, bounded recent messages, user message, and token budget")
    func requestMapping() async throws {
        let context = PersonalAIContext(
            activeRules: [], relevantMemories: [], relevantProjects: [], relevantPeople: [],
            historicalExcerpts: [], styleInstructions: "",
            systemPromptText: "rendered context block", memoryDisabled: false, buildTrace: []
        )
        var messages: [PersonalAIChatMessage] = []
        for i in 0..<12 {
            messages.append(PersonalAIChatMessage(role: i.isMultiple(of: 2) ? .user : .assistant, text: "turn \(i)"))
        }
        let transport = FakePersonalAIRemoteTransport()
        let provider = RemotePersonalAIModelProvider(providerID: "fake", auth: FakePersonalAIRemoteAuth(), transport: transport)
        _ = try await provider.generate(request(context, userMessage: "the question", messages: messages))

        let sent = try #require(await transport.lastRequest)
        #expect(sent.contextText == "rendered context block")
        #expect(sent.userMessage == "the question")
        #expect(sent.maxOutputTokens == 500)   // PersonalAIGenerationRequest's default
        // bounded to the same last-8 window the on-device tier uses
        #expect(sent.recentMessages.count == 8)
        #expect(sent.recentMessages.first?.text == "turn 4")
        #expect(sent.recentMessages.last?.text == "turn 11")
    }

    // MARK: 7 — response mapping

    @Test("the transport's response text and provider identity reach the generation result unchanged")
    func responseMapping() async throws {
        let transport = FakePersonalAIRemoteTransport(reply: "exact response text")
        let provider = RemotePersonalAIModelProvider(providerID: "fake", auth: FakePersonalAIRemoteAuth(), transport: transport)
        let result = try await provider.generate(request())
        #expect(result.text == "exact response text")
        #expect(result.provider == .cloud)
    }

    // MARK: 8 — selected memory context preserved

    @Test("a profile question's rendered context reaches the remote request exactly as built")
    func selectedMemoryContextPreserved() async throws {
        let store = InMemoryPersonalMemoryStore()
        _ = await MemoryCommandProcessor().process(message: "Запам'ятай: мене звати Олег.", conversationID: UUID(), messageID: UUID(), store: store)
        let context = await DefaultPersonalAIContextBuilder(store: store).buildContext(
            PersonalAIContextRequest(surface: .personalChat, userMessage: "What is my name?")
        )
        let transport = FakePersonalAIRemoteTransport()
        let provider = RemotePersonalAIModelProvider(providerID: "fake", auth: FakePersonalAIRemoteAuth(), transport: transport)
        _ = try await provider.generate(request(context, userMessage: "What is my name?"))

        let sent = try #require(await transport.lastRequest)
        #expect(sent.contextText == context.systemPromptText)
        #expect(sent.contextText.contains("Олег"))
    }

    // MARK: 9 — unrelated memories not transmitted

    @Test("an unrelated stored memory never appears in the remote request")
    func unrelatedMemoriesNotTransmitted() async throws {
        let store = InMemoryPersonalMemoryStore()
        _ = await MemoryCommandProcessor().process(message: "Запам'ятай: мене звати Олег.", conversationID: UUID(), messageID: UUID(), store: store)
        _ = await MemoryCommandProcessor().process(message: "Запам'ятай: я живу в Києві.", conversationID: UUID(), messageID: UUID(), store: store)
        // an unrelated question — no profile lookup, no project/person hint
        let context = await DefaultPersonalAIContextBuilder(store: store).buildContext(
            PersonalAIContextRequest(surface: .personalChat, userMessage: "What is the capital of France?")
        )
        let transport = FakePersonalAIRemoteTransport()
        let provider = RemotePersonalAIModelProvider(providerID: "fake", auth: FakePersonalAIRemoteAuth(), transport: transport)
        _ = try await provider.generate(request(context, userMessage: "What is the capital of France?"))

        let sent = try #require(await transport.lastRequest)
        #expect(sent.contextText.contains("Олег") == false)
        #expect(sent.contextText.localizedCaseInsensitiveContains("києв") == false)
        #expect(sent.userMessage.contains("Олег") == false)
    }

    // MARK: 10 — memoryDisabled respected

    @Test("memory disabled → the remote request carries no stored fact")
    func memoryDisabledRespected() async throws {
        let store = InMemoryPersonalMemoryStore()
        _ = await MemoryCommandProcessor().process(message: "Запам'ятай: мене звати Олег.", conversationID: UUID(), messageID: UUID(), store: store)
        await store.setMemoryEnabledGlobally(false)
        let context = await DefaultPersonalAIContextBuilder(store: store).buildContext(
            PersonalAIContextRequest(surface: .personalChat, userMessage: "What is my name?")
        )
        #expect(context.memoryDisabled)
        let transport = FakePersonalAIRemoteTransport()
        let provider = RemotePersonalAIModelProvider(providerID: "fake", auth: FakePersonalAIRemoteAuth(), transport: transport)
        _ = try await provider.generate(request(context, userMessage: "What is my name?"))

        let sent = try #require(await transport.lastRequest)
        #expect(sent.contextText.contains("Олег") == false)
    }

    // MARK: 11 — no raw provider credentials logged

    @Test("the diagnostic never contains the authorization token")
    func noRawCredentialsLogged() async throws {
        let distinctiveToken = "sk-ZebraQuokkaMarmosetDoNotLog"
        let transport = FakePersonalAIRemoteTransport(reply: "ok")
        let provider = RemotePersonalAIModelProvider(providerID: "fake", auth: FakePersonalAIRemoteAuth(token: distinctiveToken), transport: transport)
        let captured = await StdoutCapture.capture {
            _ = try? await provider.generate(request())
        }
        #expect(captured.contains("PERSONAL_AI_REMOTE_PROVIDER"))
        #expect(captured.contains("providerID=fake"))
        #expect(captured.contains(distinctiveToken) == false)
        // the fake, too, only ever receives the token as an opaque value —
        // proving the provider forwards it without echoing it anywhere else
        #expect(await transport.authorizationsSeen == [distinctiveToken])
    }

    // MARK: 12/13 — router order Apple → remote → heuristic; remote success prevents heuristic

    @Test("router: Apple unavailable → remote succeeds → heuristic is never invoked")
    func routerAppleFailsRemoteSucceedsHeuristicNotCalled() async throws {
        let apple = FakePersonalAIModelProvider(error: PersonalAIProviderOutcome.unavailable(reason: "no Apple Intelligence"))
        let remote = RemotePersonalAIModelProvider(
            providerID: "fake", auth: FakePersonalAIRemoteAuth(),
            transport: FakePersonalAIRemoteTransport(reply: "remote answered")
        )
        let heuristic = FakePersonalAIModelProvider(reply: "should never be reached", provider: .heuristic)
        let router = FallbackPersonalAIModelProvider(tiers: [
            .init(.onDeviceFoundationModel, apple),
            .init(.remoteCapableProvider, remote),
            .init(.heuristic, heuristic)
        ])
        let result = try await router.generate(request())
        #expect(result.text == "remote answered")
        #expect(result.provider == .cloud)
        #expect(await heuristic.requests.isEmpty)
    }

    // MARK: 14 — remote failure falls through to heuristic

    @Test("router: Apple unavailable → remote unavailable → heuristic answers")
    func routerAppleFailsRemoteFailsHeuristicAnswers() async throws {
        let apple = FakePersonalAIModelProvider(error: PersonalAIProviderOutcome.unavailable(reason: "no Apple Intelligence"))
        let remote = RemotePersonalAIModelProvider(
            providerID: "fake", auth: FakePersonalAIRemoteAuth(token: nil),   // no credential → unavailable
            transport: FakePersonalAIRemoteTransport(reply: "should never be reached")
        )
        let router = FallbackPersonalAIModelProvider(tiers: [
            .init(.onDeviceFoundationModel, apple),
            .init(.remoteCapableProvider, remote),
            .init(.heuristic, HeuristicPersonalAIModelProvider())
        ])
        let result = try await router.generate(request(userMessage: "hi there"))
        #expect(result.provider == .heuristic)
        #expect(result.text.isEmpty == false)
    }

    // MARK: 15 — provider metadata correct

    @Test("the router's final result names .cloud when the remote tier is the one that answered")
    func providerMetadataCorrectForRemote() async throws {
        let apple = FakePersonalAIModelProvider(error: FakePersonalAIError(message: "down"))
        let remote = RemotePersonalAIModelProvider(
            providerID: "fake", auth: FakePersonalAIRemoteAuth(),
            transport: FakePersonalAIRemoteTransport(reply: "ok")
        )
        let router = FallbackPersonalAIModelProvider(tiers: [
            .init(.onDeviceFoundationModel, apple), .init(.remoteCapableProvider, remote)
        ])
        let result = try await router.generate(request())
        #expect(result.provider == .cloud)
    }

    // MARK: 16 — no duplicate visible response

    @Test("a full service turn through the 3-tier router appends exactly one assistant message")
    @MainActor
    func noDuplicateVisibleResponse() async throws {
        let store = InMemoryPersonalMemoryStore()
        let apple = FakePersonalAIModelProvider(error: FakePersonalAIError(message: "down"))
        let remote = RemotePersonalAIModelProvider(
            providerID: "fake", auth: FakePersonalAIRemoteAuth(),
            transport: FakePersonalAIRemoteTransport(reply: "the one remote reply")
        )
        let router = FallbackPersonalAIModelProvider(tiers: [
            .init(.onDeviceFoundationModel, apple),
            .init(.remoteCapableProvider, remote),
            .init(.heuristic, HeuristicPersonalAIModelProvider())
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
        #expect(assistantMessages.first?.text == "the one remote reply")
    }

    // MARK: 17 — owner isolation / tombstones enforced upstream, unaffected by the remote tier

    @Test("owner isolation and tombstones still hold with the remote tier present in the router")
    @MainActor
    func ownerIsolationAndTombstonesUnaffectedByRemoteTier() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("remote-owner-iso-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let storeA = LocalPersonalMemoryStore(directory: dir, ownerID: "A")
        await storeA.upsert([MemoryRecord(category: .profile, canonicalContent: "Мене звати Олег.", importance: 0.65)])
        let recA = try #require(await storeA.allMemories().first)
        await storeA.setMemoryStatus(id: recA.id, status: .deleted)   // tombstoned even for its own owner

        let storeB = LocalPersonalMemoryStore(directory: dir, ownerID: "B")
        let router = FallbackPersonalAIModelProvider(tiers: [
            .init(.onDeviceFoundationModel, FakePersonalAIModelProvider(error: FakePersonalAIError(message: "down"))),
            .init(.remoteCapableProvider, RemotePersonalAIModelProvider(
                providerID: "fake", auth: FakePersonalAIRemoteAuth(), transport: FakePersonalAIRemoteTransport(reply: "no name known")
            )),
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

        // owner A's own (tombstoned) record is also gone even for A
        let svcA = PersonalAIService(
            store: storeA,
            contextBuilder: DefaultPersonalAIContextBuilder(store: storeA),
            modelProvider: router,
            conversationStore: InMemoryPersonalAIConversationStore()
        )
        await svcA.send("What is my name?")
        let replyA = svcA.messages.last { $0.role == .assistant }?.text ?? ""
        #expect(replyA.contains("Олег") == false)
    }
}
