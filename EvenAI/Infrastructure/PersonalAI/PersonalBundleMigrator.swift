import Foundation

/// Forward-migrates an imported `PersonalDataBundle` to the current bundle
/// schema. Phase 2 has one schema version, so this is an identity pass — but
/// the seam is real: a future v2 → v3 migration is a `case` here, and
/// `PersonalDataImporter` always runs it, so old backups never stop
/// restoring.
enum PersonalBundleMigrator {

    static func migrate(_ bundle: PersonalDataBundle) throws -> PersonalDataBundle {
        var current = bundle
        while current.manifest.schemaVersion < BackupManifest.currentSchemaVersion {
            switch current.manifest.schemaVersion {
            // case 1: current = try v1_to_v2(current)
            default:
                throw ImportError.corrupt("no migration path from schema \(current.manifest.schemaVersion)")
            }
        }
        return current
    }
}
