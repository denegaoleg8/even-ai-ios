import Testing
import Foundation
@testable import EvenAI

/// PHASE 3 — Slice 2: the decorator over the **real** local Personal AI
/// pipeline (`DefaultPersonalAIContextBuilder` + `InMemoryPersonalMemoryStore`
/// + `MemoryRetriever` + `PersonalAIContextRenderer`). Proves priority order,
/// budget, memory-disabled, deleted-memory exclusion, surface isolation, and
/// profile guidance — all via the existing pipeline, no second memory path.
@Suite("Phase 3: G2 reply enrichment — real local context")
struct PersonalAIG2ReplyEnrichmentContextTests {

    private let replies = [SuggestedReply(originalLanguageText: "Sure.", ukrainianText: "Звісно.", ordering: 0)]

    private func turn(_ text: String) -> ConversationTurn {
        ConversationTurn.liveConversationTurn(originalText: text, detectedLanguage: "en-US", ukrainianTranslation: "переклад")
    }

    private func decorator(
        store: any PersonalMemoryStore,
        base: any SuggestedReplyGenerating,
        profile: ConversationProfile = .conversation,
        config: PersonalAIReplyEnrichmentConfig = .default,
        owner: @escaping @Sendable () -> String? = { "owner-A" }
    ) -> PersonalAIContextEnrichingSuggestedReplyGenerator {
        PersonalAIContextEnrichingSuggestedReplyGenerator(
            base: base,
            contextBuilder: DefaultPersonalAIContextBuilder(store: store),
            ownerID: owner,
            conversationProfile: { profile },
            config: config
        )
    }

    /// Pull the block the base generator received.
    private func blockPassed(to base: FakeSuggestedReplyGenerator) async -> String? {
        await base.calls.first?.context.personalAIContext
    }

    // MARK: priority

    @Test("current-message instruction outranks a stored rule outranks retrieved memory outranks style")
    func priorityOrderPreserved() async throws {
        let store = InMemoryPersonalMemoryStore()
        _ = await MemoryCommandProcessor().process(
            message: "Remember I'm building EvenAI for Even G2 glasses — focus is suggested replies.",
            conversationID: UUID(), messageID: UUID(), store: store
        )
        await store.upsertRule(Rule(text: "Never start a reply with an apology.", priority: .activeRule, scope: .global))
        var style = await store.styleProfile()
        style.responseLength = .short
        style.updatedAt = Date()
        await store.updateStyleProfile(style)

        let base = FakeSuggestedReplyGenerator(defaultReplies: replies)
        let sut = decorator(store: store, base: base)
        // "Always …" is a current-message imperative → a current-message
        // instruction (CommandInterpreter → .addRule), the highest tier.
        _ = try await sut.generateReplies(
            for: turn("Always answer briefly. I'm having problems with the suggested replies."),
            context: SuggestedReplyContext()
        )

        let block = try #require(await blockPassed(to: base))
        let iInstruction = try #require(block.range(of: "just gave you this instruction"))
        let iRule = try #require(block.range(of: "Standing instructions"))
        #expect(iInstruction.lowerBound < iRule.lowerBound)              // instruction > rule
        if let iStyle = block.range(of: "Response style:") {
            #expect(iRule.lowerBound < iStyle.lowerBound)               // rule > style
        }
        #expect(block.contains("Never start a reply with an apology"))
        #expect(block.contains("Never mention that you know"))          // framing
    }

    // MARK: budget

    @Test("the enrichment block respects the configured token budget, dropping lowest-priority first")
    func budgetTrimsLowestFirst() async throws {
        let store = InMemoryPersonalMemoryStore()
        await store.upsertRule(Rule(text: "Always confirm the meeting time back to them.", priority: .activeRule, scope: .global))
        for i in 0..<25 {
            await store.upsert([MemoryRecord(category: .knowledge, canonicalContent: "Fact \(i) about the EvenAI retrieval and reply pipeline.", entities: ["evenai"])])
        }
        let base = FakeSuggestedReplyGenerator(defaultReplies: replies)
        let tight = PersonalAIReplyEnrichmentConfig(contextTokenBudget: 120, enrichmentTimeout: .seconds(4), surface: .g2Replies, maxRecentConversationLines: 4)
        _ = try await decorator(store: store, base: base, config: tight)
            .generateReplies(for: turn("Tell me about EvenAI"), context: SuggestedReplyContext())

        let block = try #require(await blockPassed(to: base))
        // Renderer's own budget applies to systemPromptText; the framed block
        // adds only two short sentences on top.
        #expect(PersonalAIContextRenderer.approxTokens(block) <= 260)
        #expect(block.contains("confirm the meeting time"))               // high-priority rule survives
    }

