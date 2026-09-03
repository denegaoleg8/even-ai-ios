import Testing
import Foundation
@testable import EvenAI

/// Regression for the real failure: a Ukrainian-stored profile fact
/// ("Мене звати Олег") could not be recalled by an English question
/// ("What is my name?") — the `.profile` record was dropped by retrieval's
/// topical-connection gate, so it never reached the Personal AI context, so
/// the local model produced a generic greeting.
///
/// The fix is deterministic and needs **no semantic model** — every test
/// here runs with the shipping lexical-only builder (`NoSemanticScorer`
/// equivalent: no scorer wired).
@MainActor
@Suite("Personal AI: profile-fact answers (no semantic model)")
struct ProfileMemoryAnswerTests {

    // MARK: helpers

    private let heuristic = HeuristicPersonalAIModelProvider()

    private func store(_ facts: (String, MemoryCategory)...) async -> InMemoryPersonalMemoryStore {
        let s = InMemoryPersonalMemoryStore()
        await s.upsert(facts.map { MemoryRecord(category: $0.1, canonicalContent: $0.0, importance: 0.65, userConfirmed: false) })
        return s
    }

    private func lexicalBuilder(_ s: any PersonalMemoryStore) -> DefaultPersonalAIContextBuilder {
        DefaultPersonalAIContextBuilder(store: s)   // no semantic scorer — shipping mode
    }

    private func context(_ b: DefaultPersonalAIContextBuilder, _ q: String) async -> PersonalAIContext {
        await b.buildContext(PersonalAIContextRequest(surface: .personalChat, userMessage: q))
    }

    private func hasFact(_ c: PersonalAIContext, _ text: String) -> Bool {
        c.relevantMemories.contains { $0.canonicalContent == text }
    }

    private func reply(_ c: PersonalAIContext, _ q: String) async throws -> String {
        try await heuristic.generate(PersonalAIGenerationRequest(personalContext: c, messages: [], userMessage: q)).text
    }

    // MARK: - the exact reported failure

