import Foundation

/// Ranks memory for one request. The rule the product brief insists on:
/// *do not inject every memory into every request*. Retrieval scores each
/// eligible record and drops everything below `RetrievalQuery.minScore`, so
/// an EvenAI question pulls EvenAI project memory and leaves last week's
/// travel note behind.
///
/// Phase 1 relevance is lexical (`TextSimilarity`). The scoring shape —
/// weighted sum of independent components — is deliberately the same one an
/// embedding-backed Phase 2 would use; only `semanticComponent` changes.
struct MemoryRetriever: Sendable {

    struct Weights: Sendable {
        var semantic = 1.0
        var categoryPrior = 0.35
        var recency = 0.30
        var importance = 0.35
        var confirmed = 0.20
        var projectMatch = 0.9
        var personMatch = 0.7
        var pinned = 0.5
        /// How much a cross-lingual semantic match counts toward a record's
        /// textual relevance, relative to a perfect lexical match. `< 1` so a
        /// semantic hit is a genuine but slightly discounted signal — it
        /// rescues a record the lexical layer missed across a language
        /// boundary without ever outranking an exact same-language match.
        var semanticCrossLingual = 0.85
        static let `default` = Weights()
    }

    var weights: Weights = .default

    init(weights: Weights = .default) {
        self.weights = weights
    }

    /// Precomputed vectors for one retrieval pass. The context builder embeds
    /// the query once (async) and loads candidate vectors from
    /// `EmbeddingVectorIndex`, then hands them here so `retrieve` stays a
    /// synchronous, deterministic pure function. `nil` — the Slice 1 default,
    /// and whenever the semantic layer is inert or failed — means "score
    /// every record lexically", i.e. exactly today's behaviour.
    struct SemanticContext: Sendable {
        var queryVector: [Float]
        var recordVectors: [UUID: [Float]]
    }