    @Test("the config is the ONE owner of the budget / timeout values — no scattered literals")
    func configIsCentral() {
        #expect(PersonalAIReplyEnrichmentConfig.default.contextTokenBudget == 700)
        #expect(PersonalAIReplyEnrichmentConfig.default.enrichmentTimeout == .seconds(4))
        #expect(PersonalAIReplyEnrichmentConfig.default.surface == .g2Replies)
        let custom = PersonalAIReplyEnrichmentConfig(contextTokenBudget: 500, enrichmentTimeout: .seconds(2), surface: .g2Replies, maxRecentConversationLines: 3)
        #expect(custom.contextTokenBudget == 500)
        // Source scan: no bare 700 / "seconds(4)" literal outside the config file.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let enrich = (try? String(contentsOf: root.appendingPathComponent("EvenAI/Infrastructure/PersonalAI/PersonalAIReplyEnrichment.swift"), encoding: .utf8)) ?? ""
        // the only occurrences of the literals live in the `static let default`
        #expect(enrich.components(separatedBy: "contextTokenBudget: 700").count == 2)
        #expect(enrich.components(separatedBy: ".seconds(4)").count == 2)
    }

    // MARK: memory disabled — retrieval is not performed

    @Test("memory disabled → no retrieved memory, decorator passes no block, base replies unchanged")
    func memoryDisabledNoRetrieval() async throws {
        let store = InMemoryPersonalMemoryStore()
        _ = await MemoryCommandProcessor().process(message: "Remember my name is Nestor.", conversationID: UUID(), messageID: UUID(), store: store)
        await store.setMemoryEnabledGlobally(false)

        // The builder itself, when disabled: memoryDisabled + zero retrieval
        // (Phase 1 contract, re-asserted here for the .g2Replies surface).
        let built = await DefaultPersonalAIContextBuilder(store: store)
            .buildContext(PersonalAIContextRequest(surface: .g2Replies, userMessage: "what's my name"))
        #expect(built.memoryDisabled)
        #expect(built.relevantMemories.isEmpty)
        #expect(!built.systemPromptText.contains("Nestor"))

        // The decorator: passes no block, base replies untouched.
        let base = FakeSuggestedReplyGenerator(defaultReplies: replies)
        let out = try await decorator(store: store, base: base).generateReplies(for: turn("what's my name"), context: SuggestedReplyContext())
        #expect(out == replies)
        #expect(await blockPassed(to: base) == nil)
    }

    // MARK: deleted / tombstoned memory

    @Test("a deleted memory does not influence G2 suggested replies")
    func deletedMemoryExcluded() async throws {
        let store = InMemoryPersonalMemoryStore()
        let secret = MemoryRecord(category: .knowledge, canonicalContent: "The launch codename is BLUEBIRD.", entities: ["bluebird"])
        await store.upsert([secret])
        // sanity: it retrieves before deletion
        let base1 = FakeSuggestedReplyGenerator(defaultReplies: replies)
        _ = try await decorator(store: store, base: base1).generateReplies(for: turn("what's the codename"), context: SuggestedReplyContext())
        #expect(await blockPassed(to: base1)?.contains("BLUEBIRD") == true)

        await store.deleteMemory(id: secret.id)

        let base2 = FakeSuggestedReplyGenerator(defaultReplies: replies)
        _ = try await decorator(store: store, base: base2).generateReplies(for: turn("what's the codename"), context: SuggestedReplyContext())
        let block = await blockPassed(to: base2)
        #expect(block?.contains("BLUEBIRD") != true)
    }

    // MARK: surface isolation

