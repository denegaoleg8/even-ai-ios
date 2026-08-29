import Testing
import Foundation
@testable import EvenAI

/// The portable user export — an open folder tree + `.zip`, separate from the
/// encrypted R2 backup, readable without EvenAI, containing no secrets.
@Suite("Backup: portable export archive")
struct PersonalDataArchiveBuilderTests {

    private func sampleBundle() -> PersonalDataBundle {
        let convID = UUID()
        var doc = PersonalMemoryDocument(
            records: [
                MemoryRecord(id: UUID(), ownerID: "user-1", category: .projects, canonicalContent: "Project EvenAI", entities: ["evenai"], sourceConversationIDs: [convID]),
                MemoryRecord(id: UUID(), ownerID: "user-1", category: .people, canonicalContent: "Nadia — designer", entities: ["nadia"]),
                MemoryRecord(id: UUID(), ownerID: "user-1", category: .knowledge, canonicalContent: "Ship weekly", entities: []),
                {
                    var m = MemoryRecord(id: UUID(), ownerID: "user-1", category: .knowledge, canonicalContent: "old fact")
                    m.deletedAt = Date(timeIntervalSince1970: 1_800_000_000); m.status = .deleted
                    return m
                }(),
            ],
            rules: [Rule(ownerID: "user-1", text: "Be concise.")]
        )
        doc.revisions = [
            RecordRevision(recordID: doc.records[0].id, recordKind: .memory, version: 0, source: .manualEntry, reason: "user-edit", previousPayloadJSON: "{}"),
        ]
        let conv = PersonalAIConversation(id: convID, title: "Planning", createdAt: Date(timeIntervalSince1970: 1_700_000_000), messageCount: 2)
        let messages = [
            PersonalAIChatMessage(conversationID: convID, role: .user, text: "what's next", timestamp: Date(timeIntervalSince1970: 1_700_000_100)),
            PersonalAIChatMessage(conversationID: convID, role: .assistant, text: "ship the export", timestamp: Date(timeIntervalSince1970: 1_700_000_200)),
        ]
        return PersonalDataExporter.makeBundle(memory: doc, conversations: [conv], messages: messages,
                                               selection: .everything, bundleVersion: 1, ownerID: "user-1")
    }