    func retrieve(
        _ query: RetrievalQuery,
        from records: [MemoryRecord],
        semantic semanticContext: SemanticContext? = nil
    ) -> [ScoredMemory] {
        let queryText = ([query.text] + query.recentContext).joined(separator: " ")
        let queryTokens = TextSimilarity.tokenSet(queryText)

        let scored: [ScoredMemory] = records.compactMap { record in
            guard record.isRetrievable(now: query.now) else { return nil }
            guard record.scope.appliesTo(surface: query.surface) else { return nil }
            guard record.category != .rules else { return nil } // rules are injected unconditionally, not retrieved

            var components: [String: Double] = [:]

            // Semantic — current message weighted fully, recent context at 0.4.
            let semMain = TextSimilarity.semanticSimilarity(query.text, record.canonicalContent)
            let semContext = query.recentContext.isEmpty ? 0 :
                TextSimilarity.semanticSimilarity(query.recentContext.joined(separator: " "), record.canonicalContent)
            let semEntities = record.entities.isEmpty ? 0 :
                (queryTokens.isDisjoint(with: Set(record.entities.flatMap { TextSimilarity.tokens($0) })) ? 0 : 0.5)
            let lexicalSemantic = max(semMain, 0.4 * semContext, semEntities)

            // Cross-lingual rescue: if a query vector and this record's
            // vector are both present, fold their cosine in via
            // `max(lexical, weight · cosine)`. Absent vectors → 0 → identical
            // to the pure-lexical path.
            let crossLingual: Double = {
                guard let semanticContext, let recordVector = semanticContext.recordVectors[record.id] else { return 0 }
                return SemanticRelevance.cosine(semanticContext.queryVector, recordVector)
            }()
            let semantic = SemanticRelevance.blend(
                lexical: lexicalSemantic,
                semantic: crossLingual,
                weight: weights.semanticCrossLingual
            )
            components["semantic"] = semantic * weights.semantic

            // Category prior for this surface.
            let prior = Self.categoryPrior(record.category, surface: query.surface, queryText: queryText)
            components["categoryPrior"] = prior * weights.categoryPrior

            // Recency — exp decay on updatedAt, half-life 30 days.
            let ageDays = max(0, query.now.timeIntervalSince(record.lastUsedAt ?? record.updatedAt) / 86_400)
            let recency = pow(0.5, ageDays / 30.0)
            components["recency"] = recency * weights.recency

            components["importance"] = record.importance * weights.importance
            components["confirmed"] = (record.userConfirmed ? 1.0 : 0.0) * weights.confirmed
            components["pinned"] = (record.pinned ? 1.0 : 0.0) * weights.pinned

            // Project / person hint matches — hard boosts.
            let recordTokens = TextSimilarity.tokenSet(record.canonicalContent)
                .union(record.entities.flatMap { TextSimilarity.tokens($0) })
            let projectHit = query.projectHints.contains { hint in
                !TextSimilarity.tokens(hint).isEmpty &&
                !Set(TextSimilarity.tokens(hint)).isDisjoint(with: recordTokens)
            }
            let personHit = query.personHints.contains { hint in
                !TextSimilarity.tokens(hint).isEmpty &&
                !Set(TextSimilarity.tokens(hint)).isDisjoint(with: recordTokens)
            }
            if projectHit && (record.category == .projects || record.category == .knowledge || record.category == .episodes) {
                components["projectMatch"] = weights.projectMatch
            }
            if personHit && record.category == .people {
                components["personMatch"] = weights.personMatch
            }

            // The user's own profile / identity facts ("my name is…", "I
            // live in…") are always eligible when this turn is a profile
            // question (`RetrievalQuery.profileLookup`) — a Personal AI must
            // be able to answer "what is my name?" with no semantic model,
            // even when the fact is stored in another language. They still
            // obey `minScore` (below), `isRetrievable`, scope and owner, and
            // this never fires for non-profile-question turns.
            let profileLookupHit = query.profileLookup && record.category == .profile

            // A record with genuinely zero topical connection is never
            // carried by importance/recency alone — that is the "don't
            // pollute the prompt" guarantee.
            let hasTopicalConnection = semantic > 0.05 || projectHit || personHit || profileLookupHit
            guard hasTopicalConnection else { return nil }

            let raw = components.values.reduce(0, +)
            let maxPossible = weights.semantic + weights.categoryPrior + weights.recency
                + weights.importance + weights.confirmed + weights.pinned
                + weights.projectMatch + weights.personMatch
            let score = raw / maxPossible

            return ScoredMemory(record: record, score: score, components: components)
        }

        return scored
            .filter { $0.score >= query.minScore }
            .sorted { $0.score > $1.score }
            .prefix(query.limit)
            .map { $0 }
    }

    // MARK: - Category priors

    /// A light nudge: on the G2 reply surface, `style`/`preferences` matter
    /// more; in Personal AI Chat everything is fair game. `projects`/`people`
    /// get a nudge whenever the query text hints at project/person talk.
    static func categoryPrior(_ category: MemoryCategory, surface: PersonalAISurface, queryText: String) -> Double {
        let l = queryText.lowercased()
        switch category {
        case .style:
            return surface == .g2Replies ? 0.8 : 0.4
        case .preferences:
            return 0.5
        case .projects:
            return ["project", "build", "launch", "ship", "bug", "feature", "deadline", "roadmap", "app", "code"].contains(where: l.contains) ? 0.9 : 0.4
        case .people:
            return 0.4
        case .profile:
            return 0.5
        case .knowledge:
            return 0.45
        case .episodes:
            return 0.35
        case .workingContext:
            return 0.4
        case .rules, .conversationArchive:
            return 0.0
        }
    }
}

/// Sweeps expired records to `.archived` so `MemoryRetriever` (and therefore
/// every prompt) never sees them. Pure — returns the records to persist;
/// the caller writes them back.
enum MemoryMaintenance {
    static func archivingExpired(in records: [MemoryRecord], now: Date = .now) -> [MemoryRecord] {
        records.filter { $0.status == .active && $0.isExpired(now: now) }
            .map { record in
                var updated = record.touched(now: now)
                updated.status = .archived
                return updated
            }
    }
}
