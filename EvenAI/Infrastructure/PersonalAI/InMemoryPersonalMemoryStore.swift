import Foundation

/// `PersonalMemoryStore` backed by a single in-process `PersonalMemoryDocument`.
/// Used by tests and SwiftUI previews. `LocalPersonalMemoryStore` shares the
/// exact same mutation semantics — this one just skips the disk.
actor InMemoryPersonalMemoryStore: PersonalMemoryStore {
    private var document: PersonalMemoryDocument

    init(document: PersonalMemoryDocument = .empty) {
        self.document = document
    }

    // MARK: Records

    func allMemories() async -> [MemoryRecord] { document.records }

    func memories(matching query: MemoryQuery) async -> [MemoryRecord] {
        MemoryQueryEvaluator.apply(query, to: document.records)
    }

    func upsert(_ records: [MemoryRecord]) async {
        for record in records {
            if let idx = document.records.firstIndex(where: { $0.id == record.id }) {
                document.records[idx] = record
            } else {
                document.records.append(record)
            }
        }
        bump()
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

    // MARK: Rules

    func allRules() async -> [Rule] { document.rules.filter { $0.deletedAt == nil } }

    func upsertRule(_ rule: Rule) async {
        if let idx = document.rules.firstIndex(where: { $0.id == rule.id }) {
            document.rules[idx] = rule
        } else {
            document.rules.append(rule)
        }
        bump()
    }

    func setRuleEnabled(id: UUID, enabled: Bool) async {
        if let idx = document.rules.firstIndex(where: { $0.id == id }) {
            document.rules[idx] = document.rules[idx].touched()
            document.rules[idx].enabled = enabled
            bump()
        }
    }

    func deleteRule(id: UUID) async {
        if let idx = document.rules.firstIndex(where: { $0.id == id }) {
            document.rules[idx].deletedAt = Date()
            document.rules[idx].enabled = false
            bump()
        }
    }

    // MARK: Style

    func styleProfile() async -> PersonalAIStyleProfile { document.styleProfile }

    func updateStyleProfile(_ profile: PersonalAIStyleProfile) async {
        document.styleProfile = profile
        bump()
    }

    // MARK: Global switches

    func isMemoryEnabledGlobally() async -> Bool { document.memoryEnabledGlobally }

    func setMemoryEnabledGlobally(_ enabled: Bool) async {
        document.memoryEnabledGlobally = enabled
        bump()
    }

    func markConversationDoNotRemember(_ conversationID: UUID, _ doNotRemember: Bool) async {
        if doNotRemember { document.doNotRememberConversationIDs.insert(conversationID) }
        else { document.doNotRememberConversationIDs.remove(conversationID) }
        bump()
    }

    func isConversationExcluded(_ conversationID: UUID) async -> Bool {
        document.doNotRememberConversationIDs.contains(conversationID)
    }

    func excludedConversationIDs() async -> Set<UUID> { document.doNotRememberConversationIDs }

    // MARK: Portability

    func export() async -> PersonalMemoryDocument { document }

    func replaceAll(with document: PersonalMemoryDocument) async {
        self.document = document
    }

    // MARK: - Helpers

    private func mutateRecord(_ id: UUID, _ transform: (inout MemoryRecord) -> Void) {
        guard let idx = document.records.firstIndex(where: { $0.id == id }) else { return }
        var updated = document.records[idx].touched()
        transform(&updated)
        document.records[idx] = updated
        bump()
    }

    private func bump() {
        document.updatedAt = Date()
    }
}

/// Shared query evaluation so `InMemoryPersonalMemoryStore` and
/// `LocalPersonalMemoryStore` filter identically.
enum MemoryQueryEvaluator {
    static func apply(_ query: MemoryQuery, to records: [MemoryRecord]) -> [MemoryRecord] {
        records.filter { record in
            if record.deletedAt != nil, query.statuses?.contains(.deleted) != true { return false }
            if let categories = query.categories, !categories.contains(record.category) { return false }
            if let statuses = query.statuses, !statuses.contains(record.status) { return false }
            if !query.includeDisabled, !record.enabled { return false }
            if let scope = query.scope, record.scope != scope, record.scope != .global { return false }
            if let search = query.searchText, !search.isEmpty {
                let haystack = (record.canonicalContent + " " + record.entities.joined(separator: " ")).lowercased()
                if !haystack.contains(search.lowercased()) { return false }
            }
            return true
        }
    }
}
