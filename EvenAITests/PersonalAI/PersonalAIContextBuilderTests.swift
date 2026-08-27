import Testing
import Foundation
@testable import EvenAI

@Suite("Personal AI: context builder")
struct PersonalAIContextBuilderTests {

    private func seededStore() async -> InMemoryPersonalMemoryStore {
        let store = InMemoryPersonalMemoryStore()
        _ = await MemoryCommandProcessor().process(
            message: "Remember I'm building EvenAI for Even G2 smart glasses — the current focus is on-device transcription, translation, and suggested replies.",
            conversationID: UUID(), messageID: UUID(), store: store
        )
        return store
    }

    // MARK: Scenario 16 — generic filler discouraged when useful context exists

    @Test("the rendered context tells the model not to use empty acknowledgements")
    func discouragesFillerWhenContextExists() async {
        let store = await seededStore()
        let builder = DefaultPersonalAIContextBuilder(store: store)
        let context = await builder.buildContext(PersonalAIContextRequest(
            surface: .personalChat,
            userMessage: "I'm having problems with the suggested replies."
        ))
        #expect(context.hasPersonalization)
        #expect(context.relevantProjects.contains { $0.canonicalContent.contains("EvenAI") })
        #expect(context.systemPromptText.localizedCaseInsensitiveContains("thanks for sharing"))
        #expect(context.systemPromptText.localizedCaseInsensitiveContains("empty acknowledgement"))
    }

    @Test("the heuristic model provider connects the message to project context and never replies with filler")
    func heuristicProviderConnectsContext() async throws {
        let store = await seededStore()
        let builder = DefaultPersonalAIContextBuilder(store: store)
        let context = await builder.buildContext(PersonalAIContextRequest(
            surface: .personalChat,
            userMessage: "I'm having problems with the suggested replies."
        ))
        let result = try await HeuristicPersonalAIModelProvider().generate(PersonalAIGenerationRequest(
            personalContext: context, messages: [], userMessage: "I'm having problems with the suggested replies."
        ))
        #expect(result.usedPersonalization)
        #expect(result.text.localizedCaseInsensitiveContains("EvenAI"))
        for filler in ["thanks for sharing", "that's interesting", "i'm here if you need anything"] {
            #expect(result.text.localizedCaseInsensitiveContains(filler) == false)
        }
    }

    // MARK: Scenario 25 — expired context never enters prompt (builder-level)

    @Test("archived and expired memories are absent from the built context")
    func expiredAbsentFromContext() async {
        let store = InMemoryPersonalMemoryStore()
        var expired = MemoryRecord(category: .workingContext, canonicalContent: "Reviewing the launch checklist in Berlin.")
        expired.expiresAt = Date().addingTimeInterval(-120)
        await store.upsert([expired])

        let builder = DefaultPersonalAIContextBuilder(store: store)
        let context = await builder.buildContext(PersonalAIContextRequest(
            surface: .personalChat, userMessage: "What's on the launch checklist?"
        ))
        #expect(context.relevantMemories.isEmpty)
        #expect(context.systemPromptText.localizedCaseInsensitiveContains("Berlin") == false)
    }

    // MARK: Scenario 26 — unrelated project info doesn't pollute the prompt

    @Test("only the queried project's memory is rendered")
    func unrelatedProjectNotRendered() async {
        let store = InMemoryPersonalMemoryStore()
        await store.upsert([
            MemoryRecord(category: .projects, canonicalContent: "EvenAI: a personal AI for Even G2 smart glasses.", entities: ["evenai", "g2"]),
            MemoryRecord(category: .projects, canonicalContent: "Kitchen renovation: new cabinets and countertops in the spring.", entities: ["kitchen", "renovation"]),
        ])
        let builder = DefaultPersonalAIContextBuilder(store: store)
        let context = await builder.buildContext(PersonalAIContextRequest(
            surface: .personalChat, userMessage: "Where did we land on the EvenAI retrieval design?", projectHints: ["evenai"]
        ))
        #expect(context.systemPromptText.contains("EvenAI"))
        #expect(context.systemPromptText.localizedCaseInsensitiveContains("kitchen") == false)
    }

    // MARK: Token budget

    @Test("the rendered context respects the token budget by dropping lowest-priority material first")
    func tokenBudgetTrimsLowestPriorityFirst() async {
        let store = InMemoryPersonalMemoryStore()
        await store.upsertRule(Rule(text: "Always double-check dates before stating them.", priority: .activeRule))
        for i in 0..<20 {
            await store.upsert([MemoryRecord(category: .knowledge, canonicalContent: "Fact number \(i) about the EvenAI project and its retrieval pipeline design.", entities: ["evenai"])])
        }
        let builder = DefaultPersonalAIContextBuilder(store: store)
        let tight = await builder.buildContext(PersonalAIContextRequest(surface: .personalChat, userMessage: "Tell me about EvenAI retrieval.", tokenBudget: 120))
        #expect(PersonalAIContextRenderer.approxTokens(tight.systemPromptText) <= 200)
        // The rule (higher priority) survives the trim.
        #expect(tight.systemPromptText.localizedCaseInsensitiveContains("double-check dates"))
    }
}
