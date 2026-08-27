import Testing
import Foundation
@testable import EvenAI

@Suite("Personal AI: rule & instruction priority")
struct RulePriorityTests {

    // MARK: Scenario 4 — rule outranks preference

    @Test("an active rule outranks a retrieved preference in the rendered context")
    func ruleOutranksPreference() async {
        let store = InMemoryPersonalMemoryStore()
        // A preference (retrieved memory tier).
        _ = await MemoryCommandProcessor().process(message: "Remember I like long, detailed explanations.", conversationID: UUID(), messageID: UUID(), store: store)
        // A rule (active-rule tier) that conflicts.
        await store.upsertRule(Rule(text: "Keep every reply to two sentences maximum.", priority: .activeRule))

        let builder = DefaultPersonalAIContextBuilder(store: store)
        let context = await builder.buildContext(PersonalAIContextRequest(
            surface: .personalChat,
            userMessage: "Explain how the retrieval scoring works."
        ))

        let prompt = context.systemPromptText
        let rulePos = prompt.range(of: "two sentences")?.lowerBound
        let prefPos = prompt.range(of: "long, detailed")?.lowerBound
        #expect(rulePos != nil)
        // The standing-instructions (rule) block is emitted before the
        // "things you know about the user" (retrieved) block.
        if let rulePos, let prefPos {
            #expect(rulePos < prefPos)
        }
        #expect(context.activeRules.contains { $0.text.contains("two sentences") })
    }

    // MARK: Scenario 5 — current explicit instruction overrides stored rule

    @Test("a command in the current message is surfaced above stored rules")
    func currentInstructionOverridesStoredRule() async {
        let store = InMemoryPersonalMemoryStore()
        await store.upsertRule(Rule(text: "Always reply in Ukrainian.", priority: .activeRule))

        let builder = DefaultPersonalAIContextBuilder(store: store)
        let context = await builder.buildContext(PersonalAIContextRequest(
            surface: .personalChat,
            userMessage: "From now on, just for this thread, reply in English."
        ))

        let prompt = context.systemPromptText
        let currentPos = prompt.range(of: "The user just gave you this instruction")?.lowerBound
        let standingPos = prompt.range(of: "Standing instructions")?.lowerBound
        #expect(currentPos != nil)
        if let currentPos, let standingPos {
            #expect(currentPos < standingPos)
        }
        #expect(prompt.localizedCaseInsensitiveContains("reply in English"))
    }

    @Test("priority ladder ordering is explicit and total")
    func priorityLadder() {
        #expect(PersonalAIPriority.explicitCurrentInstruction < PersonalAIPriority.activeRule)
        #expect(PersonalAIPriority.activeRule < PersonalAIPriority.retrievedMemory)
        #expect(PersonalAIPriority.retrievedMemory < PersonalAIPriority.learnedStyle)
        #expect(PersonalAIPriority.learnedStyle < PersonalAIPriority.defaultBehavior)
    }
}
