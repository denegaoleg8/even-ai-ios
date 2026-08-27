import Testing
import Foundation
@testable import EvenAI

@Suite("Personal AI: memory merging & provenance")
struct MemoryMergerTests {

    private func record(_ content: String, category: MemoryCategory = .projects, conv: UUID = UUID(), msg: UUID = UUID(), confidence: Double = 0.6) -> MemoryRecord {
        MemoryRecord(
            category: category,
            canonicalContent: content,
            entities: HeuristicMemoryExtractor.entities(in: content),
            confidence: confidence,
            sourceConversationIDs: [conv],
            sourceMessageIDs: [msg]
        )
    }

    // MARK: Scenario 6 — duplicate memories merge

    @Test("a near-identical memory is treated as a duplicate, not inserted twice")
    func duplicatesMerge() {
        let merger = MemoryMerger()
        let existing = record("The EvenAI launch is planned for October 2026.")
        let candidate = MemoryCandidate(
            record: record("EvenAI launch planned for October 2026"),
            rationale: "restated"
        )
        let decision = merger.reconcile(candidate: candidate, against: [existing])
        guard case let .duplicate(existingID, refreshed) = decision else {
            Issue.record("expected .duplicate, got \(decision)")
            return
        }
        #expect(existingID == existing.id)
        // Provenance from both is retained.
        #expect(Set(refreshed.sourceConversationIDs).isSuperset(of: existing.sourceConversationIDs))
        #expect(Set(refreshed.sourceConversationIDs).isSuperset(of: candidate.record.sourceConversationIDs))
    }

    // MARK: Scenario 7 — contradictory project info updates correctly

    @Test("a rescheduled launch supersedes the old date, never two active facts")
    func contradictionSupersedes() {
        let merger = MemoryMerger()
        let old = record("The EvenAI launch is planned for September 2026.")
        let candidate = MemoryCandidate(
            record: record("The EvenAI launch has moved to October 2026."),
            rationale: "update"
        )
        let decision = merger.reconcile(candidate: candidate, against: [old])
        guard case let .supersede(supersededID, newRecord) = decision else {
            Issue.record("expected .supersede, got \(decision)")
            return
        }
        #expect(supersededID == old.id)
        #expect(newRecord.supersedesID == old.id)
        #expect(newRecord.canonicalContent.localizedCaseInsensitiveContains("October"))
    }

    @Test("applying a supersede through the store leaves exactly one active record")
    func supersedeAppliedLeavesOneActive() async {
        let store = InMemoryPersonalMemoryStore()
        let processor = MemoryCommandProcessor()
        _ = await processor.process(message: "Remember the EvenAI launch is planned for September.", conversationID: UUID(), messageID: UUID(), store: store)
        _ = await processor.process(message: "Remember the EvenAI launch moved to October.", conversationID: UUID(), messageID: UUID(), store: store)

        let active = await store.memories(matching: MemoryQuery(statuses: [.active]))
        #expect(active.count == 1)
        #expect(active[0].canonicalContent.localizedCaseInsensitiveContains("October"))

        let superseded = await store.memories(matching: MemoryQuery(statuses: [.superseded]))
        #expect(superseded.count == 1)
        #expect(superseded[0].supersededByID == active[0].id)
    }

    // MARK: Scenario 8 — provenance preserved

    @Test("merge unions source conversation and message ids")
    func provenancePreserved() {
        let merger = MemoryMerger()
        let convA = UUID(), msgA = UUID(), convB = UUID(), msgB = UUID()
        let old = record("The team stand-up is at 10am.", category: .knowledge, conv: convA, msg: msgA)
        let candidate = MemoryCandidate(
            record: record("Actually the team stand-up moved to 11am.", category: .knowledge, conv: convB, msg: msgB),
            rationale: "update"
        )
        let decision = merger.reconcile(candidate: candidate, against: [old])
        guard case let .supersede(_, newRecord) = decision else {
            Issue.record("expected .supersede, got \(decision)")
            return
        }
        #expect(Set(newRecord.sourceConversationIDs) == Set([convA, convB]))
        #expect(Set(newRecord.sourceMessageIDs) == Set([msgA, msgB]))
    }

    @Test("a genuinely new, unrelated memory is just created")
    func unrelatedIsCreated() {
        let merger = MemoryMerger()
        let existing = record("The EvenAI launch is in October.")
        let candidate = MemoryCandidate(record: record("I prefer working in the mornings.", category: .preferences), rationale: "new")
        guard case .create = merger.reconcile(candidate: candidate, against: [existing]) else {
            Issue.record("expected .create")
            return
        }
    }
}