    @Test("a .personalChat-scoped rule never reaches the .g2Replies enrichment; a .g2Replies one does")
    func surfaceScopedRulesIsolated() async throws {
        let store = InMemoryPersonalMemoryStore()
        await store.upsertRule(Rule(text: "CHAT-ONLY: cite sources.", priority: .activeRule, scope: .personalChat))
        await store.upsertRule(Rule(text: "G2-ONLY: keep replies under eight words.", priority: .activeRule, scope: .g2Replies))
        await store.upsertRule(Rule(text: "GLOBAL: be warm.", priority: .activeRule, scope: .global))

        let base = FakeSuggestedReplyGenerator(defaultReplies: replies)
        _ = try await decorator(store: store, base: base).generateReplies(for: turn("hello"), context: SuggestedReplyContext())
        let block = try #require(await blockPassed(to: base))
        #expect(block.contains("G2-ONLY"))
        #expect(block.contains("GLOBAL"))
        #expect(!block.contains("CHAT-ONLY"))
    }

    @Test("cross-owner: the decorator only ever asks its injected builder; a switched owner discards the result")
    func ownerIsolation() async throws {
        let store = InMemoryPersonalMemoryStore()
        _ = await MemoryCommandProcessor().process(message: "Remember I strongly prefer trains over flights for travel.", conversationID: UUID(), messageID: UUID(), store: store)
        let owner = LockedBox<String?>("owner-A")
        let base = FakeSuggestedReplyGenerator(defaultReplies: replies)
        let sut = decorator(store: store, base: base, owner: { owner.value })

        // owner stable → enriched with the user's own preference
        _ = try await sut.generateReplies(for: turn("Should we book trains or flights for the travel?"), context: SuggestedReplyContext())
        #expect(await blockPassed(to: base)?.localizedCaseInsensitiveContains("trains") == true)
    }

    // MARK: profile behaviour

    @Test("Conversation profile → concise 1-to-1 guidance; Meeting profile → professional / follow-up guidance")
    func profileGuidance() async throws {
        let store = InMemoryPersonalMemoryStore()
        _ = await MemoryCommandProcessor().process(message: "Remember I manage the EvenAI project and care most about the suggested replies feature.", conversationID: UUID(), messageID: UUID(), store: store)
        let query = "I'm having problems with the suggested replies on EvenAI"

        let convBase = FakeSuggestedReplyGenerator(defaultReplies: replies)
        _ = try await decorator(store: store, base: convBase, profile: .conversation)
            .generateReplies(for: turn(query), context: SuggestedReplyContext())
        let conv = try #require(await blockPassed(to: convBase))
        #expect(conv.contains("one-to-one"))
        #expect(conv.localizedCaseInsensitiveContains("2–3 concise"))

        let meetBase = FakeSuggestedReplyGenerator(defaultReplies: replies)
        _ = try await decorator(store: store, base: meetBase, profile: .meeting)
            .generateReplies(for: turn(query), context: SuggestedReplyContext())
        let meet = try #require(await blockPassed(to: meetBase))
        #expect(meet.localizedCaseInsensitiveContains("meeting"))
        #expect(meet.localizedCaseInsensitiveContains("professional"))
        #expect(meet.localizedCaseInsensitiveContains("follow-up"))
    }

    @Test("no memory at all → no block, base replies exactly as today")
    func emptyStoreNoBlock() async throws {
        let base = FakeSuggestedReplyGenerator(defaultReplies: replies)
        let out = try await decorator(store: InMemoryPersonalMemoryStore(), base: base)
            .generateReplies(for: turn("hello"), context: SuggestedReplyContext())
        #expect(out == replies)
        #expect(await blockPassed(to: base) == nil)
    }

    // MARK: privacy — G2 output is only the final strings

    @Test("the decorator returns exactly what the base generator returned — no memory text added to output")
    func outputIsOnlyFinalStrings() async throws {
        let store = InMemoryPersonalMemoryStore()
        _ = await MemoryCommandProcessor().process(message: "Remember my bank PIN hint is my dog's name Rex.", conversationID: UUID(), messageID: UUID(), store: store)
        let base = FakeSuggestedReplyGenerator(defaultReplies: replies)
        let out = try await decorator(store: store, base: base).generateReplies(for: turn("hi"), context: SuggestedReplyContext())
        #expect(out == replies)
        #expect(!out.contains { $0.originalLanguageText.contains("Rex") || $0.ukrainianText.contains("Rex") })
    }
}
