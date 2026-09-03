import Testing
import Foundation
@testable import EvenAI

@Suite("Personal AI: retrieval relevance")
struct MemoryRetrieverTests {

    private func mem(_ content: String, _ category: MemoryCategory, entities: [String] = [], importance: Double = 0.5, confirmed: Bool = false, updatedAt: Date = .now) -> MemoryRecord {
        MemoryRecord(
            category: category,
            canonicalContent: content,
            entities: entities,
            updatedAt: updatedAt,
            importance: importance,
            userConfirmed: confirmed
        )
    }

    // MARK: Scenario 11 — relevant project memory retrieved

    @Test("an EvenAI question retrieves the EvenAI project memory")
    func projectMemoryRetrieved() {
        let retriever = MemoryRetriever()
        let records = [
            mem("Building EvenAI, a personal AI assistant for Even G2 smart glasses.", .projects, entities: ["evenai", "g2"], importance: 0.8),
            mem("I visited my parents in Lviv last month.", .episodes),
            mem("I prefer espresso to filter coffee.", .preferences),
        ]
        let results = retriever.retrieve(
            RetrievalQuery(text: "I'm having problems with the EvenAI suggested replies", surface: .personalChat),
            from: records
        )
        #expect(results.first?.record.category == .projects)
        #expect(results.contains { $0.record.canonicalContent.contains("EvenAI") })
    }

    // MARK: Scenario 10 & 26 — irrelevant / unrelated memory excluded

    @Test("an unrelated travel memory is excluded from an EvenAI question")
    func irrelevantExcluded() {
        let retriever = MemoryRetriever()
        let records = [
            mem("Building EvenAI for Even G2 smart glasses.", .projects, entities: ["evenai", "g2"], importance: 0.8),
            mem("I'm spending this week in Berlin visiting friends.", .workingContext, importance: 0.9),
        ]
        let results = retriever.retrieve(
            RetrievalQuery(text: "Why are the EvenAI suggested replies failing on device?", surface: .personalChat),
            from: records
        )
        #expect(results.contains { $0.record.canonicalContent.contains("Berlin") } == false)
    }

    @Test("a second, unrelated project does not pollute the first project's retrieval")
    func unrelatedProjectExcluded() {
        let retriever = MemoryRetriever()
        let records = [
            mem("Project EvenAI: an assistant for Even G2 glasses.", .projects, entities: ["evenai", "g2"]),
            mem("Project Garden: rebuilding the back deck and planting beds this spring.", .projects, entities: ["garden", "deck"]),
        ]
        let results = retriever.retrieve(
            RetrievalQuery(text: "What did we decide about the EvenAI launch date?", surface: .personalChat, projectHints: ["evenai"]),
            from: records
        )
        #expect(results.contains { $0.record.canonicalContent.contains("EvenAI") })
        #expect(results.contains { $0.record.canonicalContent.contains("Garden") } == false)
    }

    // MARK: Scenario 12 — relevant person memory retrieved

    @Test("a question mentioning a person retrieves that person's memory")
    func personMemoryRetrieved() {
        let retriever = MemoryRetriever()
        let records = [
            mem("Andrii is my co-founder and handles the backend.", .people, entities: ["andrii"]),
            mem("Marta runs our design work.", .people, entities: ["marta"]),
        ]
        let results = retriever.retrieve(
            RetrievalQuery(text: "Can you draft a message to Andrii about the API change?", surface: .personalChat, personHints: ["andrii"]),
            from: records
        )
        #expect(results.first?.record.canonicalContent.contains("Andrii") == true)
        #expect(results.contains { $0.record.canonicalContent.contains("Marta") } == false)
    }

    // MARK: Scenario 13 — relevant historical conversation retrieved

