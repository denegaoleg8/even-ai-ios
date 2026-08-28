import Foundation

/// Which slice of the user's data an export contains. A partial export is
/// still a valid, importable `PersonalDataBundle` — the missing kinds are
/// simply empty, and the manifest counts reflect that.
enum ExportSelection: String, Codable, CaseIterable, Sendable {
    case everything
    case memoriesOnly
    case conversationsOnly

    var displayName: String {
        switch self {
        case .everything: return "All Personal AI Data"
        case .memoriesOnly: return "Memories & Rules"
        case .conversationsOnly: return "Conversations"
        }
    }
}

/// How a restore applies a bundle to the local store.
enum ImportStrategy: String, Codable, Sendable {
    /// Wipe local data, take the bundle verbatim. Used for new-iPhone /
    /// reinstall recovery where there is no local data worth keeping.
    case replaceAll
    /// Keep local data; reconcile the bundle into it (memories via
    /// `MemoryMerger`, messages append-only, tombstones honoured, dedupe by
    /// id). Used when a user restores a backup on a device that already has
    /// data.
    case merge
}

struct ImportResult: Equatable, Sendable {
    var memoriesImported: Int
    var rulesImported: Int
    var conversationsImported: Int
    var messagesImported: Int
    var revisionsImported: Int
    var duplicatesSkipped: Int
    var tombstonesHonoured: Int
    var succeeded: Bool
    var errorCode: String?

    static let failed = ImportResult(
        memoriesImported: 0, rulesImported: 0, conversationsImported: 0,
        messagesImported: 0, revisionsImported: 0, duplicatesSkipped: 0,
        tombstonesHonoured: 0, succeeded: false, errorCode: "restore-failed"
    )
}

enum ImportError: Error, Equatable, Sendable {
    case notAFile
    case unreadable
    case unrecognizedFormat
    case schemaTooNew(found: Int, supported: Int)
    case checksumMismatch
    case countMismatch(kind: String, manifest: Int, actual: Int)
    case missingRequiredField(String)
    case corrupt(String)

    var code: String {
        switch self {
        case .notAFile: return "not-a-file"
        case .unreadable: return "unreadable"
        case .unrecognizedFormat: return "unrecognized-format"
        case .schemaTooNew: return "schema-too-new"
        case .checksumMismatch: return "checksum-mismatch"
        case .countMismatch: return "count-mismatch"
        case .missingRequiredField: return "missing-field"
        case .corrupt: return "corrupt"
        }
    }

    var userFacingMessage: String {
        switch self {
        case .notAFile, .unreadable:
            return "That file couldn't be read."
        case .unrecognizedFormat:
            return "That isn't an EvenAI Personal AI backup."
        case .schemaTooNew:
            return "This backup was made by a newer version of EvenAI. Update the app and try again."
        case .checksumMismatch, .corrupt:
            return "This backup is corrupted and was not restored. Your existing data is unchanged."
        case .countMismatch, .missingRequiredField:
            return "This backup is incomplete and was not restored. Your existing data is unchanged."
        }
    }
}

/// The outcome of one sync / backup / restore operation, for observable UI
/// state. Errors are short codes only — never memory content.
enum PersonalCloudOperationStatus: Equatable, Sendable {
    case idle
    case running
    case succeeded(at: Date)
    case failed(code: String)
}
