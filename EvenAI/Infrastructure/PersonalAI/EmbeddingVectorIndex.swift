import Foundation

/// Derived, rebuildable semantic vectors for Personal AI memory — **never
/// authoritative**. If this file is lost, corrupted, or written by a model
/// version this build doesn't recognise, canonical memory
/// (`canonicalContent`) is untouched and the index is simply rebuilt. This
/// is the same guarantee `PersonalCloudResilienceTests.embeddingLossIsHarmless`
/// already encodes for the cloud seam.
///
/// Mirrors `LocalPersonalMemoryStore`'s pattern: an `actor`, an injectable
/// file `URL` (tests point at a temp dir), an injectable `DocumentFileStoring`
/// (`PersonalAIContainer` passes the same `EncryptedDocumentFile` the memory
/// store uses), best-effort writes that never block the caller.
///
/// Vectors live **only here** — not on `MemoryRecord`, not in
/// `PersonalMemoryDocument`, not in `PersonalDataBundle` / export / backup /
/// cloud. `MemoryRecord.embeddingModelVersion` is the staleness marker;
/// this index is the storage.
actor EmbeddingVectorIndex {

    /// One embedded record. `revision` pins the `MemoryRecord.revision` the
    /// vector was computed from, so an edit (which bumps the record's
    /// revision via `touch()`) is detected as stale.
    struct Entry: Codable, Hashable, Sendable {
        var vector: [Float]
        var modelIdentifier: String
        var revision: Int
        var updatedAt: Date
    }

    private struct Document: Codable, Sendable {
        var schemaVersion: Int
        var entries: [String: Entry]   // MemoryRecord.id.uuidString → Entry
        static let empty = Document(schemaVersion: 1, entries: [:])
    }

    private let fileURL: URL
    private let fileStore: DocumentFileStoring
    private var document: Document = .empty
    private var loaded = false

    /// - Parameters:
    ///   - directory: where the index file lives. Defaults to the same
    ///     `PersonalAI` Application Support subdirectory the memory store
    ///     uses. Tests pass a temp dir.
    ///   - ownerID: namespaces the file so per-user isolation is real —
    ///     `personal-embeddings-<owner>.json`. Matches how
    ///     `LocalPersonalMemoryStore` namespaces its document.
    ///   - fileStore: how bytes reach disk. `PlaintextDocumentFile` by
    ///     default; `PersonalAIContainer` injects `EncryptedDocumentFile`.
    init(directory: URL? = nil, ownerID: String? = nil, fileStore: DocumentFileStoring = PlaintextDocumentFile()) {
        let base = directory ?? Self.defaultDirectory()
        let name = ownerID.map { "personal-embeddings-\($0).json" } ?? "personal-embeddings.json"
        self.fileURL = base.appendingPathComponent(name)
        self.fileStore = fileStore
    }

    private static func defaultDirectory() -> URL {
        let fm = FileManager.default
        let dir = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        let sub = dir.appendingPathComponent("PersonalAI", isDirectory: true)
        try? fm.createDirectory(at: sub, withIntermediateDirectories: true)
        return sub
    }

    // MARK: - Load / persist

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        let bytes: Data?
        do { bytes = try fileStore.read(from: fileURL) } catch { bytes = nil }
        guard let bytes else { return }
        guard let decoded = try? JSONDecoder.personalAI.decode(Document.self, from: bytes) else {
            DiagnosticTrace.log("PERSONAL_AI_EMBEDDINGS", "index unreadable — starting empty (canonical memory unaffected)")
            return
        }
        document = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder.personalAI.encode(document) else { return }
        do { try fileStore.write(data, to: fileURL) }
        catch { DiagnosticTrace.log("PERSONAL_AI_EMBEDDINGS", "persist failed: \(type(of: error))") }
    }

    // MARK: - Reads

    /// The vector for one record, or `nil` if it isn't embedded. Never
    /// throws — a missing vector means "score this record lexically".
    func vector(for id: UUID) -> [Float]? {
        ensureLoaded()
        return document.entries[id.uuidString]?.vector
    }

    /// Vectors for a candidate set, in one pass — what the context builder
    /// hands `MemoryRetriever`.
    func vectors(for ids: [UUID]) -> [UUID: [Float]] {
        ensureLoaded()
        var out: [UUID: [Float]] = [:]
        for id in ids {
            if let v = document.entries[id.uuidString]?.vector, !v.isEmpty { out[id] = v }
        }
        return out
    }

    var count: Int { ensureLoaded(); return document.entries.count }

    // MARK: - Maintenance (all best-effort, all safe to skip)

    /// Records that need embedding for `model`: not present, embedded by a
    /// different model, or embedded from an older revision.
    func staleIDs(model: String, records: [MemoryRecord]) -> [UUID] {
        ensureLoaded()
        return records.compactMap { record in
            guard let entry = document.entries[record.id.uuidString] else { return record.id }
            if entry.modelIdentifier != model { return record.id }
            if entry.revision != record.revision { return record.id }
            return nil
        }
    }

    func upsert(id: UUID, vector: [Float], modelIdentifier: String, revision: Int, now: Date = .now) {
        ensureLoaded()
        guard !vector.isEmpty else { return }   // inert scorer → nothing to store
        document.entries[id.uuidString] = Entry(vector: vector, modelIdentifier: modelIdentifier, revision: revision, updatedAt: now)
        persist()
    }

    func remove(id: UUID) {
        ensureLoaded()
        guard document.entries.removeValue(forKey: id.uuidString) != nil else { return }
        persist()
    }

    /// Drops vectors for records that no longer exist / are no longer
    /// retrievable (deleted, tombstoned, disabled, expired). Retrieval
    /// already filters these regardless — this just keeps the index from
    /// growing unbounded.
    func pruneMissing(keeping ids: Set<UUID>) {
        ensureLoaded()
        let keep = Set(ids.map(\.uuidString))
        let before = document.entries.count
        document.entries = document.entries.filter { keep.contains($0.key) }
        if document.entries.count != before { persist() }
    }

    /// Embeds up to `limit` stale records using `scorer` and stores the
    /// results. Any failure is swallowed — the affected records simply stay
    /// lexical until the next attempt. A `NoSemanticScorer` (or any scorer
    /// returning empty vectors) is a no-op.
    @discardableResult
    func refreshStale(
        among records: [MemoryRecord],
        using scorer: any SemanticMemoryScoring,
        limit: Int = 32,
        now: Date = .now
    ) async -> Int {
        guard scorer.isActive else { return 0 }
        ensureLoaded()
        let targets = Array(staleIDs(model: scorer.modelIdentifier, records: records).prefix(limit))
        guard !targets.isEmpty else { return 0 }

        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let ordered = targets.compactMap { byID[$0] }
        let vectors: [[Float]]
        do { vectors = try await scorer.embed(ordered.map(\.canonicalContent)) }
        catch {
            DiagnosticTrace.log("PERSONAL_AI_EMBEDDINGS", "refresh failed: \(type(of: error)) — records stay lexical")
            return 0
        }
        guard vectors.count == ordered.count else { return 0 }

        var written = 0
        for (record, vector) in zip(ordered, vectors) where !vector.isEmpty {
            document.entries[record.id.uuidString] = Entry(
                vector: vector, modelIdentifier: scorer.modelIdentifier, revision: record.revision, updatedAt: now
            )
            written += 1
        }
        if written > 0 { persist() }
        return written
    }

    /// Full rebuild from scratch (model upgrade, restore, first run). Clears
    /// everything this model didn't produce, then embeds all supplied
    /// records. Callers pass only retrievable records.
    func rebuild(from records: [MemoryRecord], using scorer: any SemanticMemoryScoring, now: Date = .now) async {
        ensureLoaded()
        document.entries.removeAll()
        persist()
        guard scorer.isActive else { return }
        _ = await refreshStale(among: records, using: scorer, limit: records.count, now: now)
    }
}
