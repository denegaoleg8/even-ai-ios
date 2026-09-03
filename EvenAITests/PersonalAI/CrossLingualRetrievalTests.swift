import Testing
import Foundation
@testable import EvenAI

/// Slice 1 — **ARCHITECTURAL** cross-lingual retrieval tests.
///
/// These prove the *pipeline* — embed the query → blend a semantic score
/// into `MemoryRetriever` → rank → filter → render — behaves correctly when
/// a `SemanticMemoryScoring` says two phrases are equivalent. The
/// equivalence is declared per-test via `ScriptedSemanticScorer` groups; no
/// language dictionary lives in production.
///
/// The real EN↔UK↔DE↔PL acceptance (a real on-device multilingual encoder
/// actually producing near-parallel vectors for translated phrases) is a
/// LATER SLICE. Nothing here asserts that the shipping app does cross-lingual
/// retrieval yet — production is wired with `NoSemanticScorer` and stays
/// lexical.
@Suite("Personal AI: cross-lingual retrieval — architecture (scripted scorer)")
struct CrossLingualRetrievalTests {

    // MARK: helpers

    private func freshIndex() throws -> EmbeddingVectorIndex {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return EmbeddingVectorIndex(directory: dir)
    }

    private func builder(
        store: InMemoryPersonalMemoryStore,
        scorer: any SemanticMemoryScoring,
        index: EmbeddingVectorIndex
    ) -> DefaultPersonalAIContextBuilder {
        DefaultPersonalAIContextBuilder(store: store, semanticScorer: scorer, vectorIndex: index)
    }

    private func seeded(_ records: MemoryRecord...) async -> InMemoryPersonalMemoryStore {
        let store = InMemoryPersonalMemoryStore()
        await store.upsert(records)
        return store
    }

    private func mem(_ content: String, _ category: MemoryCategory = .preferences) -> MemoryRecord {
        MemoryRecord(category: category, canonicalContent: content, importance: 0.5)
    }

    private func ctx(_ builder: DefaultPersonalAIContextBuilder, _ query: String, surface: PersonalAISurface = .personalChat) async -> PersonalAIContext {
        await builder.buildContext(PersonalAIContextRequest(surface: surface, userMessage: query))
    }

    private func retrieved(_ c: PersonalAIContext, contains needle: String) -> Bool {
        c.relevantMemories.contains { $0.canonicalContent.localizedCaseInsensitiveContains(needle) }
    }

    // A coffee-preference concept expressed across four languages, plus the
    // stored memory phrasings, all declared equivalent for the test.
    private func coffeeGroup(_ extra: String...) -> [[String]] {
        [[
            "Prefers espresso without sugar.",
            "Віддає перевагу еспресо без цукру.",
            "Яку каву мені замовити?",
            "What coffee should I order?",
            "Welchen Kaffee soll ich bestellen?",
            "Jaką kawę mam zamówić?",
        ] + extra]
    }

    // MARK: 1 — same-language lexical still works (semantic layer present)

    @Test("1: Ukrainian memory → Ukrainian query still retrieves (lexical, unchanged)")
    func ukToUk() async throws {
        let store = await seeded(mem("Віддає перевагу еспресо без цукру."))
        let c = await ctx(builder(store: store, scorer: ScriptedSemanticScorer(groups: coffeeGroup()), index: try freshIndex()),
                          "Розкажи більше про мою каву та еспресо.")
        #expect(retrieved(c, contains: "еспресо"))
    }

    // MARK: 2–7 — cross-language rescue via the semantic layer

    @Test("2: Ukrainian memory → English query (semantic rescue)")
    func ukMemoryEnQuery() async throws {
        let store = await seeded(mem("Віддає перевагу еспресо без цукру."))
        let c = await ctx(builder(store: store, scorer: ScriptedSemanticScorer(groups: coffeeGroup()), index: try freshIndex()),
                          "What coffee should I order?")
        #expect(retrieved(c, contains: "еспресо"))
    }

    @Test("3: Ukrainian memory → German query (semantic rescue)")
    func ukMemoryDeQuery() async throws {
        let store = await seeded(mem("Віддає перевагу еспресо без цукру."))
        let c = await ctx(builder(store: store, scorer: ScriptedSemanticScorer(groups: coffeeGroup()), index: try freshIndex()),
                          "Welchen Kaffee soll ich bestellen?")
        #expect(retrieved(c, contains: "еспресо"))
    }

    @Test("4: Ukrainian memory → Polish query (semantic rescue)")
    func ukMemoryPlQuery() async throws {
        let store = await seeded(mem("Віддає перевагу еспресо без цукру."))
        let c = await ctx(builder(store: store, scorer: ScriptedSemanticScorer(groups: coffeeGroup()), index: try freshIndex()),
                          "Jaką kawę mam zamówić?")
        #expect(retrieved(c, contains: "еспресо"))
    }

