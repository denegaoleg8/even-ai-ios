import Foundation

/// Phase 1 development storage for Personal AI memory: an `actor` over a
/// single `PersonalMemoryDocument` JSON file. **This is not the final
/// authoritative store** — Phase 2 replaces it with an encrypted local cache
/// in front of a cloud primary. That swap is additive because every record
/// already carries `id` / `remoteID` / `revision` / `syncState` / tombstone
/// fields, and this whole file's state *is* a `PersonalMemoryDocument`, which
/// is exactly the sync / export / restore unit.
///
/// Mirrors `LocalGlassesChatStore`'s pattern: an `actor`, a file `URL`
/// injectable so tests point at a temp directory, writes are best-effort and
/// never block the caller's real work.
actor LocalPersonalMemoryStore: PersonalMemoryStore {

    private let fileURL: URL
    private let ownerID: String?
    private let fileStore: DocumentFileStoring
    private var document: PersonalMemoryDocument
    private var loaded = false

    /// - Parameters:
    ///   - directory: where the document lives. Defaults to Application
    ///     Support. Tests pass a temp dir.
    ///   - ownerID: namespaces the file (`personal-memory-<owner>.json`) so
    ///     per-user isolation is real even in the single-user world.
    ///   - fileStore: how bytes reach disk. `PlaintextDocumentFile` by
    ///     default; `PersonalAIContainer` injects `EncryptedDocumentFile`
    ///     in production (§27).
    init(directory: URL? = nil, ownerID: String? = nil, fileStore: DocumentFileStoring = PlaintextDocumentFile()) {
        let base = directory ?? Self.defaultDirectory()
        let name = ownerID.map { "personal-memory-\($0).json" } ?? "personal-memory.json"
        self.fileURL = base.appendingPathComponent(name)
        self.ownerID = ownerID
        self.fileStore = fileStore
        self.document = .empty
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
        guard let decoded = try? JSONDecoder.personalAI.decode(PersonalMemoryDocument.self, from: bytes) else {
            DiagnosticTrace.log("PERSONAL_AI_MEMORY", "load failed: document unreadable, starting empty")
            return
        }
        if decoded.schemaVersion > PersonalMemoryDocument.currentSchemaVersion {
            DiagnosticTrace.log("PERSONAL_AI_MEMORY", "document schemaVersion=\(decoded.schemaVersion) is newer than supported=\(PersonalMemoryDocument.currentSchemaVersion)")
        }
        document = decoded
    }

    private func persist() {
        document.updatedAt = Date()
        guard let data = try? JSONEncoder.personalAI.encode(document) else { return }
        do {
            try fileStore.write(data, to: fileURL)
        } catch {
            DiagnosticTrace.log("PERSONAL_AI_MEMORY", "persist failed: \(type(of: error))")
        }
    }

    // MARK: - Records

    func allMemories() async -> [MemoryRecord] {
        ensureLoaded()
        return document.records
    }

    func memories(matching query: MemoryQuery) async -> [MemoryRecord] {
        ensureLoaded()
        return MemoryQueryEvaluator.apply(query, to: document.records)
    }

    func upsert(_ records: [MemoryRecord]) async {
        ensureLoaded()
        for record in records {
            if let idx = document.records.firstIndex(where: { $0.id == record.id }) {
                document.records[idx] = record
            } else {
                document.records.append(record)
            }
        }
        persist()
    }

    func setMemoryEnabled(id: UUID, enabled: Bool) async {
        mutateRecord(id) { $0.enabled = enabled }
    }

    func setMemoryStatus(id: UUID, status: MemoryStatus) async {
        mutateRecord(id) {
            $0.status = status
            if status == .deleted { $0.deletedAt = Date() }
        }
    }

    func setMemoryConfirmed(id: UUID, confirmed: Bool, pinned: Bool) async {
        mutateRecord(id) {
            $0.userConfirmed = confirmed
            $0.pinned = pinned
            if confirmed { $0.confidence = max($0.confidence, 0.95) }
        }
    }

    func deleteMemory(id: UUID) async {
        mutateRecord(id) {
            $0.status = .deleted
            $0.deletedAt = Date()
            $0.enabled = false
        }
    }

    // MARK: - Rules

    func allRules() async -> [Rule] {
        ensureLoaded()
        return document.rules.filter { $0.deletedAt == nil }
    }

    func upsertRule(_ rule: Rule) async {
        ensureLoaded()
        if let idx = document.rules.firstIndex(where: { $0.id == rule.id }) {
            document.rules[idx] = rule
        } else {
            document.rules.append(rule)
        }
        persist()
    }

    func setRuleEnabled(id: UUID, enabled: Bool) async {
        ensureLoaded()
        guard let idx = document.rules.firstIndex(where: { $0.id == id }) else { return }
        var updated = document.rules[idx].touched()
        updated.enabled = enabled
        document.rules[idx] = updated
        persist()
    }

    func deleteRule(id: UUID) async {
        ensureLoaded()
        guard let idx = document.rules.firstIndex(where: { $0.id == id }) else { return }
        document.rules[idx].deletedAt = Date()
        document.rules[idx].enabled = false
        persist()
    }

    // MARK: - Style

    func styleProfile() async -> PersonalAIStyleProfile {
        ensureLoaded()
        return document.styleProfile
    }

    func updateStyleProfile(_ profile: PersonalAIStyleProfile) async {
        ensureLoaded()
        document.styleProfile = profile
        persist()
    }

    // MARK: - Global switches

    func isMemoryEnabledGlobally() async -> Bool {
        ensureLoaded()
        return document.memoryEnabledGlobally
    }

    func setMemoryEnabledGlobally(_ enabled: Bool) async {
        ensureLoaded()
        document.memoryEnabledGlobally = enabled
        persist()
    }

    func markConversationDoNotRemember(_ conversationID: UUID, _ doNotRemember: Bool) async {
        ensureLoaded()
        if doNotRemember { document.doNotRememberConversationIDs.insert(conversationID) }
        else { document.doNotRememberConversationIDs.remove(conversationID) }
        persist()
    }

    func isConversationExcluded(_ conversationID: UUID) async -> Bool {
        ensureLoaded()
        return document.doNotRememberConversationIDs.contains(conversationID)
    }

    func excludedConversationIDs() async -> Set<UUID> {
        ensureLoaded()
        return document.doNotRememberConversationIDs
    }

    // MARK: - Portability

    func export() async -> PersonalMemoryDocument {
        ensureLoaded()
        return document
    }

    func replaceAll(with document: PersonalMemoryDocument) async {
        loaded = true
        self.document = document
        persist()
    }

    // MARK: - Phase 2: sync state & revisions

    func loadSyncState() async -> PersonalSyncState {
        ensureLoaded()
        return document.syncState
    }

    func saveSyncState(_ state: PersonalSyncState) async {
        ensureLoaded()
        document.syncState = state
        persist()
    }

    func appendRevision(_ revision: RecordRevision) async {
        ensureLoaded()
        document.revisions.append(revision)
        pruneRevisions(recordID: revision.recordID)
        persist()
    }

    func revisions(recordID: UUID) async -> [RecordRevision] {
        ensureLoaded()
        return document.revisions.filter { $0.recordID == recordID }.sorted { $0.changedAt < $1.changedAt }
    }

    func allRevisions() async -> [RecordRevision] {
        ensureLoaded()
        return document.revisions
    }

    /// Bound history growth: full retention for a `userConfirmed` memory,
    /// last-N for anything inferred (see `RecordRevision` retention rules).
    private func pruneRevisions(recordID: UUID) {
        let isConfirmed = document.records.first(where: { $0.id == recordID })?.userConfirmed ?? false
        guard !isConfirmed else { return }
        let forRecord = document.revisions.enumerated().filter { $0.element.recordID == recordID }
        guard forRecord.count > RecordRevision.inferredRetention else { return }
        let dropCount = forRecord.count - RecordRevision.inferredRetention
        let indicesToDrop = Set(forRecord.sorted { $0.element.changedAt < $1.element.changedAt }.prefix(dropCount).map { $0.offset })
        document.revisions = document.revisions.enumerated().filter { !indicesToDrop.contains($0.offset) }.map { $0.element }
    }

    // MARK: - Helpers

    private func mutateRecord(_ id: UUID, _ transform: (inout MemoryRecord) -> Void) {
        ensureLoaded()
        guard let idx = document.records.firstIndex(where: { $0.id == id }) else { return }
        var updated = document.records[idx].touched()
        transform(&updated)
        document.records[idx] = updated
        persist()
    }
}

extension JSONEncoder {
    static var personalAI: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var personalAI: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