    @Test("archive contains exactly the planned file tree")
    func fileTree() throws {
        let files = try PersonalDataArchiveBuilder.files(for: sampleBundle())
        let paths = Set(files.map(\.path))
        #expect(paths == [
            "README.md", "manifest.json",
            "chats/readable-history.md", "chats/conversations.jsonl",
            "memory/memories.json", "memory/rules.json", "memory/style-profile.json",
            "memory/projects.json", "memory/people.json",
            "history/revisions.jsonl", "history/tombstones.jsonl",
        ])
    }

    @Test("readable-history.md is human-readable with roles and timestamps")
    func readableHistory() throws {
        let files = try PersonalDataArchiveBuilder.files(for: sampleBundle())
        let md = String(decoding: files.first { $0.path == "chats/readable-history.md" }!.data, as: UTF8.self)
        #expect(md.contains("## Planning"))
        #expect(md.contains("**You**"))
        #expect(md.contains("**Personal AI**"))
        #expect(md.contains("what's next"))
        #expect(md.contains("ship the export"))
    }

    @Test("conversations.jsonl and history/*.jsonl are one valid JSON object per line")
    func jsonlValid() throws {
        let files = try PersonalDataArchiveBuilder.files(for: sampleBundle())
        for name in ["chats/conversations.jsonl", "history/revisions.jsonl", "history/tombstones.jsonl"] {
            let text = String(decoding: files.first { $0.path == name }!.data, as: UTF8.self)
            let lines = text.split(separator: "\n")
            #expect(!lines.isEmpty, "\(name) is empty")
            for line in lines {
                #expect((try? JSONSerialization.jsonObject(with: Data(line.utf8))) != nil, "bad JSON line in \(name): \(line)")
            }
        }
    }

    @Test("projects.json / people.json are the category-filtered memories, same stable ids")
    func projectsPeopleFiltered() throws {
        let bundle = sampleBundle()
        let files = try PersonalDataArchiveBuilder.files(for: bundle)
        let projects = try JSONDecoder.personalAI.decode([MemoryRecord].self, from: files.first { $0.path == "memory/projects.json" }!.data)
        let people = try JSONDecoder.personalAI.decode([MemoryRecord].self, from: files.first { $0.path == "memory/people.json" }!.data)
        #expect(projects.allSatisfy { $0.category == .projects })
        #expect(people.allSatisfy { $0.category == .people })
        // Same ids as in memories.json.
        let all = try JSONDecoder.personalAI.decode([MemoryRecord].self, from: files.first { $0.path == "memory/memories.json" }!.data)
        #expect(Set(projects.map(\.id)).isSubset(of: Set(all.map(\.id))))
    }

    @Test("tombstones.jsonl lists deleted records so a re-import can't resurrect them")
    func tombstones() throws {
        let files = try PersonalDataArchiveBuilder.files(for: sampleBundle())
        let text = String(decoding: files.first { $0.path == "history/tombstones.jsonl" }!.data, as: UTF8.self)
        #expect(text.contains("\"recordKind\":\"memory\""))
        #expect(text.contains("\"deletedAt\""))
    }

    @Test("manifest.json carries schema version + counts + an owner *tag* (not the id)")
    func manifest() throws {
        let files = try PersonalDataArchiveBuilder.files(for: sampleBundle())
        let manifest = try JSONDecoder.personalAI.decode(PersonalDataArchiveBuilder.ArchiveManifest.self,
                                                from: files.first { $0.path == "manifest.json" }!.data)
        #expect(manifest.format == "evenai.personal-ai.export")
        #expect(manifest.archiveSchemaVersion == PersonalDataArchiveBuilder.archiveSchemaVersion)
        #expect((manifest.counts["memory"] ?? 0) >= 3)
        #expect(manifest.ownerTag == BackupOwnerTag.tag("user-1"))
        #expect(manifest.ownerTag?.contains("user-1") == false)
    }

    @Test("the whole archive contains no auth tokens / secrets")
    func noSecrets() throws {
        let files = try PersonalDataArchiveBuilder.files(for: sampleBundle())
        for (path, data) in files {
            let text = String(decoding: data, as: UTF8.self).lowercased()
            for forbidden in ["\"password\"", "accesstoken", "refreshtoken", "\"apikey\"", "bearer ",
                              "authorization", "privatekey", "keychain", "cloudflare", "aws_secret"] {
                #expect(!text.contains(forbidden), "\(path) contains \(forbidden)")
            }
        }
    }

    @Test("writeZip produces a standard zip whose STORE entries round-trip byte-for-byte")
    func zipRoundTrips() throws {
        let bundle = sampleBundle()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zip-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let zipURL = dir.appendingPathComponent("export.zip")
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        try PersonalDataArchiveBuilder.writeZip(bundle, to: zipURL, date: date)

        let zipData = try Data(contentsOf: zipURL)
        #expect(zipData.prefix(4) == Data([0x50, 0x4b, 0x03, 0x04])) // PK\x03\x04
        let entries = TestStoredZipReader.entries(zipData)
        let root = PersonalDataArchiveBuilder.folderName(date)
        let source = try PersonalDataArchiveBuilder.files(for: bundle, date: date)
        for (path, data) in source {
            #expect(entries["\(root)/\(path)"] == data, "zip entry \(path) differs")
        }
    }

    @Test("writeArchive lays the tree out on disk")
    func writeArchiveOnDisk() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("arc-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let folder = try PersonalDataArchiveBuilder.writeArchive(sampleBundle(), into: parent)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("README.md").path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("memory/memories.json").path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("history/tombstones.jsonl").path))
    }
}