    @Test("5: English memory → Ukrainian query (semantic rescue)")
    func enMemoryUkQuery() async throws {
        let store = await seeded(mem("Prefers espresso without sugar."))
        let c = await ctx(builder(store: store, scorer: ScriptedSemanticScorer(groups: coffeeGroup()), index: try freshIndex()),
                          "Яку каву мені замовити?")
        #expect(retrieved(c, contains: "espresso"))
    }

    @Test("6: German memory → English query (semantic rescue)")
    func deMemoryEnQuery() async throws {
        let groups = [[
            "Bevorzugt Espresso ohne Zucker.",
            "What coffee should I order?",
            "Prefers espresso without sugar.",
        ]]
        let store = await seeded(mem("Bevorzugt Espresso ohne Zucker."))
        let c = await ctx(builder(store: store, scorer: ScriptedSemanticScorer(groups: groups), index: try freshIndex()),
                          "What coffee should I order?")
        #expect(retrieved(c, contains: "Espresso"))
    }

    @Test("7: Polish memory → Ukrainian query (semantic rescue)")
    func plMemoryUkQuery() async throws {
        let groups = [[
            "Woli espresso bez cukru.",
            "Яку каву мені замовити?",
        ]]
        let store = await seeded(mem("Woli espresso bez cukru."))
        let c = await ctx(builder(store: store, scorer: ScriptedSemanticScorer(groups: groups), index: try freshIndex()),
                          "Яку каву мені замовити?")
        #expect(retrieved(c, contains: "espresso"))
    }

    // MARK: 8 — unrelated cross-language memory is NOT selected

    @Test("8: an unrelated memory in another language is not pulled in")
    func unrelatedNotSelected() async throws {
        let groups = [
            ["Prefers espresso without sugar.", "What coffee should I order?"],
            ["Мій собака любить гуляти вранці."],   // a different concept, its own group
        ]
        let store = await seeded(
            mem("Prefers espresso without sugar."),
            mem("Мій собака любить гуляти вранці.")
        )
        let c = await ctx(builder(store: store, scorer: ScriptedSemanticScorer(groups: groups), index: try freshIndex()),
                          "What coffee should I order?")
        #expect(retrieved(c, contains: "espresso"))
        #expect(retrieved(c, contains: "собака") == false)
    }

    // MARK: 9 — the relevant memory ranks first among several

    @Test("9: the semantically-matching memory ranks ahead of unrelated ones")
    func relevantRanksFirst() async throws {
        let groups = [
            ["Prefers espresso without sugar.", "What coffee should I order?"],
            ["Runs 10k every Sunday morning."],
            ["Reads two books a month."],
        ]
        let store = await seeded(
            mem("Runs 10k every Sunday morning."),
            mem("Prefers espresso without sugar."),
            mem("Reads two books a month.")
        )
        let c = await ctx(builder(store: store, scorer: ScriptedSemanticScorer(groups: groups), index: try freshIndex()),
                          "What coffee should I order?")
        #expect(c.relevantMemories.first?.canonicalContent.localizedCaseInsensitiveContains("espresso") == true)
    }

    // MARK: 10 — priority: an active rule still outranks retrieved memory

