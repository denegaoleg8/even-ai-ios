import Foundation

/// The **portable user export** — deliberately separate from the encrypted R2
/// disaster-recovery backup. This is what a user saves to Files / AirDrops to
/// a Mac: an open, human- *and* machine-readable folder tree (and a `.zip` of
/// it), no encryption, **no secrets**, understandable without any EvenAI
/// software.
///
/// ```
/// EvenAI-PersonalAI-YYYY-MM-DD/
///   README.md
///   manifest.json
///   chats/readable-history.md
///   chats/conversations.jsonl
///   memory/memories.json
///   memory/rules.json
///   memory/style-profile.json
///   memory/projects.json          (memories where category == projects)
///   memory/people.json            (memories where category == people)
///   history/revisions.jsonl
///   history/tombstones.jsonl
/// ```
///
/// The `PersonalDataBundle` machine format (`PersonalDataExporter`) and the
/// encrypted `.eapb` backup are unchanged — this is additive.
enum PersonalDataArchiveBuilder {

    static let archiveSchemaVersion = 1

    struct ArchiveManifest: Codable {
        var format = "evenai.personal-ai.export"
        var archiveSchemaVersion = PersonalDataArchiveBuilder.archiveSchemaVersion
        var bundleSchemaVersion: Int
        var exportedAt: Date
        var appVersion: String
        /// Opaque — a salted hash, never the account id.
        var ownerTag: String?
        var counts: [String: Int]
        var files: [String]
    }

    // MARK: build in-memory

    /// The full set of `(relativePath, bytes)` for the archive.
    static func files(for bundle: PersonalDataBundle, date: Date = .now, appVersion: String = "") throws -> [(path: String, data: Data)] {
        let mem = bundle.memory
        let liveMemories = mem.records
        let projects = liveMemories.filter { $0.category == .projects }
        let people = liveMemories.filter { $0.category == .people }

        var out: [(String, Data)] = []

        out.append(("README.md", Data(readme(bundle: bundle, date: date).utf8)))

        out.append(("manifest.json", try json(ArchiveManifest(
            bundleSchemaVersion: mem.schemaVersion,
            exportedAt: date,
            appVersion: appVersion,
            ownerTag: bundle.manifest.ownerID.map { BackupOwnerTag.tag($0) },
            counts: bundle.recordCounts,
            files: [
                "README.md", "manifest.json",
                "chats/readable-history.md", "chats/conversations.jsonl",
                "memory/memories.json", "memory/rules.json", "memory/style-profile.json",
                "memory/projects.json", "memory/people.json",
                "history/revisions.jsonl", "history/tombstones.jsonl",
            ]
        ))))

        out.append(("chats/readable-history.md", Data(readableHistory(bundle: bundle).utf8)))
        out.append(("chats/conversations.jsonl", jsonl(bundle.messages.map { message in
            [
                "id": message.id.uuidString,
                "conversationID": message.conversationID.uuidString,
                "role": message.role.rawValue,
                "text": message.text,
                "timestamp": iso(message.timestamp),
                "eligibleForMemory": message.eligibleForMemory,
                "deletedAt": message.deletedAt.map(iso) as Any,
            ]
        })))

        out.append(("memory/memories.json", try json(liveMemories)))
        out.append(("memory/rules.json", try json(mem.rules)))
        out.append(("memory/style-profile.json", try json(mem.styleProfile)))
        out.append(("memory/projects.json", try json(projects)))
        out.append(("memory/people.json", try json(people)))

        out.append(("history/revisions.jsonl", jsonl(bundle.revisions.map { revision in
            [
                "revisionID": revision.id.uuidString,
                "recordID": revision.recordID.uuidString,
                "recordKind": revision.recordKind.rawValue,
                "version": revision.version,
                "changedAt": iso(revision.changedAt),
                "source": revision.source.rawValue,
                "reason": revision.reason,
            ]
        })))

        out.append(("history/tombstones.jsonl", jsonl(tombstones(bundle: bundle))))

        return out
    }

    // MARK: write to disk / zip

