import Testing
import Foundation
@testable import EvenAI

@Suite("Personal AI: passive memory extraction")
struct HeuristicMemoryExtractorTests {

    private let extractor = HeuristicMemoryExtractor()

    private func extract(_ text: String, memoryEnabled: Bool = true, excluded: Set<UUID> = [], conversationID: UUID = UUID()) async -> [MemoryCandidate] {
        await extractor.extract(
            from: PersonalAIExchange(conversationID: conversationID, surface: .personalChat, userText: text),
            existing: [], excludedConversationIDs: excluded, memoryEnabled: memoryEnabled
        )
    }

    @Test("durable self-fact is captured as profile")
    func durableSelfFact() async {
        let c = await extract("By the way, I live in Kyiv and work as an iOS engineer.")
        #expect(c.count == 1)
        #expect(c[0].record.category == .profile)
        #expect(c[0].record.userConfirmed == false)
    }

    @Test("durable project statement is captured as projects")
    func durableProjectFact() async {
        let c = await extract("We decided to move the EvenAI launch to Q4.")
        #expect(c.first?.record.category == .projects)
    }

    @Test("filler and greetings are not captured")
    func fillerRejected() async {
        for filler in ["thanks!", "ok cool", "great, sounds good", "haha nice", "good morning"] {
            #expect(await extract(filler).isEmpty, "captured filler: \(filler)")
        }
    }

    @Test("a plain question is not captured")
    func questionNotCaptured() async {
        #expect(await extract("what's the best way to structure the retrieval scoring?").isEmpty)
    }

    @Test("memory disabled → nothing captured")
    func memoryDisabled() async {
        #expect(await extract("Remember I live in Kyiv.", memoryEnabled: false).isEmpty)
    }

    @Test("excluded conversation → nothing captured")
    func excludedConversation() async {
        let conv = UUID()
        #expect(await extract("Remember I live in Kyiv.", excluded: [conv], conversationID: conv).isEmpty)
    }

    @Test("explicit remember beats passive extraction (no double storage)")
    func explicitNotDoubled() async {
        let c = await extract("Remember that I'm building EvenAI for G2 glasses.")
        #expect(c.count == 1)
        #expect(c[0].rationale.contains("explicit"))
    }

    @Test("canonicalization tidies phrasing without inventing facts")
    func canonicalization() {
        #expect(HeuristicMemoryExtractor.canonicalize("that i prefer tea") == "I prefer tea.")
        #expect(HeuristicMemoryExtractor.canonicalize("EvenAI ships in October") == "EvenAI ships in October.")
    }
}
