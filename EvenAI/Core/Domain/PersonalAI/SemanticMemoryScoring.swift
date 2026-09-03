import Foundation

/// Personal AI retrieval's **semantic seam** — "something that turns text
/// into a comparable vector". Deliberately the same shape as
/// `EmbeddingProviding` (embeddings are the derived-data seam) but kept a
/// separate protocol so `MemoryRetriever` depends on a retrieval concept,
/// not on the cloud/sync connotations `EmbeddingProviding` carries.
///
/// ## Additive and optional by construction
///
/// The lexical path (`TextSimilarity` / `MemoryRetriever`) is the floor and
/// is never removed. A `SemanticMemoryScoring` only ever *adds* a
/// cross-lingual relevance signal on top; when it is absent, inert
/// (`modelIdentifier == "none"`), or failing, retrieval behaves exactly as
/// it does today.
///
/// Slice 1 ships `NoSemanticScorer` only. A real on-device multilingual
/// sentence encoder is a later slice and drops in here without touching
/// storage or the retrieval blend.
protocol SemanticMemoryScoring: Sendable {
    /// Stable `model + version` identifier, stored on `MemoryRecord
    /// .embeddingModelVersion` so a re-embed can detect a model change.
    /// `"none"` for the inert scorer — callers treat that as "no semantic
    /// layer" and stay purely lexical.
    var modelIdentifier: String { get }

    /// Embeds each input into a dense vector. An empty array for an entry
    /// means "no vector available" — the caller must fall back to lexical
    /// for that entry, never treat it as a zero-relevance signal.
    func embed(_ texts: [String]) async throws -> [[Float]]
}

extension SemanticMemoryScoring {
    /// Whether this scorer actually contributes a semantic signal. The
    /// inert scorer answers `false`, and every consumer short-circuits to
    /// the lexical path on `false`.
    var isActive: Bool { modelIdentifier != "none" }
}

/// The Slice 1 default: **no semantic layer**. Retrieval stays lexical.
/// Its presence documents the seam and lets the whole pipeline be wired,
/// tested, and shipped before any model asset exists.
struct NoSemanticScorer: SemanticMemoryScoring {
    var modelIdentifier: String { "none" }
    func embed(_ texts: [String]) async throws -> [[Float]] { texts.map { _ in [] } }
}

/// Pure, deterministic vector math for the retrieval blend. No state, no
/// dependency — unit-testable in isolation.
enum SemanticRelevance {

    /// Cosine similarity mapped to `0...1` (negative cosines clamped to 0,
    /// since a memory that is *semantically opposite* to the query is not
    /// "relevant"). Returns `0` when either vector is empty, a different
    /// dimension, or has zero magnitude — every "no usable vector" case
    /// collapses to "no semantic signal", i.e. lexical-only.
    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices {
            let x = Double(a[i]), y = Double(b[i])
            dot += x * y; na += x * x; nb += y * y
        }
        guard na > 0, nb > 0 else { return 0 }
        let c = dot / (na.squareRoot() * nb.squareRoot())
        return max(0, min(1, c))
    }

    /// The hybrid rule: the record's textual relevance is the **stronger**
    /// of its lexical signal and its (weighted) cross-lingual semantic
    /// signal. `max` — not a sum — so the semantic layer can only ever
    /// *rescue* a record the lexical layer missed across a language
    /// boundary, never dilute a strong lexical match or inflate the score
    /// ceiling.
    static func blend(lexical: Double, semantic: Double, weight: Double) -> Double {
        max(lexical, weight * max(0, min(1, semantic)))
    }
}
