import Testing
import Foundation
@testable import EvenAI

/// §9 local end-to-end harness: the full production call chain —
/// `PersonalAIService` → `FallbackPersonalAIModelProvider` →
/// `RemotePersonalAIModelProvider` → `OpenAIResponsesTransport` → mapper —
/// down to a fake proxy that never leaves the process. No real network
/// call; no real credential; `PersonalAIContainer.live` is not involved
/// (this composition exists only in this test file).
@Suite("Personal AI: OpenAI remote — local end-to-end harness")
struct OpenAIRemoteEndToEndTests {

    private let proxyURL = URL(string: "https://proxy.example.invalid/personal-ai/generate")!

    /// A fake proxy that actually reads the request it received and
    /// derives its reply from it — proving the profile fact genuinely
    /// flowed all the way through the real mapping code, not a hardcoded
    /// fixture that happens to say the right name.
    private func deriveNameFromRequestFakeHTTPClient() -> FakeOpenAIProxyHTTPClient {
        FakeOpenAIProxyHTTPClient { urlRequest in
            let body = urlRequest.httpBody ?? Data()
            let dto = try JSONDecoder().decode(OpenAIResponsesRequestDTO.self, from: body)
            let instructions = dto.instructions ?? ""
            let name = instructions.contains("Олег") ? "Олег" : "someone unknown"
            let json = """
            {"output":[{"type":"message","content":[{"type":"output_text","text":"Your name is \(name)."}]}]}
            """
            return (200, Data(json.utf8))
        }
    }

    @Test("\"Запам'ятай: мене звати Олег.\" → new conversation → \"What is my name?\": the reply genuinely comes from the OpenAI-shaped remote tier, heuristic is never invoked, no duplicate response")
    @MainActor
    func endToEndProfileRegression() async throws {
        let store = InMemoryPersonalMemoryStore()
        let fakeHTTP = deriveNameFromRequestFakeHTTPClient()
        let transport = OpenAIResponsesTransport(proxyURL: proxyURL, httpClient: fakeHTTP)
        let remote = RemotePersonalAIModelProvider(providerID: "openai", auth: FakePersonalAIRemoteAuth(), transport: transport)
        let apple = FakePersonalAIModelProvider(error: PersonalAIProviderOutcome.unavailable(reason: "no Apple Intelligence"))
        let heuristic = FakePersonalAIModelProvider(reply: "should never be reached", provider: .heuristic)
        let router = FallbackPersonalAIModelProvider(tiers: [
            .init(.onDeviceFoundationModel, apple),
            .init(.remoteCapableProvider, remote),
            .init(.heuristic, heuristic)
        ])
        let svc = PersonalAIService(
            store: store,
            contextBuilder: DefaultPersonalAIContextBuilder(store: store),
            modelProvider: router,
            conversationStore: InMemoryPersonalAIConversationStore()
        )

        await svc.send("Запам'ятай: мене звати Олег.")
        await svc.startNewConversation()
        await svc.send("What is my name?")

        let assistantMessages = svc.messages.filter { $0.role == .assistant }
        #expect(assistantMessages.count == 1, "no duplicate visible response")
        let reply = assistantMessages.last?.text ?? ""
        #expect(reply.contains("Олег"), "the reply should genuinely name Oleg: \(reply)")
        #expect(await heuristic.requests.isEmpty, "heuristic must not be invoked when the remote tier succeeds")

        // the request that actually reached the fake proxy for the profile
        // question carried the retrieved profile context — confirms this
        // end-to-end, not just at the unit level. (Two requests total: the
        // "remember" turn also generates a reply, same as any other turn;
        // only the second, the actual question, is asserted on here.)
        let sentRequests = await fakeHTTP.requests
        #expect(sentRequests.count == 2)
        let sentBody = try #require(sentRequests.last?.httpBody)
        let sentDTO = try JSONDecoder().decode(OpenAIResponsesRequestDTO.self, from: sentBody)
        #expect(sentDTO.instructions?.contains("Олег") == true)
    }

    @Test("an unrelated memory never appears in the bytes sent to the OpenAI-shaped proxy")
    @MainActor
    func endToEndNoUnrelatedMemoryLeak() async throws {
        let store = InMemoryPersonalMemoryStore()
        let fakeHTTP = FakeOpenAIProxyHTTPClient(status: 200, body: Data(#"{"output":[{"type":"message","content":[{"type":"output_text","text":"Paris."}]}]}"#.utf8))
        let transport = OpenAIResponsesTransport(proxyURL: proxyURL, httpClient: fakeHTTP)
        let remote = RemotePersonalAIModelProvider(providerID: "openai", auth: FakePersonalAIRemoteAuth(), transport: transport)
        let router = FallbackPersonalAIModelProvider(tiers: [
            .init(.onDeviceFoundationModel, FakePersonalAIModelProvider(error: FakePersonalAIError(message: "down"))),
            .init(.remoteCapableProvider, remote),
            .init(.heuristic, HeuristicPersonalAIModelProvider())
        ])
        let svc = PersonalAIService(
            store: store,
            contextBuilder: DefaultPersonalAIContextBuilder(store: store),
            modelProvider: router,
            conversationStore: InMemoryPersonalAIConversationStore()
        )

        await svc.send("Запам'ятай: мене звати Олег.")
        await svc.send("Запам'ятай: я живу в Києві.")
        await svc.startNewConversation()
        await svc.send("What is the capital of France?")

        let sentBody = try #require(await fakeHTTP.lastRequest?.httpBody)
        let bodyString = String(data: sentBody, encoding: .utf8) ?? ""
        #expect(bodyString.contains("Олег") == false)
        #expect(bodyString.localizedCaseInsensitiveContains("києв") == false)
    }
}
