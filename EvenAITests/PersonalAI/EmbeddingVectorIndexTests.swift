import Testing
import Foundation
@testable import EvenAI

/// Slice 1 — the derived, rebuildable vector store. Proves it is safe to
/// lose (canonical memory untouched), version-aware, revision-aware, and a
/// strict no-op under `NoSemanticScorer`.
@Suite("Personal AI: embedding vector index")
struct EmbeddingVectorIndexTests {

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("evi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func mem(_ content: String, revision: Int = 0) -> MemoryRecord {
        var r = MemoryRecord(category: .preferences, canonicalContent: content)
        r.revision = revision
        return r
    }

    @Test("NoSemanticScorer → refreshStale and rebuild write nothing")
    func inertScorerIsNoOp() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = EmbeddingVectorIndex(directory: dir)
        let records = [mem("Я віддаю перевагу еспресо."), mem("I live in Kyiv.")]

        let written = await index.refreshStale(among: records, using: NoSemanticScorer())
        #expect(written == 0)
        await index.rebuild(from: records, using: NoSemanticScorer())
        #expect(await index.count == 0)
        #expect(await index.vector(for: records[0].id) == nil)
    }

    @Test("refreshStale embeds and persists; a reloaded index still has the vectors")
    func embedsAndPersists() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let scorer = ScriptedSemanticScorer(groups: [["a", "b"]])
        let records = [mem("a"), mem("b")]

        let index = EmbeddingVectorIndex(directory: dir)
        let written = await index.refreshStale(among: records, using: scorer)
        #expect(written == 2)

        let reloaded = EmbeddingVectorIndex(directory: dir)
        #expect(await reloaded.vector(for: records[0].id) != nil)
        #expect(await reloaded.vectors(for: records.map(\.id)).count == 2)
    }

    @Test("staleIDs flags: missing, different model, changed revision")
    func staleDetection() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let scorer = ScriptedSemanticScorer(modelIdentifier: "m1", groups: [["x", "y", "z"]])
        var records = [mem("x", revision: 0), mem("y", revision: 0), mem("z", revision: 0)]

        let index = EmbeddingVectorIndex(directory: dir)
        await index.rebuild(from: records, using: scorer)
        #expect(await index.staleIDs(model: "m1", records: records).isEmpty)

        // a different model version → all stale
        #expect(await index.staleIDs(model: "m2", records: records).count == 3)

        // an edited record (revision bump) → just that one stale
        records[1].revision = 1
        #expect(await index.staleIDs(model: "m1", records: records) == [records[1].id])
    }

    @Test("pruneMissing drops vectors for records that are gone; remove drops one")
    func pruneAndRemove() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let scorer = ScriptedSemanticScorer(groups: [["p", "q", "r"]])
        let records = [mem("p"), mem("q"), mem("r")]
        let index = EmbeddingVectorIndex(directory: dir)
        await index.rebuild(from: records, using: scorer)
        #expect(await index.count == 3)

        await index.pruneMissing(keeping: [records[0].id, records[1].id])
        #expect(await index.count == 2)
        #expect(await index.vector(for: records[2].id) == nil)

        await index.remove(id: records[0].id)
        #expect(await index.count == 1)
    }

    @Test("rebuild after a model change replaces the whole index")
    func rebuildReplaces() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let records = [mem("one"), mem("two")]
        let index = EmbeddingVectorIndex(directory: dir)

        await index.rebuild(from: records, using: ScriptedSemanticScorer(modelIdentifier: "v1", groups: [["one", "two"]]))
        #expect(await index.count == 2)

        await index.rebuild(from: [records[0]], using: ScriptedSemanticScorer(modelIdentifier: "v2", groups: [["one"]]))
        #expect(await index.count == 1)
        #expect(await index.vector(for: records[1].id) == nil)
    }

    @Test("a corrupt index file is treated as empty — canonical memory is never at risk")
    func corruptFileHarmless() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("not json".utf8).write(to: dir.appendingPathComponent("personal-embeddings.json"))
        let index = EmbeddingVectorIndex(directory: dir)
        #expect(await index.count == 0)
        #expect(await index.vector(for: UUID()) == nil)
    }

    @Test("per-owner index files do not share vectors")
    func perOwnerIsolation() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let scorer = ScriptedSemanticScorer(groups: [["secret"]])
        let record = mem("secret")

        let ownerA = EmbeddingVectorIndex(directory: dir, ownerID: "A")
        await ownerA.rebuild(from: [record], using: scorer)
        #expect(await ownerA.vector(for: record.id) != nil)

        let ownerB = EmbeddingVectorIndex(directory: dir, ownerID: "B")
        #expect(await ownerB.vector(for: record.id) == nil)
        #expect(await ownerB.count == 0)
    }
}
