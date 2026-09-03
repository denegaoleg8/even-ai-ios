import Testing
import Foundation
@testable import EvenAI

/// Slice 1 — pure vector math for the retrieval blend. No store, no builder.
@Suite("Personal AI: semantic relevance (blend math)")
struct SemanticRelevanceTests {

    // MARK: cosine

    @Test("cosine of identical vectors is 1")
    func cosineIdentical() {
        #expect(abs(SemanticRelevance.cosine([1, 0, 0], [1, 0, 0]) - 1) < 1e-6)
        #expect(abs(SemanticRelevance.cosine([0.2, 0.4, 0.4], [0.2, 0.4, 0.4]) - 1) < 1e-6)
    }

    @Test("cosine of orthogonal vectors is 0")
    func cosineOrthogonal() {
        #expect(SemanticRelevance.cosine([1, 0], [0, 1]) == 0)
    }

    @Test("negative cosine is clamped to 0 — an opposite memory is not 'relevant'")
    func cosineNegativeClamped() {
        #expect(SemanticRelevance.cosine([1, 0], [-1, 0]) == 0)
    }

    @Test("cosine is 0 for empty, mismatched-dimension, or zero-magnitude vectors")
    func cosineDegenerate() {
        #expect(SemanticRelevance.cosine([], []) == 0)
        #expect(SemanticRelevance.cosine([1, 2, 3], [1, 2]) == 0)
        #expect(SemanticRelevance.cosine([0, 0, 0], [1, 1, 1]) == 0)
    }

    // MARK: blend — max(lexical, weight · semantic)

    @Test("a strong lexical match is never diluted by a weak semantic signal")
    func blendKeepsStrongLexical() {
        #expect(SemanticRelevance.blend(lexical: 0.9, semantic: 0.1, weight: 0.85) == 0.9)
    }

    @Test("a semantic hit rescues a record the lexical layer missed")
    func blendRescuesOnSemantic() {
        let blended = SemanticRelevance.blend(lexical: 0.0, semantic: 1.0, weight: 0.85)
        #expect(abs(blended - 0.85) < 1e-9)
    }

    @Test("the semantic contribution is capped by weight (< 1) so it can't outrank an exact lexical match")
    func blendSemanticCapped() {
        let blended = SemanticRelevance.blend(lexical: 0.0, semantic: 5.0, weight: 0.85)  // semantic clamped to 1
        #expect(abs(blended - 0.85) < 1e-9)
        #expect(SemanticRelevance.blend(lexical: 1.0, semantic: 1.0, weight: 0.85) == 1.0)
    }

    @Test("zero semantic signal → blend is exactly the lexical score (today's behaviour)")
    func blendNoSemanticIsIdentity() {
        for l in [0.0, 0.13, 0.5, 0.87, 1.0] {
            #expect(SemanticRelevance.blend(lexical: l, semantic: 0, weight: 0.85) == l)
        }
    }

    // MARK: NoSemanticScorer

    @Test("NoSemanticScorer is inert: modelIdentifier 'none', isActive false, empty vectors")
    func noSemanticScorerInert() async throws {
        let scorer = NoSemanticScorer()
        #expect(scorer.modelIdentifier == "none")
        #expect(scorer.isActive == false)
        let vectors = try await scorer.embed(["anything", "at all"])
        #expect(vectors == [[], []])
    }
}
