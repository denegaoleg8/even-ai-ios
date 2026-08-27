import Testing
import Foundation
@testable import EvenAI

@Suite("Personal AI: style profile")
struct StyleProfileTests {

    // MARK: Scenario 14 — style influences context

    @Test("an explicit style directive is applied immediately and reaches the rendered context")
    func explicitStyleInfluencesContext() async {
        let store = InMemoryPersonalMemoryStore()
        _ = await MemoryCommandProcessor().process(message: "Use Ukrainian when talking to me, and be direct.", conversationID: UUID(), messageID: UUID(), store: store)

        let profile = await store.styleProfile()
        #expect(profile.preferredLanguage == "uk")
        #expect((profile.directness ?? 0) >= 0.6)

        let builder = DefaultPersonalAIContextBuilder(store: store)
        let context = await builder.buildContext(PersonalAIContextRequest(surface: .personalChat, userMessage: "How's the project going?"))
        #expect(context.styleInstructions.localizedCaseInsensitiveContains("ukrainian"))
        #expect(context.systemPromptText.localizedCaseInsensitiveContains("Response style"))
    }

    // MARK: Scenario 15 — one message does not permanently overfit style

    @Test("a single terse message does not flip the projected response length")
    func oneMessageDoesNotOverfit() {
        let learner = StyleProfileLearner()
        var profile = PersonalAIStyleProfile.empty
        profile = learner.observing(userMessage: "yes", in: profile)
        #expect(profile.responseLength == .unspecified, "one short message must not set a permanent preference")

        // Only after several corroborating observations does it move.
        profile = learner.observing(userMessage: "ok", in: profile)
        profile = learner.observing(userMessage: "sure", in: profile)
        profile = learner.observing(userMessage: "got it", in: profile)
        #expect(profile.responseLength == .short)
    }

    @Test("an explicit setting is never overridden by later inferred signals")
    func explicitBeatsInferred() {
        let learner = StyleProfileLearner()
        var profile = learner.applyingDirective("keep replies short", to: .empty)
        #expect(profile.responseLength == .short)
        // Feed many long messages — inference must not flip it to .long.
        let longMessage = String(repeating: "word ", count: 60)
        for _ in 0..<6 { profile = learner.observing(userMessage: longMessage, in: profile) }
        #expect(profile.responseLength == .short)
    }

    @Test("'never say' captures a phrase to avoid")
    func phraseToAvoidCaptured() {
        let learner = StyleProfileLearner()
        let profile = learner.applyingDirective("never say \"thanks for sharing\"", to: .empty)
        #expect(profile.phrasesToAvoid.contains { $0.localizedCaseInsensitiveContains("thanks for sharing") })
    }
}
