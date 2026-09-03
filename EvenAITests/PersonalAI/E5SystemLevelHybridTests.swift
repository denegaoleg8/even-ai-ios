import Testing
import Foundation
@testable import EvenAI

/// Prompt 2B-ii — **system-level** hybrid gate (§24.5).
///
/// Drives the *real* `MemoryRetriever` → `DefaultPersonalAIContextBuilder` →
/// `PersonalAIContextRenderer` pipeline with **real** `multilingual-e5-small`
/// vectors (`E5Fixtures`, rev `614241f…`), and asks the question that matters:
/// **does the complete Personal AI context improve for cross-lingual queries,
/// without breaking existing behaviour?** — not "is cosine high".
///
/// Device-independent: no Core ML model, no Swift tokenizer, no shipping change.
@MainActor
@Suite("Prompt 2B-ii: E5 system-level hybrid retrieval")
struct E5SystemLevelHybridTests {

    // MARK: fixtures → store

    private func category(_ s: String) -> MemoryCategory {
        switch s {
        case "PREF": return .preferences
        case "PROFILE": return .profile
        case "PROJECT": return .projects
        case "PEOPLE": return .people
        case "STYLE": return .style
        default: return .knowledge
        }
    }

    private func seededStore() async -> InMemoryPersonalMemoryStore {
        let store = InMemoryPersonalMemoryStore()
        var records: [MemoryRecord] = []
        for (text, cat) in E5Fixtures.memories {
            records.append(MemoryRecord(category: category(cat), canonicalContent: text, importance: 0.5))
        }
        await store.upsert(records)
        return store
    }

