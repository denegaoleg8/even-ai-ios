import Foundation

/// The one implementation of `PersonalAIContextBuilding`. Personal AI Chat
/// and the future G2 personalization seam both call this — the only thing
/// that differs is `PersonalAIContextRequest.surface`.
///
/// Pipeline: load store → archive expired records → retrieve relevant memory
/// → resolve active rules (scope + priority) → project style → render a
/// token-budgeted block. Every step is a separate, independently tested
/// type; this composes them.
struct DefaultPersonalAIContextBuilder: PersonalAIContextBuilding {

    private let store: any PersonalMemoryStore
    private let retriever: MemoryRetriever
    private let interpreter: CommandInterpreter
    private static let profileQuestions = ProfileQuestionDetector()
    /// Optional cross-lingual semantic layer. `nil` / inert
    /// (`NoSemanticScorer`) → retrieval is purely lexical, exactly as
    /// before. When active, the builder embeds the query and folds a
    /// semantic score into ranking via `MemoryRetriever.SemanticContext`.
    private let semanticScorer: (any SemanticMemoryScoring)?
    /// Derived vector storage for the semantic layer. Rebuildable; never
    /// authoritative. Only touched when `semanticScorer` is active.
    private let vectorIndex: EmbeddingVectorIndex?

    init(
        store: any PersonalMemoryStore,
        retriever: MemoryRetriever = MemoryRetriever(),
        interpreter: CommandInterpreter = CommandInterpreter(),
        semanticScorer: (any SemanticMemoryScoring)? = nil,
        vectorIndex: EmbeddingVectorIndex? = nil
    ) {
        self.store = store
        self.retriever = retriever
        self.interpreter = interpreter
        self.semanticScorer = semanticScorer
        self.vectorIndex = vectorIndex
    }

    /// The wired semantic layer, but only when it is real (non-inert) and
    /// has vector storage — otherwise `nil` and retrieval stays lexical.
    private var activeSemantic: (scorer: any SemanticMemoryScoring, index: EmbeddingVectorIndex)? {
        guard let semanticScorer, semanticScorer.isActive, let vectorIndex else { return nil }
        return (semanticScorer, vectorIndex)
    }

