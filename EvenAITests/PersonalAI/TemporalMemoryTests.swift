import Testing
import Foundation
@testable import EvenAI

@Suite("Personal AI: temporal memory")
struct TemporalMemoryTests {

    // MARK: Scenario 9 — temporary memory expires

    @Test("'this week' becomes working context with an expiry, not a permanent profile fact")
    func thisWeekIsWorkingContext() async {
        let extractor = HeuristicMemoryExtractor()
        let now = Date()
        let candidates = await extractor.extract(
            from: .user("Remember I'm in Berlin this week for meetings.", at: now),
            existing: [], excludedConversationIDs: [], memoryEnabled: true
        )
        #expect(candidates.count == 1)
        let record = candidates[0].record
        #expect(record.category == .workingContext)
        #expect(record.expiresAt != nil)
        if let expiresAt = record.expiresAt {
            #expect(expiresAt > now)
            #expect(expiresAt < now.addingTimeInterval(60 * 60 * 24 * 14))
        }
    }

    @Test("an expired record is not retrievable and is archived by maintenance")
    func expiredRecordIsArchived() async {
        let past = Date().addingTimeInterval(-60 * 60 * 24 * 30)
        var record = MemoryRecord(category: .workingContext, canonicalContent: "In Berlin this week.", createdAt: past, updatedAt: past)
        record.expiresAt = Date().addingTimeInterval(-60)

        #expect(record.isRetrievable(now: .now) == false)

        let toArchive = MemoryMaintenance.archivingExpired(in: [record])
        #expect(toArchive.count == 1)
        #expect(toArchive[0].status == .archived)
    }

    // MARK: Scenario 25 — expired context never enters the prompt

    @Test("an expired working-context memory never reaches the rendered context")
    func expiredNeverInPrompt() async {
        let store = InMemoryPersonalMemoryStore()
        var expired = MemoryRecord(category: .workingContext, canonicalContent: "I am in Berlin visiting the office.")
        expired.expiresAt = Date().addingTimeInterval(-3600)
        await store.upsert([expired])

        let builder = DefaultPersonalAIContextBuilder(store: store)
        let context = await builder.buildContext(PersonalAIContextRequest(
            surface: .personalChat,
            userMessage: "What's the latest on my Berlin trip and the office?"
        ))
        #expect(context.systemPromptText.localizedCaseInsensitiveContains("Berlin") == false)
        #expect(context.relevantMemories.isEmpty)

        // And it was archived as a side effect.
        let active = await store.memories(matching: MemoryQuery(statuses: [.active]))
        #expect(active.isEmpty)
    }

    @Test("a permanent fact with no horizon phrase stays permanent")
    func permanentStaysPermanent() async {
        let extractor = HeuristicMemoryExtractor()
        let candidates = await extractor.extract(
            from: .user("Remember I live in Kyiv.", at: .now),
            existing: [], excludedConversationIDs: [], memoryEnabled: true
        )
        #expect(candidates.count == 1)
        #expect(candidates[0].record.category == .profile)
        #expect(candidates[0].record.expiresAt == nil)
    }
}