    private func freshIndex() throws -> EmbeddingVectorIndex {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("e5sys-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return EmbeddingVectorIndex(directory: dir)
    }

    private func lexicalBuilder(_ store: InMemoryPersonalMemoryStore) -> DefaultPersonalAIContextBuilder {
        DefaultPersonalAIContextBuilder(store: store)
    }

    private func hybridBuilder(
        _ store: InMemoryPersonalMemoryStore,
        scorer: PrecomputedEmbeddingScorer? = nil,
        index: EmbeddingVectorIndex? = nil
    ) throws -> DefaultPersonalAIContextBuilder {
        DefaultPersonalAIContextBuilder(
            store: store,
            semanticScorer: scorer ?? PrecomputedEmbeddingScorer(),
            vectorIndex: try (index ?? freshIndex())
        )
    }

    private func retrieved(_ c: PersonalAIContext, _ text: String) -> Bool {
        c.relevantMemories.contains { $0.canonicalContent == text }
        || c.relevantProjects.contains { $0.canonicalContent == text }
        || c.relevantPeople.contains { $0.canonicalContent == text }
    }

    private func ctx(_ b: DefaultPersonalAIContextBuilder, _ q: String, surface: PersonalAISurface = .personalChat) async -> PersonalAIContext {
        await b.buildContext(PersonalAIContextRequest(surface: surface, userMessage: q))
    }

    // MARK: A — lexical-only vs hybrid recall over the labelled multilingual set

    @Test("hybrid materially improves cross-lingual recall into the built context; no same-language regression")
    func lexicalVsHybridRecall() async throws {
        let store = await seededStore()
        let lex = lexicalBuilder(store)
        let hyb = try hybridBuilder(store)

        var lexHit = 0, hybHit = 0
        var lexCross = 0, hybCross = 0, crossTotal = 0
        var lexSame = 0, hybSame = 0, sameTotal = 0

        for q in E5Fixtures.labelledQueries {
            let target = E5Fixtures.memories[q.target].text
            let l = retrieved(await ctx(lex, q.query), target)
            let h = retrieved(await ctx(hyb, q.query), target)
            lexHit += l ? 1 : 0
            hybHit += h ? 1 : 0
            let sameLang = q.direction.split(separator: ">").first == q.direction.split(separator: ">").last
            if sameLang {
                sameTotal += 1; lexSame += l ? 1 : 0; hybSame += h ? 1 : 0
            } else {
                crossTotal += 1; lexCross += l ? 1 : 0; hybCross += h ? 1 : 0
            }
        }

        let n = E5Fixtures.labelledQueries.count
        print("[2B-ii] RECALL into context — lexical \(lexHit)/\(n), hybrid \(hybHit)/\(n)  |  cross-lingual lexical \(lexCross)/\(crossTotal), hybrid \(hybCross)/\(crossTotal)  |  same-language lexical \(lexSame)/\(sameTotal), hybrid \(hybSame)/\(sameTotal)")

        #expect(hybHit >= lexHit)                         // never worse overall
        #expect(hybCross > lexCross)                      // materially better cross-lingual
        #expect(hybSame >= lexSame)                       // no same-language regression
    }

    // MARK: B — coffee system-level acceptance (§15), all four languages

    @Test("coffee: hybrid surfaces the espresso preference where lexical-only fails, in all four languages")
    func coffeeSystemLevel() async throws {
        let store = await seededStore()
        let lex = lexicalBuilder(store)
        let hyb = try hybridBuilder(store)
        let target = "Я віддаю перевагу еспресо без цукру."

        for q in ["What coffee should I order?", "Welchen Kaffee soll ich bestellen?",
                  "Jaką kawę mam zamówić?", "Яку каву мені замовити?"] {
            let l = retrieved(await ctx(lex, q), target)
            let hc = await ctx(hyb, q)
            let h = retrieved(hc, target)
            print("[2B-ii] coffee \"\(q)\": lexical=\(l)  hybrid=\(h)  inPrompt=\(hc.systemPromptText.contains("еспресо"))")
            #expect(h, "hybrid must surface the espresso preference for: \(q)")
        }
    }

    // MARK: C — hard-negative containment (§14-D)

    @Test("hybrid does not flood the retrieved set with unrelated memories for a coffee query")
    func hardNegativeContainment() async throws {
        let store = await seededStore()
        let hyb = try hybridBuilder(store)
        // memories that are NOT plausibly coffee/beverage/preference related
        let unrelated: Set<String> = [
            "Marta leads the design team.",
            "Ma dwoje dzieci i mieszka pod Krakowem.",
            "Дедлайн релізу застосунку — кінець жовтня.",
            "Grew up in Lviv; speaks Ukrainian, English and German.",
            "Tomasz jest mentorem i doradza w sprawach kariery.",
            "Arbeitet remote und beginnt den Tag um 7 Uhr.",
        ]
        let c = await ctx(hyb, "What coffee should I order?")
        let all = c.relevantMemories.map(\.canonicalContent) + c.relevantProjects.map(\.canonicalContent) + c.relevantPeople.map(\.canonicalContent)
        let flooded = all.filter { unrelated.contains($0) }.count
        print("[2B-ii] coffee query retrieved \(all.count) memories; unrelated among them: \(flooded)  (\(all))")
        #expect(flooded <= 2)
    }

    // MARK: D — fail-open (§16)

    @Test("scorer throws → hybrid context == lexical context")
    func fallbackScorerThrows() async throws {
        let store = await seededStore()
        let lex = lexicalBuilder(store)
        let hyb = try hybridBuilder(store, scorer: PrecomputedEmbeddingScorer(failure: PrecomputedEmbeddingScorerError()))
        for q in ["What coffee should I order?", "Any food allergies I should know about?"] {
            let l = await ctx(lex, q); let h = await ctx(hyb, q)
            #expect(Set(h.relevantMemories.map(\.id)) == Set(l.relevantMemories.map(\.id)))
        }
    }

    @Test("scorer far slower than the 2 s builder budget → hybrid times out to lexical, quickly")
    func fallbackScorerTimeout() async throws {
        let store = await seededStore()
        let lex = lexicalBuilder(store)
        let hyb = try hybridBuilder(store, scorer: PrecomputedEmbeddingScorer(delay: .seconds(30)))
        let started = Date()
        let h = await ctx(hyb, "What coffee should I order?")
        #expect(Date().timeIntervalSince(started) < 6)
        let l = await ctx(lex, "What coffee should I order?")
        #expect(Set(h.relevantMemories.map(\.id)) == Set(l.relevantMemories.map(\.id)))
    }

    @Test("no scorer wired → identical to lexical")
    func fallbackNoScorer() async throws {
        let store = await seededStore()
        let l = await ctx(lexicalBuilder(store), "What coffee should I order?")
        let h = await ctx(DefaultPersonalAIContextBuilder(store: store), "What coffee should I order?")
        #expect(Set(h.relevantMemories.map(\.id)) == Set(l.relevantMemories.map(\.id)))
    }

    // MARK: E — memory-off (§17)

    @Test("memory disabled globally → no semantic embedding, no retrieved memory")
    func memoryOff() async throws {
        let store = await seededStore()
        await store.setMemoryEnabledGlobally(false)
        let scorer = PrecomputedEmbeddingScorer()
        let hyb = try hybridBuilder(store, scorer: scorer)
        let c = await ctx(hyb, "What coffee should I order?")
        #expect(c.memoryDisabled)
        #expect(c.relevantMemories.isEmpty)
        #expect(await scorer.embedCallCount == 0)
        #expect(c.systemPromptText.contains("еспресо") == false)
    }

    // MARK: F — tombstone (§18)

    @Test("a deleted memory is never surfaced even with a perfect semantic match")
    func tombstoneWins() async throws {
        let store = InMemoryPersonalMemoryStore()
        let target = "Я віддаю перевагу еспресо без цукру."
        let rec = MemoryRecord(category: .preferences, canonicalContent: target, importance: 0.5)
        await store.upsert([rec])
        await store.setMemoryStatus(id: rec.id, status: .deleted)
        let scorer = PrecomputedEmbeddingScorer()
        let hyb = try hybridBuilder(store, scorer: scorer)
        let c = await ctx(hyb, "What coffee should I order?")
        #expect(c.relevantMemories.isEmpty)
        #expect(await scorer.embeddedTexts.contains(target) == false)
    }

    // MARK: G — owner isolation (§18)

    @Test("owner B's build cannot surface owner A's memory via semantic relevance")
    func ownerIsolation() async throws {
        let target = "Я віддаю перевагу еспресо без цукру."
        let storeA = InMemoryPersonalMemoryStore()
        await storeA.upsert([MemoryRecord(category: .preferences, canonicalContent: target, importance: 0.5)])
        let a = try hybridBuilder(storeA, index: EmbeddingVectorIndex(directory: try dir(), ownerID: "A"))
        #expect(retrieved(await ctx(a, "What coffee should I order?"), target))

        let storeB = InMemoryPersonalMemoryStore()   // B has no such memory
        let b = try hybridBuilder(storeB, index: EmbeddingVectorIndex(directory: try dir(), ownerID: "B"))
        #expect((await ctx(b, "What coffee should I order?")).relevantMemories.isEmpty)
    }

    private func dir() throws -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("e5iso-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
}
