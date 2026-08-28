import CloudKit

/// Ensures the two Personal AI custom zones exist before a write, and deletes
/// them for a full account wipe. Holds only a "known to exist this session"
/// flag — the source of truth is CloudKit.
actor CloudKitZoneManager {

    private let database: any CloudKitDatabaseFacade
    private var zonesEnsured = false

    init(database: any CloudKitDatabaseFacade) {
        self.database = database
    }

    /// Idempotent. Creates `PersonalAICore` and `PersonalAIChat` if missing.
    func ensureZones() async throws {
        guard !zonesEnsured else { return }
        try await database.ensureZones(CloudKitSchema.allZoneIDs)
        zonesEnsured = true
    }

    /// Deletes both zones — the single operation behind "Delete Personal AI
    /// Account" / `deleteAllData`. Local data handling is the caller's job.
    func deleteAllZones() async throws {
        try await database.deleteZones(CloudKitSchema.allZoneIDs)
        zonesEnsured = false
    }

    /// Force a re-check on the next `ensureZones()` (e.g. after a
    /// `zoneNotFound` during a fetch).
    func invalidate() {
        zonesEnsured = false
    }
}
