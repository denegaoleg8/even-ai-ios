import Testing
import Foundation
@testable import EvenAI

@Suite("Personal AI: local store & portability")
struct LocalPersonalMemoryStoreTests {

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PersonalAITests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("records persist across store instances at the same path")
    func persistsAcrossInstances() async {
        let dir = tempDir()
        let store1 = LocalPersonalMemoryStore(directory: dir)
        await store1.upsert([MemoryRecord(category: .profile, canonicalContent: "I live in Kyiv.")])
        await store1.upsertRule(Rule(text: "Keep replies short."))

        let store2 = LocalPersonalMemoryStore(directory: dir)
        let memories = await store2.allMemories()
        let rules = await store2.allRules()
        #expect(memories.count == 1)
        #expect(memories.first?.canonicalContent == "I live in Kyiv.")
        #expect(rules.count == 1)
    }

    @Test("export → replaceAll round-trips the whole document (Phase 2 backup/restore seam)")
    func exportRestoreRoundTrips() async {
        let dir = tempDir()
        let store = LocalPersonalMemoryStore(directory: dir)
        await store.upsert([
            MemoryRecord(category: .projects, canonicalContent: "Building EvenAI."),
            MemoryRecord(category: .preferences, canonicalContent: "I prefer tea."),
        ])
        await store.upsertRule(Rule(text: "Be direct."))
        await store.setMemoryEnabledGlobally(false)

        let document = await store.export()
        #expect(document.records.count == 2)
        #expect(document.rules.count == 1)
        #expect(document.memoryEnabledGlobally == false)
        #expect(document.schemaVersion == PersonalMemoryDocument.currentSchemaVersion)

        // JSON round-trip (ISO8601 on-disk dates are second-precision, so
        // compare structure/ids rather than sub-second Date bit-equality).
        let data = try! JSONEncoder.personalAI.encode(document)
        let decoded = try! JSONDecoder.personalAI.decode(PersonalMemoryDocument.self, from: data)
        let decodedIDs: Set<UUID> = Set(decoded.records.map(\.id))
        let originalIDs: Set<UUID> = Set(document.records.map(\.id))
        let decodedContent: Set<String> = Set(decoded.records.map(\.canonicalContent))
        let originalContent: Set<String> = Set(document.records.map(\.canonicalContent))
        let decodedRuleText: [String] = decoded.rules.map(\.text)
        let originalRuleText: [String] = document.rules.map(\.text)
        #expect(decodedIDs == originalIDs)
        #expect(decodedContent == originalContent)
        #expect(decodedRuleText == originalRuleText)
        #expect(decoded.memoryEnabledGlobally == document.memoryEnabledGlobally)
        #expect(decoded.schemaVersion == document.schemaVersion)

        let fresh = LocalPersonalMemoryStore(directory: tempDir())
        await fresh.replaceAll(with: decoded)
        let restored = await fresh.allMemories()
        #expect(restored.count == 2)
        #expect(await fresh.isMemoryEnabledGlobally() == false)
    }

    @Test("owner id namespaces the file")
    func ownerNamespacing() async {
        let dir = tempDir()
        let a = LocalPersonalMemoryStore(directory: dir, ownerID: "user-a")
        let b = LocalPersonalMemoryStore(directory: dir, ownerID: "user-b")
        await a.upsert([MemoryRecord(category: .profile, canonicalContent: "A's memory.")])
        let bMemories = await b.allMemories()
        #expect(bMemories.isEmpty)
    }

    @Test("deleted records become tombstones, not gone (Phase 2 sync needs the history)")
    func deleteLeavesTombstone() async {
        let store = LocalPersonalMemoryStore(directory: tempDir())
        let record = MemoryRecord(category: .knowledge, canonicalContent: "Ephemeral note.")
        await store.upsert([record])
        await store.deleteMemory(id: record.id)

        let all = await store.allMemories()
        #expect(all.count == 1)
        #expect(all[0].status == .deleted)
        #expect(all[0].deletedAt != nil)

        let active = await store.memories(matching: MemoryQuery(statuses: [.active]))
        #expect(active.isEmpty)
    }

    @Test("MemoryRecord and Rule keep their sync fields through Codable")
    func syncFieldsStable() throws {
        var record = MemoryRecord(category: .profile, canonicalContent: "x")
        record.remoteID = "srv-123"
        record.syncState = .pendingPush
        record.revision = 4
        let data = try JSONEncoder.personalAI.encode(record)
        let decoded = try JSONDecoder.personalAI.decode(MemoryRecord.self, from: data)
        #expect(decoded.id == record.id)
        #expect(decoded.remoteID == "srv-123")
        #expect(decoded.syncState == .pendingPush)
        #expect(decoded.revision == 4)
        #expect(decoded.category == record.category)
        #expect(decoded.canonicalContent == record.canonicalContent)
    }
}
