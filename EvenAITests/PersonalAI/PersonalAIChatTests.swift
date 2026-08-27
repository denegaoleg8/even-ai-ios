import Testing
import Foundation
@testable import EvenAI

@MainActor
@Suite("Personal AI: chat behaviour")
struct PersonalAIChatTests {

    private func makeService(
        store: InMemoryPersonalMemoryStore = InMemoryPersonalMemoryStore(),
        model: any PersonalAIModelProviding = FakePersonalAIModelProvider(reply: "Here's a substantive answer that connects to what I know."),
        builder: (any PersonalAIContextBuilding)? = nil
    ) -> (PersonalAIService, InMemoryPersonalMemoryStore) {
        let service = PersonalAIService(
            store: store,
            contextBuilder: builder ?? DefaultPersonalAIContextBuilder(store: store),
            modelProvider: model,
            conversationStore: InMemoryPersonalAIConversationStore()
        )
        return (service, store)
    }

    // MARK: Scenario 21 — Personal AI Chat uses PersonalAIContextBuilding

    @Test("send() routes through the PersonalAIContextBuilding contract")
    func sendUsesContextBuilder() async {
        let store = InMemoryPersonalMemoryStore()
        let recorder = RecordingContextBuilder(wrapping: DefaultPersonalAIContextBuilder(store: store))
        let model = FakePersonalAIModelProvider()
        let (service, _) = makeService(store: store, model: model, builder: recorder)

        await service.open()
        await service.send("What should I focus on with EvenAI today?")

        let requests = await recorder.requests
        #expect(requests.count == 1)
        #expect(requests.first?.surface == .personalChat)
        // And the built context actually reached the model.
        let modelRequests = await model.requests
        #expect(modelRequests.count == 1)
        #expect(service.messages.count == 2)
        #expect(service.messages.last?.role == .assistant)
    }

    @Test("conversation history is retained across an open()")
    func historyRetained() async {
        let convStore = InMemoryPersonalAIConversationStore()
        let store = InMemoryPersonalMemoryStore()
        let service1 = PersonalAIService(store: store, contextBuilder: DefaultPersonalAIContextBuilder(store: store), modelProvider: FakePersonalAIModelProvider(), conversationStore: convStore)
        await service1.open()
        await service1.send("First message")
        let id = service1.conversationID

        let service2 = PersonalAIService(store: store, contextBuilder: DefaultPersonalAIContextBuilder(store: store), modelProvider: FakePersonalAIModelProvider(), conversationStore: convStore)
        await service2.open()
        #expect(service2.conversationID == id)
        #expect(service2.messages.count == 2)
    }

    // MARK: Scenario 17 — memory-disabled mode

    @Test("with memory disabled, nothing is stored and the context says so")
    func memoryDisabledStoresNothing() async {
        let (service, store) = makeService()
        await service.open()
        await service.setMemoryEnabled(false)
        await service.send("Remember that I'm building EvenAI for G2 glasses.")

        let memories = await store.allMemories()
        #expect(memories.isEmpty)

        // The built context is explicitly the memory-off variant.
        let builder = DefaultPersonalAIContextBuilder(store: store)
        let context = await builder.buildContext(PersonalAIContextRequest(surface: .personalChat, userMessage: "hi"))
        #expect(context.memoryDisabled)
        #expect(context.systemPromptText.localizedCaseInsensitiveContains("memory is turned off"))
    }

    // MARK: Scenario 18 — do-not-remember conversation

    @Test("a conversation marked 'do not remember' extracts nothing")
    func doNotRememberConversation() async {
        let (service, store) = makeService()
        await service.open()
        await service.setConversationDoNotRemember(true)
        await service.send("I live in Kyiv and I'm building EvenAI.")

        let memories = await store.allMemories()
        #expect(memories.isEmpty)
        #expect(service.messages.count == 2) // the chat still works
    }

    @Test("a generation failure surfaces a useful state, not a crash, and does not lose the user message")
    func generationFailureIsUseful() async {
        let (service, _) = makeService(model: FakePersonalAIModelProvider(error: PersonalAIError.modelUnavailable(reason: "test")))
        await service.open()
        await service.send("Hello")
        if case let .failed(message) = service.status {
            #expect(message.localizedCaseInsensitiveContains("model"))
        } else {
            Issue.record("expected .failed status")
        }
        #expect(service.messages.first?.text == "Hello")
    }
}
