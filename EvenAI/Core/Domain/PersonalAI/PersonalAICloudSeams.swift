import Foundation

// MARK: - Phase 2 seams (declared, deliberately NOT implemented in Phase 1)
//
// These protocols exist so the Phase 1 architecture has explicit joints for
// the cloud work, and so nothing built now hard-wires Railway, a single AI
// provider, or a single storage backend. There is no conformer in this
// codebase yet — adding one is Phase 2, and the plan
// (PHASE2_PERSONAL_AI_CLOUD.md) describes exactly how each drops in.

/// Remote authoritative store for a user's memory. A Phase 2
/// `HybridMemoryStore` composes this with `LocalPersonalMemoryStore`'s
/// successor (an encrypted local cache) behind the existing
/// `PersonalMemoryStore` protocol — callers above never change.
protocol CloudMemoryStore: Sendable {
    /// Records changed remotely since `since` (a server revision cursor).
    func pull(since cursor: String?) async throws -> PersonalMemoryDocument
    /// Push local pending changes; returns the server's authoritative
    /// versions (with `remoteID` / `revision` assigned) plus a new cursor.
    func push(_ document: PersonalMemoryDocument) async throws -> (merged: PersonalMemoryDocument, cursor: String)
    /// Full snapshot for new-device recovery / disaster recovery.
    func snapshot() async throws -> PersonalMemoryDocument
}

/// The network face of memory operations, independent of transport. Phase 2
/// implements this against whatever backend is chosen (self-hosted, managed
/// DB, etc.) — never assumed to be Railway.
protocol PersonalMemoryAPI: Sendable {
    func fetchMemories(cursor: String?) async throws -> PersonalMemoryDocument
    func upsertMemories(_ records: [MemoryRecord]) async throws -> [MemoryRecord]
    func upsertRules(_ rules: [Rule]) async throws -> [Rule]
    func deleteMemory(remoteID: String) async throws
}

/// The network face of Personal AI generation, independent of model vendor.
/// A Phase 2 cloud provider conforms to this *and* to
/// `PersonalAIModelProviding`, so the app can move generation on/off device
/// without touching the memory layer.
protocol PersonalAIAPI: Sendable {
    func generate(
        systemContext: String,
        messages: [PersonalAIChatMessage],
        userMessage: String,
        maxOutputTokens: Int
    ) async throws -> PersonalAIGenerationResult
}