    @Test("an archived conversation excerpt is retrieved when topically relevant")
    func historicalConversationRetrieved() {
        let retriever = MemoryRetriever()
        let records = [
            mem("Discussed the STT reconnect bug and the bounded-retry fix.", .conversationArchive, entities: ["stt", "reconnect"]),
            mem("Chatted about weekend plans.", .conversationArchive),
        ]
        let results = retriever.retrieve(
            RetrievalQuery(text: "The STT reconnect issue is back — any ideas?", surface: .personalChat),
            from: records
        )
        #expect(results.first?.record.canonicalContent.contains("reconnect") == true)
    }

    @Test("nothing is returned when nothing is topically connected")
    func nothingConnectedReturnsEmpty() {
        let retriever = MemoryRetriever()
        let records = [
            mem("I prefer tea.", .preferences, importance: 1.0, confirmed: true),
            mem("My birthday is in May.", .profile, importance: 1.0, confirmed: true),
        ]
        let results = retriever.retrieve(
            RetrievalQuery(text: "Explain how WebSockets handle backpressure.", surface: .personalChat),
            from: records
        )
        #expect(results.isEmpty)
    }

    // MARK: Slice 1 — the cross-lingual semantic blend (additive)

    @Test("passing `semantic: nil` is byte-identical to the no-argument call")
    func semanticNilIsIdentity() {
        let retriever = MemoryRetriever()
        let records = [
            mem("Building EvenAI for Even G2 smart glasses.", .projects, entities: ["evenai", "g2"], importance: 0.8),
            mem("I visited Lviv last month.", .episodes),
        ]
        let query = RetrievalQuery(text: "How's the EvenAI build going?", surface: .personalChat)
        let a = retriever.retrieve(query, from: records)
        let b = retriever.retrieve(query, from: records, semantic: nil)
        #expect(a.map(\.id) == b.map(\.id))
        #expect(a.map(\.score) == b.map(\.score))
    }

    @Test("a semantic vector match rescues a record with zero lexical overlap")
    func semanticRescuesZeroLexicalOverlap() {
        let retriever = MemoryRetriever()
        let record = mem("Prefers espresso without sugar.", .preferences)
        // No shared tokens → lexically dropped today.
        let query = RetrievalQuery(text: "Яку каву мені замовити?", surface: .personalChat)
        #expect(retriever.retrieve(query, from: [record]).isEmpty)

        // With near-parallel vectors the record is retrieved.
        let sem = MemoryRetriever.SemanticContext(
            queryVector: [1, 0, 0],
            recordVectors: [record.id: [0.98, 0.02, 0]]
        )
        let rescued = retriever.retrieve(query, from: [record], semantic: sem)
        #expect(rescued.contains { $0.record.id == record.id })
    }

    @Test("an orthogonal semantic vector adds nothing — still dropped")
    func orthogonalSemanticIsInert() {
        let retriever = MemoryRetriever()
        let record = mem("Prefers espresso without sugar.", .preferences)
        let query = RetrievalQuery(text: "Яку каву мені замовити?", surface: .personalChat)
        let sem = MemoryRetriever.SemanticContext(
            queryVector: [1, 0, 0],
            recordVectors: [record.id: [0, 1, 0]]
        )
        #expect(retriever.retrieve(query, from: [record], semantic: sem).isEmpty)
    }

    @Test("a near-exact lexical match still outranks a semantic-only match (weight < 1 keeps the ceiling)")
    func lexicalMatchOutranksSemanticOnly() {
        let retriever = MemoryRetriever()
        let queryText = "The suggested replies keep failing on device."
        let strong = mem(queryText, .knowledge)                       // lexically identical to the query
        let weak = mem("Prefers espresso without sugar.", .preferences) // unrelated, but given a perfect vector
        let query = RetrievalQuery(text: queryText, surface: .personalChat)
        let sem = MemoryRetriever.SemanticContext(
            queryVector: [1, 0],
            recordVectors: [weak.id: [1, 0]]
        )
        let results = retriever.retrieve(query, from: [strong, weak], semantic: sem)
        #expect(results.first?.record.id == strong.id)
    }
}