    @Test("10: a standing rule is rendered above semantically-retrieved memory")
    func rulePriorityPreserved() async throws {
        let store = InMemoryPersonalMemoryStore()
        await store.upsert([mem("Prefers espresso without sugar.")])
        await store.upsertRule(Rule(text: "Always confirm the order total before sending.", priority: .activeRule))
        let c = await ctx(builder(store: store, scorer: ScriptedSemanticScorer(groups: coffeeGroup()), index: try freshIndex()),
                          "What coffee should I order?")
        #expect(retrieved(c, contains: "espresso"))
        let rulePos = c.systemPromptText.range(of: "confirm the order total")
        let memPos = c.systemPromptText.range(of: "espresso without sugar")
        #expect(rulePos != nil && memPos != nil)
        if let rulePos, let memPos { #expect(rulePos.lowerBound < memPos.lowerBound) }
    }

    // MARK: 11 — memory disabled → NO semantic retrieval

    @Test("11: memory disabled globally → the query is never embedded")
    func memoryDisabledNoEmbed() async throws {
        let store = await seeded(mem("Prefers espresso without sugar."))
        await store.setMemoryEnabledGlobally(false)
        let scorer = ScriptedSemanticScorer(groups: coffeeGroup())
        let c = await ctx(builder(store: store, scorer: scorer, index: try freshIndex()), "What coffee should I order?")
        #expect(c.memoryDisabled)
        #expect(c.relevantMemories.isEmpty)
        #expect(await scorer.embedCallCount == 0)
    }

    // MARK: 12 — tombstoned memory never returned

    @Test("12: a deleted memory is not retrieved and not embedded")
    func tombstonedExcluded() async throws {
        let store = InMemoryPersonalMemoryStore()
        let record = mem("Prefers espresso without sugar.")
        await store.upsert([record])
        await store.setMemoryStatus(id: record.id, status: .deleted)
        let scorer = ScriptedSemanticScorer(groups: coffeeGroup())
        let c = await ctx(builder(store: store, scorer: scorer, index: try freshIndex()), "What coffee should I order?")
        #expect(c.relevantMemories.isEmpty)
        #expect(await scorer.embeddedTexts.contains(record.canonicalContent) == false)
    }

    // MARK: 13 — user isolation (per-owner store + per-owner index)

    @Test("13: owner B's builder cannot surface owner A's memory")
    func userIsolation() async throws {
        let groups = coffeeGroup()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("clr-iso-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let storeA = await seeded(mem("Prefers espresso without sugar."))
        let cA = await ctx(builder(store: storeA, scorer: ScriptedSemanticScorer(groups: groups),
                                   index: EmbeddingVectorIndex(directory: dir, ownerID: "A")),
                           "What coffee should I order?")
        #expect(retrieved(cA, contains: "espresso"))

        let storeB = InMemoryPersonalMemoryStore()   // B has no such memory
        let cB = await ctx(builder(store: storeB, scorer: ScriptedSemanticScorer(groups: groups),
                                   index: EmbeddingVectorIndex(directory: dir, ownerID: "B")),
                           "What coffee should I order?")
        #expect(cB.relevantMemories.isEmpty)
    }

    // MARK: 14 — semantic layer inert → lexical fallback intact

    @Test("14: NoSemanticScorer → cross-language query does NOT retrieve (lexical only, as today)")
    func inertScorerLexicalOnly() async throws {
        let store = await seeded(mem("Віддає перевагу еспресо без цукру."))
        let c = await ctx(builder(store: store, scorer: NoSemanticScorer(), index: try freshIndex()),
                          "What coffee should I order?")
        #expect(c.relevantMemories.isEmpty)   // no shared tokens, no semantic layer → nothing (unchanged behaviour)

        // …and same-language lexical still works with the inert scorer.
        let c2 = await ctx(builder(store: store, scorer: NoSemanticScorer(), index: try freshIndex()),
                           "Нагадай про мою каву та еспресо.")
        #expect(retrieved(c2, contains: "еспресо"))
    }

    // MARK: 15 — semantic failure / timeout → safe lexical fallback

    @Test("15: a throwing scorer → buildContext still returns, lexical result intact")
    func throwingScorerFallsBack() async throws {
        let store = await seeded(mem("Віддає перевагу еспресо без цукру."))
        let scorer = ScriptedSemanticScorer(groups: coffeeGroup(), failure: ScriptedSemanticScorerError())
        let c = await ctx(builder(store: store, scorer: scorer, index: try freshIndex()),
                          "Нагадай про мою каву та еспресо.")
        #expect(retrieved(c, contains: "еспресо"))   // lexical still works
    }

    @Test("15b: a hung scorer → builder times out and returns lexical result quickly")
    func hungScorerTimesOut() async throws {
        let store = await seeded(mem("Нагадування: моя кава — це еспресо."))
        let scorer = ScriptedSemanticScorer(groups: coffeeGroup(), delay: .seconds(30))
        let started = Date()
        let c = await ctx(builder(store: store, scorer: scorer, index: try freshIndex()),
                          "Розкажи про мою каву та еспресо.")
        #expect(Date().timeIntervalSince(started) < 6)   // did NOT wait 30s
        #expect(retrieved(c, contains: "еспресо"))
    }

    // MARK: 16 — query in a language the scorer doesn't map → safe

    @Test("16: an unmapped query produces no semantic hit and does not crash")
    func unmappedQuerySafe() async throws {
        let store = await seeded(mem("Prefers espresso without sugar."))
        let scorer = ScriptedSemanticScorer(groups: [["Prefers espresso without sugar."]])  // query not in any group
        let c = await ctx(builder(store: store, scorer: scorer, index: try freshIndex()),
                          "Karibihira nink'ivyo nokwitura?")   // unmapped
        #expect(c.relevantMemories.isEmpty)   // no lexical overlap, no semantic hit
    }

    // MARK: 18 — the G2 surface goes through the same builder

    @Test("18: cross-lingual rescue also works on the .g2Replies surface")
    func g2SurfaceCrossLingual() async throws {
        let store = await seeded(mem("Віддає перевагу еспресо без цукру.", .preferences))
        let c = await ctx(builder(store: store, scorer: ScriptedSemanticScorer(groups: coffeeGroup()), index: try freshIndex()),
                          "What coffee should I order?", surface: .g2Replies)
        #expect(retrieved(c, contains: "еспресо"))
    }
}
