import Foundation
@testable import EvenAI

/// Deterministic stand-in for a real multilingual sentence encoder.
///
/// **This is a test double, not production semantics.** It does not know that
/// "coffee" ≈ "кава" — each *test* declares which phrases are semantically
/// equivalent by putting them in the same `group`, and the double turns that
/// declaration into geometry (near-parallel unit vectors). Phrases in
/// different groups, or not in any group, come out ~orthogonal. This lets the
/// retrieval *architecture* (embed → blend → rank → filter) be verified
/// end-to-end without shipping a language dictionary or a model asset.
///
/// The real encoder (a later slice) conforms to the same `SemanticMemoryScoring`
/// protocol and is what actually proves EN↔UK↔DE↔PL relevance.
actor ScriptedSemanticScorer: SemanticMemoryScoring {

    nonisolated let modelIdentifier: String

    private let groups: [[String]]
    private let exact: [String: [Float]]
    private let dimension: Int
    private let failure: (any Error)?
    private let delay: Duration?

    private var _embedCallCount = 0
    private var _embeddedTexts: [String] = []

    init(
        modelIdentifier: String = "scripted-multilingual-v1",
        groups: [[String]] = [],
        exact: [String: [Float]] = [:],
        dimension: Int = 24,
        failure: (any Error)? = nil,
        delay: Duration? = nil
    ) {
        self.modelIdentifier = modelIdentifier
        self.groups = groups
        self.exact = exact
        self.dimension = max(dimension, groups.count + 4)
        self.failure = failure
        self.delay = delay
    }

    var embedCallCount: Int { _embedCallCount }
    var embeddedTexts: [String] { _embeddedTexts }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        _embedCallCount += 1
        _embeddedTexts.append(contentsOf: texts)
        if let delay { try await Task.sleep(for: delay) }
        if let failure { throw failure }
        return texts.map { Self.vector(for: $0, groups: groups, exact: exact, dimension: dimension) }
    }

    // MARK: - Deterministic vector synthesis

    nonisolated static func vector(for text: String, groups: [[String]], exact: [String: [Float]], dimension: Int) -> [Float] {
        if let override = exact[text] { return normalized(override) }
        let key = normalizeKey(text)

        var v = [Float](repeating: 0, count: dimension)

        if let g = groups.firstIndex(where: { $0.contains { normalizeKey($0) == key } }) {
            // Group identity dimension.
            v[g] = 1.0
            // Small, position-dependent jitter so members of one group are
            // near-parallel but strictly orderable (member 0 == the query in
            // ranking tests gets zero jitter → cosine 1.0).
            let member = groups[g].firstIndex { normalizeKey($0) == key } ?? 0
            let jitterDim = groups.count + (g % max(1, dimension - groups.count))
            if jitterDim < dimension { v[jitterDim] = Float(member) * 0.05 }
        } else {
            // Unknown phrase → a basis vector in the "noise" subspace,
            // orthogonal to every group identity dimension.
            let h = fnv1a(key)
            let dim = groups.count + Int(h % UInt64(max(1, dimension - groups.count)))
            v[min(dim, dimension - 1)] = 1.0
        }
        return normalized(v)
    }

    private nonisolated static func normalizeKey(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func normalized(_ v: [Float]) -> [Float] {
        let norm = v.reduce(0) { $0 + Double($1 * $1) }.squareRoot()
        guard norm > 0 else { return v }
        return v.map { Float(Double($0) / norm) }
    }

    private nonisolated static func fnv1a(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}

struct ScriptedSemanticScorerError: Error {}
