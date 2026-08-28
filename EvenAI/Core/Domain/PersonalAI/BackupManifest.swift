import Foundation

/// The header of a `PersonalDataBundle` — enough to identify, validate and
/// migrate a backup / export **without an EvenAI server**. `checksum` covers
/// the entire bundle payload except the manifest itself, so a truncated or
/// tampered file is rejected on import.
struct BackupManifest: Codable, Hashable, Sendable {
    /// Stable format identifier — an importer checks this before anything
    /// else.
    static let formatIdentifier = "evenai.personal-ai.bundle"
    /// Bundle schema version. Import migrates anything `<= currentSchemaVersion`
    /// forward and rejects anything newer.
    static let currentSchemaVersion = 1

    var format: String
    var schemaVersion: Int
    /// Increments once per backup produced on this device.
    var bundleVersion: Int
    var createdAt: Date
    var deviceID: String?
    var ownerID: String?
    var appVersion: String
    /// Per-`PersonalRecordKind` record counts (raw string keys so the
    /// manifest stays forward-compatible if kinds are added).
    var counts: [String: Int]
    /// SHA-256 (hex) of the canonical JSON encoding of the bundle with the
    /// manifest field omitted.
    var checksum: String

    init(
        format: String = BackupManifest.formatIdentifier,
        schemaVersion: Int = BackupManifest.currentSchemaVersion,
        bundleVersion: Int,
        createdAt: Date = .now,
        deviceID: String? = nil,
        ownerID: String? = nil,
        appVersion: String = "",
        counts: [String: Int] = [:],
        checksum: String = ""
    ) {
        self.format = format
        self.schemaVersion = schemaVersion
        self.bundleVersion = bundleVersion
        self.createdAt = createdAt
        self.deviceID = deviceID
        self.ownerID = ownerID
        self.appVersion = appVersion
        self.counts = counts
        self.checksum = checksum
    }

    var isRecognizedFormat: Bool { format == Self.formatIdentifier }
    var isSupportedSchema: Bool { schemaVersion >= 1 && schemaVersion <= Self.currentSchemaVersion }
}
