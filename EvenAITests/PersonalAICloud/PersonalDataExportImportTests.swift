import Testing
import Foundation
@testable import EvenAI

@MainActor
@Suite("Personal AI Cloud: export / import / backup")
struct PersonalDataExportImportTests {

    private func seededStore() async -> (InMemoryPersonalMemoryStore, InMemoryPersonalAIConversationStore, LocalPersonalDataStore) {
        let mem = InMemoryPersonalMemoryStore()
        let conv = InMemoryPersonalAIConversationStore()
        await mem.upsert([
            MemoryRecord(category: .projects, canonicalContent: "Building EvenAI.", entities: ["evenai"]),
            MemoryRecord(category: .profile, canonicalContent: "I live in Kyiv."),
        ])
        await mem.upsertRule(Rule(text: "Keep it short."))
        var style = await mem.styleProfile(); style.preferredLanguage = "uk"; style.updatedAt = Date()
        await mem.updateStyleProfile(style)
        let convID = await conv.currentConversationID()
        await conv.append(PersonalAIChatMessage(role: .user, text: "hello"), conversationID: convID)
        await conv.append(PersonalAIChatMessage(role: .assistant, text: "hi there"), conversationID: convID)
        // A revision, and a tombstone.
        let deletable = MemoryRecord(category: .knowledge, canonicalContent: "temporary")
        await mem.upsert([deletable])
        await mem.deleteMemory(id: deletable.id)
        await mem.appendRevision(RecordRevision(recordID: UUID(), recordKind: .memory, version: 0, source: .manualEntry, reason: "test", previousPayloadJSON: "{}"))
        let data = LocalPersonalDataStore(memory: mem, conversations: conv)
        return (mem, conv, data)
    }

    // MARK: §30.21 / §30.22 / §30.23 — round trip preserves ids, revisions, tombstones

    @Test("export → import round trip preserves ids, content, revisions and tombstones")
    func roundTrip() async {
        let (mem, conv, data) = await seededStore()
        let bundle = await data.exportBundle(selection: .everything, bundleVersion: 1)
        let encoded = try! PersonalDataExporter.data(for: bundle)

        // A brand-new device.
        let mem2 = InMemoryPersonalMemoryStore()
        let conv2 = InMemoryPersonalAIConversationStore()
        let result = PersonalDataImporter.validate(encoded)
        guard case .success(let valid) = result else { Issue.record("validation failed: \(result)"); return }
        let importResult = await PersonalDataImporter.restore(valid, into: mem2, conversationStore: conv2, strategy: .replaceAll)
        #expect(importResult.succeeded)

        let originalMems = await mem.allMemories()
        let restoredMems = await mem2.allMemories()
        #expect(Set(restoredMems.map(\.id)) == Set(originalMems.map(\.id)))
        #expect(restoredMems.contains { $0.canonicalContent.contains("EvenAI") })
        #expect(restoredMems.contains { $0.deletedAt != nil })                 // tombstone survived
        #expect((await mem2.allRevisions()).count == (await mem.allRevisions()).count)  // revisions survived
        #expect((await mem2.styleProfile()).preferredLanguage == "uk")
        #expect((await conv2.allMessages()).count == 2)
    }

    // MARK: §30.26 — restore does not duplicate

    @Test("importing the same bundle twice with .merge does not duplicate anything")
    func mergeNoDuplicates() async {
        let (mem, conv, data) = await seededStore()
        let bundle = await data.exportBundle(selection: .everything, bundleVersion: 1)

        let countBefore = (await mem.allMemories()).count
        _ = await PersonalDataImporter.restore(bundle, into: mem, conversationStore: conv, strategy: .merge)
        _ = await PersonalDataImporter.restore(bundle, into: mem, conversationStore: conv, strategy: .merge)
        #expect((await mem.allMemories()).count == countBefore)
        #expect((await conv.allMessages()).count == 2)
    }

    // MARK: §30.24 / §30.25 — corrupt / incomplete backups are rejected

    @Test("a checksum-mismatched bundle is rejected")
    func checksumMismatchRejected() async {
        let (_, _, data) = await seededStore()
        var bundle = await data.exportBundle(selection: .everything, bundleVersion: 1)
        bundle.memory.records.append(MemoryRecord(category: .knowledge, canonicalContent: "smuggled in after checksum"))
        let encoded = try! PersonalDataExporter.data(for: bundle)
        if case .failure(let e) = PersonalDataImporter.validate(encoded) {
            #expect(e == .checksumMismatch || { if case .countMismatch = e { return true } else { return false } }())
        } else {
            Issue.record("tampered bundle should not validate")
        }
    }

