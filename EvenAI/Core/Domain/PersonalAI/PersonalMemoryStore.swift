import Foundation

/// The one persistence abstraction for Personal AI memory — rules, records,
/// style profile, and the "do not remember" / global-disable switches, all
/// in one store because they are one memory model.
///
/// Phase 1 has two conformers: `LocalPersonalMemoryStore` (an `actor` over a
/// JSON `PersonalMemoryDocument` on disk — development storage, explicitly
/// not the final authoritative solution) and `InMemoryPersonalMemoryStore`
/// (tests/previews). The record shapes already carry every field a Phase 2
/// `CloudMemoryStore` / `HybridMemoryStore` needs (`id`, `remoteID`,
/// `revision`, `syncState`, tombstones), so that seam is additive.
///
/// `export()` / `import(_:)` operate on the whole `PersonalMemoryDocument`
/// so Phase 2 backup / restore / new-iPhone recovery is already expressible.
protocol PersonalMemoryStore: Sendable {
    // Records
    func allMemories() async -> [MemoryRecord]
    func memories(matching query: MemoryQuery) async -> [MemoryRecord]
    func upsert(_ records: [MemoryRecord]) async
    func setMemoryEnabled(id: UUID, enabled: Bool) async
    func setMemoryStatus(id: UUID, status: MemoryStatus) async
    func setMemoryConfirmed(id: UUID, confirmed: Bool, pinned: Bool) async
    func deleteMemory(id: UUID) async

    // Rules
    func allRules() async -> [Rule]
    func upsertRule(_ rule: Rule) async
    func setRuleEnabled(id: UUID, enabled: Bool) async
    func deleteRule(id: UUID) async

    // Style
    func styleProfile() async -> PersonalAIStyleProfile
    func updateStyleProfile(_ profile: PersonalAIStyleProfile) async

    // Global switches
    func isMemoryEnabledGlobally() async -> Bool
    func setMemoryEnabledGlobally(_ enabled: Bool) async
    func markConversationDoNotRemember(_ conversationID: UUID, _ doNotRemember: Bool) async
    func isConversationExcluded(_ conversationID: UUID) async -> Bool
    func excludedConversationIDs() async -> Set<UUID>

    // Backup / portability seam (usable now, essential for Phase 2)
    func export() async -> PersonalMemoryDocument
    func replaceAll(with document: PersonalMemoryDocument) async
}
