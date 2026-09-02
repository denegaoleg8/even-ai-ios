import Foundation

/// The **one** definition of the canonical, versioned R2 object namespace for
/// Personal AI backups. The version lives *here* and nowhere else — there is no
/// `"backup/v1"` string literal scattered through the codebase.
///
/// ```
/// backup/v1/<ownerTag>/catalog.json                         the committed BackupHandle list
/// backup/v1/<ownerTag>/objects/<bundleVersion>-<tier>-<backupID>.eapb   one sealed snapshot
/// ```
///
/// - `<ownerTag>` is `BackupOwnerTag.tag(canonicalUserID)` — a 64-char lowercase
///   SHA-256 hex string. **Never** a raw user id, email, name, memory text, or
///   conversation text.
/// - Path generation is **validating**: it throws on a malformed owner tag,
///   a malformed / unsafe `backupID` (separators real or percent-encoded,
///   `.` / `..`, control chars), an unknown tier, or a negative bundle version.
/// - `parse(_:)` is the reader. It **never guesses**: a key in an unrecognised
///   namespace version, or one that does not match the exact shape, returns
///   `nil` — it is simply "not one of ours". A future `backup/v2/` can be
///   added to `recognisedVersions` and given its own reader without disturbing
///   v1.
enum BackupObjectNamespace {

    /// The version new objects are written under.
    static let currentVersion = 1
    /// Every version this build can *read* (list / fetch / delete). A key whose
    /// version is not in this set is rejected by `parse` and by
    /// `BackupAuthorizationScope.keyIsInOwnerNamespace`.
    static let recognisedVersions: Set<Int> = [1]

    private static let root = "backup"
    private static let objectsSegment = "objects"
    private static let catalogFilename = "catalog.json"
    private static let objectExtension = "eapb"

    /// The retention tiers a valid object key may carry
    /// (`PersonalAIBackupCoordinator.Tier`).
    static let validTiers: Set<String> = ["incremental", "daily", "weekly", "monthly"]

    enum NamespaceError: Error, Equatable, Sendable {
        case malformedOwnerTag
        case malformedBackupID
        case unsafeBackupID(String)
        case invalidTier
        case invalidBundleVersion
    }

    // MARK: - Generation (validating)

    /// `"backup/v1"`
    static func versionPrefix(_ version: Int = currentVersion) -> String { "\(root)/v\(version)" }

    /// `"backup/v1/<ownerTag>"`
    static func ownerRoot(ownerTag: String, version: Int = currentVersion) throws -> String {
        try validateOwnerTag(ownerTag)
        return "\(versionPrefix(version))/\(ownerTag)"
    }

    /// `"backup/v1/<ownerTag>/objects"` — the prefix an orphan sweep would list.
    static func objectsPrefix(ownerTag: String, version: Int = currentVersion) throws -> String {
        "\(try ownerRoot(ownerTag: ownerTag, version: version))/\(objectsSegment)"
    }

    static func catalogKey(ownerTag: String, version: Int = currentVersion) throws -> String {
        "\(try ownerRoot(ownerTag: ownerTag, version: version))/\(catalogFilename)"
    }

    static func objectKey(
        ownerTag: String,
        bundleVersion: Int,
        tier: String,
        backupID: String,
        version: Int = currentVersion
    ) throws -> String {
        try validateOwnerTag(ownerTag)
        guard bundleVersion >= 0 else { throw NamespaceError.invalidBundleVersion }
        guard validTiers.contains(tier) else { throw NamespaceError.invalidTier }
        try validateBackupID(backupID)
        return "\(versionPrefix(version))/\(ownerTag)/\(objectsSegment)/\(bundleVersion)-\(tier)-\(backupID).\(objectExtension)"
    }

    // MARK: - Reading

    struct Parsed: Equatable, Sendable {
        var version: Int
        var ownerTag: String
        var component: Component

        enum Component: Equatable, Sendable {
            case catalog
            case object(bundleVersion: Int, tier: String, backupID: String)
        }
    }

    /// Parse a key back to its parts, or `nil` for anything that is not an
    /// exactly-shaped key in a **recognised** version. Never throws, never
    /// reinterprets an unknown version.
    static func parse(_ key: String) -> Parsed? {
        guard BackupAuthorizationScope.keyIsWellFormed(key) else { return nil }
        let parts = key.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        // backup / v<N> / <ownerTag> / (catalog.json | objects/<file>)
        guard parts.count >= 4, parts[0] == root else { return nil }
        guard parts[1].hasPrefix("v"), let version = Int(parts[1].dropFirst()),
              recognisedVersions.contains(version) else { return nil }
        let ownerTag = parts[2]
        guard (try? validateOwnerTag(ownerTag)) != nil else { return nil }

        if parts.count == 4, parts[3] == catalogFilename {
            return Parsed(version: version, ownerTag: ownerTag, component: .catalog)
        }
        guard parts.count == 5, parts[3] == objectsSegment else { return nil }
        let filename = parts[4]
        guard filename.hasSuffix(".\(objectExtension)") else { return nil }
        let stem = String(filename.dropLast(objectExtension.count + 1))
        let fields = stem.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 3, let bundleVersion = Int(fields[0]), bundleVersion >= 0,
              validTiers.contains(fields[1]),
              (try? validateBackupID(fields[2])) != nil else { return nil }
        return Parsed(
            version: version, ownerTag: ownerTag,
            component: .object(bundleVersion: bundleVersion, tier: fields[1], backupID: fields[2])
        )
    }

    /// `key` is a well-formed key in a *recognised* version's namespace for
    /// `ownerTag`. (An unrecognised version → `false`.)
    static func isRecognisedVersionKey(_ key: String, ownerTag: String) -> Bool {
        guard let parsed = parse(key) else { return false }
        return parsed.ownerTag == ownerTag
    }

    /// `key` is in the **current** write version's namespace for `ownerTag`.
    static func isCurrentVersionKey(_ key: String, ownerTag: String) -> Bool {
        guard let parsed = parse(key) else { return false }
        return parsed.ownerTag == ownerTag && parsed.version == currentVersion
    }

    /// If `key` begins `"backup/v<N>/"` for a **recognised** `N`, return the
    /// part after that prefix; otherwise return `key` unchanged. Never strips
    /// an unknown version — so an unknown-version key keeps its `backup/vX/`
    /// prefix and then fails an owner-namespace check.
    static func strippingRecognisedVersionPrefix(_ key: String) -> String {
        let parts = key.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == root,
              parts[1].hasPrefix("v"), let version = Int(parts[1].dropFirst()),
              recognisedVersions.contains(version)
        else { return key }
        return String(parts[2])
    }

    // MARK: - Validation

    private static func validateOwnerTag(_ tag: String) throws {
        // ownerTag v1 is exactly 64 lowercase hex characters.
        guard tag.count == 64,
              tag.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) })
        else { throw NamespaceError.malformedOwnerTag }
    }

    private static func validateBackupID(_ id: String) throws {
        guard !id.isEmpty, id.utf8.count <= 128 else { throw NamespaceError.malformedBackupID }
        let lower = id.lowercased()
        for unsafe in ["/", "\\", "..", ".", "%2f", "%5c", "%2e", "\u{0000}"] where lower.contains(unsafe) {
            throw NamespaceError.unsafeBackupID(unsafe)
        }
        guard id.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value != 0x7F }) else {
            throw NamespaceError.unsafeBackupID("control")
        }
        // A conservative charset: ASCII letters, digits, and `-` (UUID shape).
        guard id.allSatisfy({ ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }) else {
            throw NamespaceError.malformedBackupID
        }
    }
}
