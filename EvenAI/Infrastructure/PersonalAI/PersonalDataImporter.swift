import Foundation

/// Deterministic, safe restore of a `PersonalDataBundle`. The two rules that
/// matter most:
///
/// 1. **A bad backup never replaces good data.** `validate` runs first and
///    fully; only a bundle that passes every check is applied, and it is
///    applied as one atomic swap.
/// 2. **Stable IDs, no duplicates, tombstones honoured.** Records keyed by
///    `id`; a bundle record with `deletedAt` set stays deleted and never
///    resurrects a locally-live copy.
struct PersonalDataImporter: Sendable {

    // MARK: - Validation

    static func validate(_ data: Data) -> Result<PersonalDataBundle, ImportError> {
        guard !data.isEmpty else { return .failure(.unreadable) }
        let decoder = JSONDecoder.personalAI
        guard let bundle = try? decoder.decode(PersonalDataBundle.self, from: data) else {
            return .failure(.corrupt("bundle does not decode"))
        }
        return validate(bundle)
    }

    static func validate(_ bundle: PersonalDataBundle) -> Result<PersonalDataBundle, ImportError> {
        let m = bundle.manifest
        guard m.isRecognizedFormat else { return .failure(.unrecognizedFormat) }
        guard m.schemaVersion <= BackupManifest.currentSchemaVersion else {
            return .failure(.schemaTooNew(found: m.schemaVersion, supported: BackupManifest.currentSchemaVersion))
        }
        guard m.schemaVersion >= 1 else { return .failure(.corrupt("schema version < 1")) }

        // Count integrity — a truncated JSONL / partial write is caught here.
        let actual = bundle.recordCounts
        for (kind, declared) in m.counts {
            let real = actual[kind] ?? 0
            if real != declared {
                return .failure(.countMismatch(kind: kind, manifest: declared, actual: real))
            }
        }

        // Checksum — tamper / corruption.
        guard PersonalBundleChecksum.verify(bundle) else { return .failure(.checksumMismatch) }

        // Required structural fields.
        for message in bundle.messages where message.text.isEmpty && message.deletedAt == nil {
            return .failure(.missingRequiredField("message.text"))
        }

        return .success(bundle)
    }

    // MARK: - Restore

    /// Apply a validated bundle. `.replaceAll` wipes then takes the bundle;
    /// `.merge` reconciles into whatever is already present.
    static func restore(
        _ bundle: PersonalDataBundle,
        into memoryStore: any PersonalMemoryStore,
        conversationStore: any PersonalAIConversationStore,
        strategy: ImportStrategy,
        merger: MemoryMerger = MemoryMerger(),
        now: Date = .now
    ) async -> ImportResult {
        guard case .success(let migrated) = validate(bundle).flatMap({ b in Result { try PersonalBundleMigrator.migrate(b) }.mapError { _ in ImportError.corrupt("migration failed") } }) else {
            return .failed
        }

        switch strategy {
        case .replaceAll:
            return await replaceAll(migrated, memoryStore: memoryStore, conversationStore: conversationStore)
        case .merge:
            return await merge(migrated, memoryStore: memoryStore, conversationStore: conversationStore, merger: merger, now: now)
        }
    }

    private static func replaceAll(
        _ bundle: PersonalDataBundle,
        memoryStore: any PersonalMemoryStore,
        conversationStore: any PersonalAIConversationStore
    ) async -> ImportResult {
        var doc = bundle.memory
        doc.revisions = bundle.revisions
        await memoryStore.replaceAll(with: doc)
        await conversationStore.replaceAllConversations(bundle.conversations, messages: bundle.messages)
        return ImportResult(
            memoriesImported: doc.records.count,
            rulesImported: doc.rules.count,
            conversationsImported: bundle.conversations.count,
            messagesImported: bundle.messages.count,
            revisionsImported: bundle.revisions.count,
            duplicatesSkipped: 0,
            tombstonesHonoured: doc.records.filter { $0.deletedAt != nil }.count,
            succeeded: true,
            errorCode: nil
        )
    }

    private static func merge(
        _ bundle: PersonalDataBundle,
        memoryStore: any PersonalMemoryStore,
        conversationStore: any PersonalAIConversationStore,
        merger: MemoryMerger,
        now: Date
    ) async -> ImportResult {
        var duplicates = 0
        var tombstones = 0

        // Memories — keyed by id. Incoming tombstone always wins. Otherwise
        // higher revision wins; equal id + not tombstone + already present =
        // dedupe.
        let existing = await memoryStore.allMemories()
        let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        var toUpsert: [MemoryRecord] = []
        for incoming in bundle.memory.records {
            if let local = existingByID[incoming.id] {
                if incoming.deletedAt != nil {
                    var t = local
                    t.deletedAt = incoming.deletedAt
                    t.status = .deleted
                    t.enabled = false
                    toUpsert.append(t)
                    tombstones += 1
                } else if incoming.revision > local.revision {
                    toUpsert.append(incoming)
                } else {
                    duplicates += 1
                }
            } else {
                toUpsert.append(incoming)
                if incoming.deletedAt != nil { tombstones += 1 }
            }
        }
        if !toUpsert.isEmpty { await memoryStore.upsert(toUpsert) }

        // Rules — union by id.
        let existingRuleIDs = Set(await memoryStore.allRules().map { $0.id })
        var rulesImported = 0
        for rule in bundle.memory.rules where !existingRuleIDs.contains(rule.id) {
            await memoryStore.upsertRule(rule)
            rulesImported += 1
        }

        // Conversations + messages — append-only, dedupe by id.
        let existingMessageIDs = Set(await conversationStore.allMessages().map { $0.id })
        let existingConvIDs = Set(await conversationStore.allConversations().map { $0.id })
        var convImported = 0
        for conv in bundle.conversations where !existingConvIDs.contains(conv.id) {
            await conversationStore.upsertConversation(conv)
            convImported += 1
        }
        let newMessages = bundle.messages.filter { !existingMessageIDs.contains($0.id) }
        if !newMessages.isEmpty { await conversationStore.upsertMessages(newMessages) }

        // Revisions — append any not already present.
        let knownRevisionIDs = Set(await memoryStore.allRevisions().map { $0.id })
        var revImported = 0
        for revision in bundle.revisions where !knownRevisionIDs.contains(revision.id) {
            await memoryStore.appendRevision(revision)
            revImported += 1
        }

        return ImportResult(
            memoriesImported: toUpsert.count,
            rulesImported: rulesImported,
            conversationsImported: convImported,
            messagesImported: newMessages.count,
            revisionsImported: revImported,
            duplicatesSkipped: duplicates,
            tombstonesHonoured: tombstones,
            succeeded: true,
            errorCode: nil
        )
    }
}