    func buildContext(_ request: PersonalAIContextRequest) async -> PersonalAIContext {
        let memoryEnabled = await store.isMemoryEnabledGlobally()
        let excludedConversation = request.conversationID.map { id in
            Task { await store.isConversationExcluded(id) }
        }

        // Memory disabled globally, or this conversation opted out → no
        // retrieved memory at all. Rules still apply (they are the user's
        // explicit instructions, not "memory about them"), but nothing is
        // recalled.
        let conversationExcluded = await (excludedConversation?.value ?? false)
        let disabled = !memoryEnabled

        // 1. Maintenance: archive expired records so they can never be retrieved.
        let allRecords = await store.allMemories()
        let toArchive = MemoryMaintenance.archivingExpired(in: allRecords, now: request.now)
        if !toArchive.isEmpty {
            await store.upsert(toArchive)
        }
        let liveRecords = allRecords.map { record -> MemoryRecord in
            if let archived = toArchive.first(where: { $0.id == record.id }) { return archived }
            return record
        }

        // 2. Rules — always evaluated, never retrieval-gated.
        let rules = await store.allRules()
            .filter { $0.isActive(now: request.now, surface: request.surface) }
            .sorted { $0.priority < $1.priority }

        // 3. Current-message instruction (highest priority tier).
        let currentInstruction = Self.currentInstruction(in: request.userMessage, interpreter: interpreter)

        // Is this turn asking to recall a stored profile / identity fact
        // ("what is my name?", "де я живу?")? If so, `.profile` records are
        // let past retrieval's generic topical-connection gate and rendered
        // as **known user facts** — a Personal AI must answer identity
        // questions with no semantic model, even cross-lingually.
        let profileLookup = !Self.profileQuestions.aspects(in: request.userMessage).isEmpty

        // 4. Retrieval.
        var scored: [ScoredMemory] = []
        if !disabled && !conversationExcluded {
            let query = RetrievalQuery(
                text: request.userMessage,
                recentContext: request.recentConversation,
                surface: request.surface,
                projectHints: request.projectHints.map { $0.lowercased() },
                personHints: request.personHints.map { $0.lowercased() },
                now: request.now,
                profileLookup: profileLookup
            )

            // 4a. Cross-lingual semantic layer (additive, best-effort). Only
            //     runs when a real scorer is wired — never when memory is
            //     disabled or the conversation is excluded (this whole block
            //     is already gated on that). Any failure leaves
            //     `semanticContext == nil` and retrieval is purely lexical.
            let semanticContext = await Self.semanticContext(
                for: request.userMessage,
                candidates: liveRecords.filter { $0.isRetrievable(now: request.now) },
                using: activeSemantic
            )

            scored = retriever.retrieve(query, from: liveRecords, semantic: semanticContext)

            // Mark retrieved records as used (recency signal for next time).
            let usedIDs = Set(scored.map { $0.record.id })
            let touched = liveRecords.filter { usedIDs.contains($0.id) }.map { rec -> MemoryRecord in
                var r = rec
                r.lastUsedAt = request.now
                return r
            }
            if !touched.isEmpty { await store.upsert(touched) }
        }

        let retrieved = scored.map { $0.record }
        let projects = retrieved.filter { $0.category == .projects }
        let people = retrieved.filter { $0.category == .people }
        let excerpts: [ConversationExcerpt] = scored
            .filter { $0.record.category == .conversationArchive && $0.record.sourceConversationIDs.first != request.conversationID }
            .prefix(3)
            .map { ConversationExcerpt(
                conversationID: $0.record.sourceConversationIDs.first ?? UUID(),
                timestamp: $0.record.createdAt,
                text: $0.record.canonicalContent,
                relevance: $0.score
            ) }
        // On a profile question, the retrieved `.profile` facts are the
        // answer — pull them out so the renderer shows them as known facts,
        // not buried in "may be relevant" prose. Retrieval has already
        // enforced active / non-deleted / correct-owner / in-scope / not
        // expired, and `disabled` suppresses retrieval entirely.
        let knownProfileFacts = profileLookup ? retrieved.filter { $0.category == .profile } : []
        let knownProfileIDs = Set(knownProfileFacts.map(\.id))
        let otherMemories = retrieved.filter {
            ![.projects, .people, .conversationArchive].contains($0.category) && !knownProfileIDs.contains($0.id)
        }

        // 5. Style.
        let profile = await store.styleProfile()
        let styleInstructions = disabled ? "" : Self.renderStyle(profile)

        // 6. Render.
        let rendered = PersonalAIContextRenderer.render(.init(
            currentInstruction: currentInstruction,
            rules: rules,
            knownProfileFacts: knownProfileFacts,
            projects: projects,
            people: people,
            otherMemories: otherMemories,
            excerpts: excerpts,
            styleInstructions: styleInstructions,
            tokenBudget: request.tokenBudget,
            memoryDisabled: disabled
        ))

        var trace = rendered.trace
        trace.insert("retrieved=\(retrieved.count)/\(liveRecords.filter { $0.isRetrievable(now: request.now) }.count)", at: 0)
        trace.append("surface=\(request.surface.rawValue)")
        if conversationExcluded { trace.append("conversationExcluded") }
        if !toArchive.isEmpty { trace.append("archivedExpired=\(toArchive.count)") }

        return PersonalAIContext(
            activeRules: rules,
            relevantMemories: retrieved,
            relevantProjects: projects,
            relevantPeople: people,
            historicalExcerpts: excerpts,
            styleInstructions: styleInstructions,
            systemPromptText: rendered.text,
            memoryDisabled: disabled,
            buildTrace: trace
        )
    }

    // MARK: - Helpers

    /// Time the whole semantic pre-step is allowed before the builder gives
    /// up and returns purely-lexical results. Independent of (and much
    /// tighter than) the Phase 3 G2 enrichment timeout — this one protects
    /// the Personal AI Chat path too, where nothing else bounds the wait.
    private static let semanticBudget: Duration = .seconds(2)