    @Test("stored \"Мене звати Олег\" → \"What is my name?\" reaches context and the local reply names Oleg")
    func realFailureRegression() async throws {
        // 1. extraction classifies it as a profile fact
        let extractor = HeuristicMemoryExtractor()
        let candidates = await extractor.extract(
            from: PersonalAIExchange(conversationID: UUID(), surface: .personalChat, userText: "Мене звати Олег"),
            existing: [], excludedConversationIDs: [], memoryEnabled: true
        )
        #expect(candidates.first?.record.category == .profile)
        let canonical = candidates.first!.record.canonicalContent   // "Мене звати Олег."

        // 2. persisted + survives reload
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("profile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let write = LocalPersonalMemoryStore(directory: dir)
        await write.upsert([candidates.first!.record])
        let reloaded = LocalPersonalMemoryStore(directory: dir)
        let persisted = await reloaded.allMemories()
        #expect(persisted.count == 1)
        #expect(persisted[0].category == .profile)
        #expect(persisted[0].canonicalContent == canonical)

        // 3. retrieval + context builder include it (lexical-only, no scorer)
        let c = await context(lexicalBuilder(reloaded), "What is my name?")
        #expect(hasFact(c, canonical))
        #expect(c.systemPromptText.contains("Олег"))

        // 4. the local heuristic reply answers with the name
        let r = try await reply(c, "What is my name?")
        #expect(r.localizedCaseInsensitiveContains("Олег"))
        #expect(r.localizedCaseInsensitiveContains("break it into") == false)   // not the generic template
    }

    // MARK: - cross-language matrix (§6): UK fact, questions in 4 languages

    @Test("Ukrainian name fact answers name questions in UK / EN / DE / PL")
    func nameCrossLanguageMatrix() async throws {
        let fact = "Мене звати Олег."
        let s = await store((fact, .profile))
        for q in ["Як мене звати?", "What is my name?", "Wie heiße ich?", "Jak mam na imię?"] {
            let c = await context(lexicalBuilder(s), q)
            #expect(hasFact(c, fact), "not retrieved for: \(q)")
            let r = try await reply(c, q)
            #expect(r.localizedCaseInsensitiveContains("Олег"), "reply missing name for: \(q) — got: \(r)")
        }
    }

    // MARK: - not name-only (§4): location + occupation

    @Test("location fact answers \"Where do I live?\" cross-lingually")
    func locationProfileFact() async throws {
        let fact = "Я живу в Києві."
        let s = await store((fact, .profile))
        for q in ["Де я живу?", "Where do I live?", "Wo wohne ich?", "Gdzie mieszkam?"] {
            let c = await context(lexicalBuilder(s), q)
            #expect(hasFact(c, fact), "not retrieved for: \(q)")
            let r = try await reply(c, q)
            #expect(r.localizedCaseInsensitiveContains("києв"), "reply missing location for: \(q) — got: \(r)")
        }
    }

    @Test("occupation fact answers \"What do I do for work?\" cross-lingually")
    func occupationProfileFact() async throws {
        let fact = "I work as a customs lawyer."
        let s = await store((fact, .profile))
        for q in ["What do I do for work?", "Ким я працюю?", "Was mache ich beruflich?", "Gdzie pracuję?"] {
            let c = await context(lexicalBuilder(s), q)
            #expect(hasFact(c, fact), "not retrieved for: \(q)")
            let r = try await reply(c, q)
            #expect(r.localizedCaseInsensitiveContains("customs lawyer"), "reply missing occupation for: \(q) — got: \(r)")
        }
    }

    // MARK: - negatives / safety (§7)

    @Test("an unrelated question does NOT pull profile facts into the context")
    func unrelatedQueryNoLeak() async throws {
        let s = await store(
            ("Мене звати Олег.", .profile),
            ("Я живу в Києві.", .profile),
            ("I work as a customs lawyer.", .profile)
        )
        for q in ["How do WebSockets handle backpressure?", "Розкажи про погоду завтра.", "What's the capital of France?"] {
            let c = await context(lexicalBuilder(s), q)
            #expect(c.relevantMemories.isEmpty, "profile facts leaked for: \(q)")
        }
    }

    @Test("memory disabled → profile fact is not retrieved and the reply doesn't leak it")
    func memoryDisabled() async throws {
        let s = await store(("Мене звати Олег.", .profile))
        await s.setMemoryEnabledGlobally(false)
        let c = await context(lexicalBuilder(s), "What is my name?")
        #expect(c.memoryDisabled)
        #expect(c.relevantMemories.isEmpty)
        let r = try await reply(c, "What is my name?")
        #expect(r.contains("Олег") == false)
    }

    @Test("a deleted / tombstoned profile fact is never surfaced")
    func tombstonedProfileFact() async throws {
        let s = InMemoryPersonalMemoryStore()
        let rec = MemoryRecord(category: .profile, canonicalContent: "Мене звати Олег.", importance: 0.65)
        await s.upsert([rec])
        await s.setMemoryStatus(id: rec.id, status: .deleted)
        let c = await context(lexicalBuilder(s), "What is my name?")
        #expect(c.relevantMemories.isEmpty)
        #expect(c.systemPromptText.contains("Олег") == false)
    }

    @Test("owner B's build cannot surface owner A's profile fact")
    func ownerIsolation() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("profile-iso-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = LocalPersonalMemoryStore(directory: dir, ownerID: "A")
        await a.upsert([MemoryRecord(category: .profile, canonicalContent: "Мене звати Олег.", importance: 0.65)])
        #expect(hasFact(await context(lexicalBuilder(a), "What is my name?"), "Мене звати Олег."))

        let b = LocalPersonalMemoryStore(directory: dir, ownerID: "B")
        #expect((await context(lexicalBuilder(b), "What is my name?")).relevantMemories.isEmpty)
    }

    @Test("a current-instruction rule still renders above the retrieved profile fact")
    func priorityRuleWins() async throws {
        let s = await store(("Мене звати Олег.", .profile))
        // "Always …" in the message is a current instruction (priority 0).
        let c = await context(lexicalBuilder(s), "Always answer in one sentence. What is my name?")
        let instrPos = c.systemPromptText.range(of: "answer in one sentence")
        let factPos = c.systemPromptText.range(of: "Мене звати Олег")
        #expect(instrPos != nil)
        #expect(factPos != nil)
        if let instrPos, let factPos { #expect(instrPos.lowerBound < factPos.lowerBound) }
    }

    // MARK: - provider does not fabricate

    @Test("no profile fact on file → the provider does not invent a name")
    func noFactNoFabrication() async throws {
        let s = InMemoryPersonalMemoryStore()   // empty
        let c = await context(lexicalBuilder(s), "What is my name?")
        let r = try await reply(c, "What is my name?")
        #expect(r.localizedCaseInsensitiveContains("your name is") == false)
        #expect(r.isEmpty == false)   // still a safe non-empty fallback
    }
}