    /// Write the folder tree into `parent` and return the archive folder URL.
    @discardableResult
    static func writeArchive(_ bundle: PersonalDataBundle, into parent: URL, date: Date = .now, appVersion: String = "") throws -> URL {
        let folder = parent.appendingPathComponent(folderName(date), isDirectory: true)
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for (path, data) in try files(for: bundle, date: date, appVersion: appVersion) {
            let fileURL = folder.appendingPathComponent(path)
            try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: [.atomic])
        }
        return folder
    }

    /// Build the archive as a single `.zip` at `zipURL` (no disk folder needed).
    @discardableResult
    static func writeZip(_ bundle: PersonalDataBundle, to zipURL: URL, date: Date = .now, appVersion: String = "") throws -> URL {
        let root = folderName(date)
        let entries = try files(for: bundle, date: date, appVersion: appVersion).map {
            StoredZipArchive.Entry(path: "\(root)/\($0.path)", data: $0.data, modified: date)
        }
        try StoredZipArchive.archive(entries).write(to: zipURL, options: [.atomic])
        return zipURL
    }

    // MARK: rendering

    static func folderName(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return "EvenAI-PersonalAI-\(f.string(from: date))"
    }

    private static func readme(bundle: PersonalDataBundle, date: Date) -> String {
        """
        # EvenAI — Personal AI export

        Exported \(iso(date)) · archive schema \(archiveSchemaVersion) · bundle schema \(bundle.memory.schemaVersion)

        This is a complete, portable copy of your Personal AI data. No EvenAI
        software or account is needed to read it.

        - `chats/readable-history.md` — your conversations, plain text.
        - `chats/conversations.jsonl` — one JSON object per message.
        - `memory/*.json` — canonical memories, rules, style profile. Stable
          `id`s, timestamps, provenance (`sourceConversationIDs` /
          `sourceMessageIDs`).
        - `memory/projects.json` / `memory/people.json` — the same records as
          in `memories.json`, filtered for convenience (same ids).
        - `history/revisions.jsonl` — the edit history of records.
        - `history/tombstones.jsonl` — records you deleted (kept so a restore
          never resurrects them).
        - `manifest.json` — schema version, counts, per-file list.

        Timestamps are ISO-8601 UTC. Text is UTF-8. This export contains **no**
        passwords, tokens, API keys, or private keys.
        """
    }

    private static func readableHistory(bundle: PersonalDataBundle) -> String {
        let convsByID = Dictionary(uniqueKeysWithValues: bundle.conversations.map { ($0.id, $0) })
        let grouped = Dictionary(grouping: bundle.messages.filter { $0.deletedAt == nil }) { $0.conversationID }
        let orderedConvIDs = grouped.keys.sorted { a, b in
            let ta = convsByID[a]?.createdAt ?? grouped[a]?.first?.timestamp ?? .distantPast
            let tb = convsByID[b]?.createdAt ?? grouped[b]?.first?.timestamp ?? .distantPast
            return ta < tb
        }

        var lines: [String] = ["# Conversation history", ""]
        for convID in orderedConvIDs {
            let conv = convsByID[convID]
            let msgs = (grouped[convID] ?? []).sorted { $0.timestamp < $1.timestamp }
            let title = conv?.title ?? "Conversation \(msgs.first.map { iso($0.timestamp) } ?? "")"
            lines.append("## \(title)")
            lines.append("")
            for m in msgs {
                let who = m.role == .user ? "**You**" : (m.role == .assistant ? "**Personal AI**" : "**System**")
                lines.append("\(who) · \(iso(m.timestamp))")
                lines.append("")
                lines.append(m.text)
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func tombstones(bundle: PersonalDataBundle) -> [[String: Any]] {
        var rows: [[String: Any]] = []
        for r in bundle.memory.records where r.deletedAt != nil {
            rows.append(["id": r.id.uuidString, "recordKind": "memory", "deletedAt": iso(r.deletedAt!)])
        }
        for r in bundle.memory.rules where r.deletedAt != nil {
            rows.append(["id": r.id.uuidString, "recordKind": "rule", "deletedAt": iso(r.deletedAt!)])
        }
        for c in bundle.conversations where c.deletedAt != nil {
            rows.append(["id": c.id.uuidString, "recordKind": "conversation", "deletedAt": iso(c.deletedAt!)])
        }
        for m in bundle.messages where m.deletedAt != nil {
            rows.append(["id": m.id.uuidString, "recordKind": "message", "deletedAt": iso(m.deletedAt!)])
        }
        return rows
    }

    // MARK: helpers

    private static func json<T: Encodable>(_ value: T) throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try e.encode(value)
    }

    private static func jsonl(_ rows: [[String: Any]]) -> Data {
        var out = Data()
        for row in rows {
            let clean = row.compactMapValues { $0 is NSNull ? nil : $0 }
            if let line = try? JSONSerialization.data(withJSONObject: clean, options: [.sortedKeys, .withoutEscapingSlashes]) {
                out.append(line)
                out.append(0x0A)
            }
        }
        return out
    }

    private static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
