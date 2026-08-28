import Foundation

/// The Phase 2 default: no embeddings. Retrieval stays lexical
/// (`TextSimilarity` / `MemoryRetriever`), which is fully sufficient and has
/// zero external dependency. Its presence documents the seam: vectors are
/// **derived** — a `MemoryRecord`'s `embeddingModelVersion` stays `nil`,
/// nothing about canonical memory changes, and a real provider
/// (on-device `NLEmbedding`, or a server vector service) drops in without
/// touching storage or retrieval's public shape.
struct NoEmbeddingProvider: EmbeddingProviding {
    var modelIdentifier: String { "none" }
    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { _ in [] }
    }
}