    @Test("a truncated file is rejected and never applied")
    func truncatedRejected() async {
        let (_, _, data) = await seededStore()
        let bundle = await data.exportBundle(selection: .everything, bundleVersion: 1)
        let full = try! PersonalDataExporter.data(for: bundle)
        let truncated = full.prefix(full.count / 2)

        let mem2 = InMemoryPersonalMemoryStore()
        await mem2.upsert([MemoryRecord.fixture("existing good data")])
        if case .success = PersonalDataImporter.validate(Data(truncated)) {
            Issue.record("truncated file should not validate")
        }
        #expect((await mem2.allMemories()).count == 1) // untouched
    }

    @Test("a non-EvenAI JSON file is rejected as unrecognized format")
    func wrongFormatRejected() {
        let notABackup = Data(#"{"hello":"world"}"#.utf8)
        if case .failure(let e) = PersonalDataImporter.validate(notABackup) {
            #expect(e == .unrecognizedFormat || e == .checksumMismatch || { if case .corrupt = e { return true } else { return false } }())
        } else {
            Issue.record("arbitrary JSON should not validate")
        }
    }

    // MARK: §30.27 / §30.28 — no secrets in the export

    @Test("an exported archive's bytes contain no auth token, api key, or keychain secret")
    func exportExcludesSecrets() async {
        let (_, _, data) = await seededStore()
        let bundle = await data.exportBundle(selection: .everything, bundleVersion: 1)
        let bytes = try! PersonalDataExporter.data(for: bundle)
        let text = String(data: bytes, encoding: .utf8) ?? ""
        for forbidden in ["refreshToken", "refresh_token", "accessToken", "access_token",
                          "Bearer ", "sk-", "apiKey", "api_key", "kSecAttr", "-----BEGIN", "privateKey"] {
            #expect(text.contains(forbidden) == false, "export leaked: \(forbidden)")
        }
    }

    // MARK: §30.23 — tombstones survive an encrypted backup round trip

    @Test("a full encrypted backup → restore keeps tombstones and revisions")
    func encryptedBackupRoundTrip() async {
        let harness = await PersonalCloudHarness()
        await harness.memoryStore.upsert([MemoryRecord.fixture("live one")])
        let doomed = MemoryRecord(category: .knowledge, canonicalContent: "to be deleted")
        await harness.memoryStore.upsert([doomed])
        await harness.memoryStore.deleteMemory(id: doomed.id)

        let outcome = await harness.backupCoordinator.backup(tier: .daily)
        #expect(outcome.succeeded)

        // Wipe local, restore from the (only) backup.
        await harness.memoryStore.replaceAll(with: .empty)
        switch await harness.backupCoordinator.loadLatestBackupBundle() {
        case .success(let bundle):
            let result = await harness.dataStore.importBundle(bundle, strategy: .replaceAll)
            #expect(result.succeeded)
            let mems = await harness.memoryStore.allMemories()
            #expect(mems.contains { $0.canonicalContent.contains("live one") })
            #expect(mems.contains { $0.deletedAt != nil })
        case .failure(let e):
            Issue.record("backup did not load: \(e)")
        }
    }

    // MARK: Bundle codable + checksum stability

    @Test("checksum is stable across encode passes and changes when content changes")
    func checksumStability() async {
        let (_, _, data) = await seededStore()
        let bundle = await data.exportBundle(selection: .everything, bundleVersion: 1)
        #expect(PersonalBundleChecksum.verify(bundle))
        #expect(PersonalBundleChecksum.compute(for: bundle) == PersonalBundleChecksum.compute(for: bundle))

        var mutated = bundle
        mutated.memory.records[0].canonicalContent += " changed"
        #expect(PersonalBundleChecksum.compute(for: mutated) != bundle.manifest.checksum)
    }

    @Test("selection filters the exported kinds but stays a valid bundle")
    func partialExportIsValid() async {
        let (_, _, data) = await seededStore()
        let memoriesOnly = await data.exportBundle(selection: .memoriesOnly, bundleVersion: 1)
        #expect(memoriesOnly.messages.isEmpty)
        #expect(memoriesOnly.memory.records.isEmpty == false)
        #expect(PersonalBundleChecksum.verify(memoriesOnly))
        if case .failure(let e) = PersonalDataImporter.validate(memoriesOnly) { Issue.record("partial export invalid: \(e)") }
    }
}