    /// Embeds the query and loads candidate vectors so `MemoryRetriever` can
    /// fold in a cross-lingual score. Opportunistically re-embeds up to a
    /// bounded number of stale candidates and prunes vectors for records
    /// that are gone — the "lazy re-embed on retrieval touch" from the plan,
    /// entirely on the read path. Returns `nil` (⇒ lexical-only) whenever the
    /// semantic layer is absent, inert, times out, or anything throws.
    private static func semanticContext(
        for userMessage: String,
        candidates: [MemoryRecord],
        using active: (scorer: any SemanticMemoryScoring, index: EmbeddingVectorIndex)?
    ) async -> MemoryRetriever.SemanticContext? {
        guard let (scorer, index) = active, !candidates.isEmpty else { return nil }

        let work: @Sendable () async -> MemoryRetriever.SemanticContext? = {
            // Keep the index tidy; retrieval already filters non-retrievable
            // records, so this is housekeeping only.
            await index.pruneMissing(keeping: Set(candidates.map(\.id)))
            await index.refreshStale(among: candidates, using: scorer, limit: 32)

            guard let queryVector = try? await scorer.embed([userMessage]).first, !queryVector.isEmpty else { return nil }
            let recordVectors = await index.vectors(for: candidates.map(\.id))
            guard !recordVectors.isEmpty else { return nil }
            return MemoryRetriever.SemanticContext(queryVector: queryVector, recordVectors: recordVectors)
        }

        return await withTaskGroup(of: MemoryRetriever.SemanticContext?.self) { group in
            group.addTask { await work() }
            group.addTask { try? await Task.sleep(for: semanticBudget); return nil }
            let first = await group.next() ?? nil   // whichever finishes first
            group.cancelAll()
            return first
        }
    }

    static func currentInstruction(in message: String, interpreter: CommandInterpreter) -> String? {
        for command in interpreter.interpret(message) {
            switch command {
            case .addRule(let text, _): return text
            case .setStyle(let directive): return HeuristicMemoryExtractor.canonicalize(directive)
            default: continue
            }
        }
        return nil
    }

    static func renderStyle(_ p: PersonalAIStyleProfile) -> String {
        guard p.hasSignal else { return "" }
        var parts: [String] = []
        if let lang = p.preferredLanguage {
            parts.append("reply in \(Self.languageName(lang))")
        }
        switch p.responseLength {
        case .short: parts.append("keep it short")
        case .long: parts.append("be thorough")
        case .medium, .unspecified: break
        }
        if let d = p.directness, StyleDimensionMeta.isTrusted(p.evidence["directness"]) {
            parts.append(d >= 0.6 ? "be direct" : "be gentle")
        }
        if let f = p.formality, StyleDimensionMeta.isTrusted(p.evidence["formality"]) {
            parts.append(f >= 0.6 ? "keep it professional" : "keep it casual")
        }
        if let t = p.technicalDepth, t >= 0.6 { parts.append("go technical when useful") }
        if let pr = p.proactiveness, pr >= 0.6 { parts.append("suggest concrete next steps") }
        switch p.formatting {
        case .bullets: parts.append("use bullet points")
        case .prose: parts.append("write in prose, not lists")
        case .unspecified: break
        }
        if !p.phrasesToAvoid.isEmpty {
            parts.append("never use: " + p.phrasesToAvoid.map { "\"\($0)\"" }.joined(separator: ", "))
        }
        if !p.preferredVocabulary.isEmpty {
            parts.append("prefer the terms: " + p.preferredVocabulary.joined(separator: ", "))
        }
        return parts.isEmpty ? "" : parts.joined(separator: "; ") + "."
    }

    static func languageName(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }
}

private extension StyleDimensionMeta {
    static func isTrusted(_ meta: StyleDimensionMeta?) -> Bool {
        guard let meta else { return false }
        return meta.isTrusted
    }
}
