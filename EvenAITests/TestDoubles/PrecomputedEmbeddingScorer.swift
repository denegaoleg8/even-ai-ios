import Foundation
@testable import EvenAI

/// A `SemanticMemoryScoring` whose vectors are **real** `intfloat/multilingual-e5-small`
/// embeddings (rev `614241f…`, exported in Prompt 2B-C and pinned in `E5Fixtures`).
/// It lets the *actual* `MemoryRetriever` → `DefaultPersonalAIContextBuilder`
/// pipeline be exercised with genuine E5 geometry, without shipping the Core ML
/// model or a Swift tokenizer.
///
/// **Test-only.** Never referenced by any production target.
actor PrecomputedEmbeddingScorer: SemanticMemoryScoring {

    nonisolated let modelIdentifier: String
    private let vectors: [String: [Float]]
    private let failure: (any Error)?
    private let delay: Duration?
    private(set) var embedCallCount = 0
    private(set) var embeddedTexts: [String] = []

    init(
        modelIdentifier: String = "e5-small-fixture/d384/l2/tokspm1/pp1",
        vectors: [String: [Float]] = E5Fixtures.memoryVectors.merging(E5Fixtures.queryVectors) { a, _ in a },
        failure: (any Error)? = nil,
        delay: Duration? = nil
    ) {
        self.modelIdentifier = modelIdentifier
        self.vectors = vectors
        self.failure = failure
        self.delay = delay
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        embedCallCount += 1
        embeddedTexts.append(contentsOf: texts)
        if let delay { try await Task.sleep(for: delay) }
        if let failure { throw failure }
        // Unknown text → empty vector → the caller treats it as "no vector"
        // and scores that entry lexically (never as zero relevance).
        return texts.map { vectors[$0] ?? [] }
    }
}

struct PrecomputedEmbeddingScorerError: Error {}
