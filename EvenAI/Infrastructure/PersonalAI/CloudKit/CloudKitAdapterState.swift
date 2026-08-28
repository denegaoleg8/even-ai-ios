import Foundation

/// Everything the CloudKit adapter persists **locally**: per-record change
/// tags + synthetic revisions (the bridge between the engine's `Int`
/// `baseRevision` model and CloudKit's opaque `recordChangeTag`), the two zone
/// change tokens, and the `PersonalAIUserID ↔ iCloud account` binding.
///
/// It is a **cache, not authority** — dropping it and re-fetching from a `nil`
/// token fully rebuilds the tokens and per-record tags. It is never written to
/// CloudKit (that would be "sync metadata that itself needs syncing").
///
/// Contents are **sync plumbing only** — opaque server strings, integers,
/// dates, and two identifiers (`personalAIUserID`, the iCloud user record
/// name). **No auth tokens, passwords, API keys, or memory content.**
struct CloudKitAdapterState: Codable, Hashable, Sendable {

    struct RecordState: Codable, Hashable, Sendable {
        var changeTag: String
        var syntheticRevision: Int
        /// Archived `CKRecord` **system fields** (record id, change tag,
        /// timestamps) for the live path's `.ifServerRecordUnchanged` save
        /// policy. Contains no field values / memory content.
        var systemFieldsArchive: Data?
    }

    /// Format version for this file. A file written by a newer adapter than
    /// the one reading it is treated as unreadable → safe reset (metadata
    /// only).
    var adapterStateVersion: Int = CloudKitAdapterState.currentVersion
    static let currentVersion = 1

    /// Keyed `"<zoneName>:<recordName>"`.
    var records: [String: RecordState] = [:]
    var cursor: CloudKitSyncCursor = .empty
    var binding: CloudKitAccountBinding?
    /// Monotonic source for `RecordState.syntheticRevision`, so the engine's
    /// `syncedRevisions` bookkeeping keeps working unchanged.
    var nextSyntheticRevision: Int = 1

    static let empty = CloudKitAdapterState()

    static func key(zone: CloudKitSchema.Zone, recordName: String) -> String {
        "\(zone.zoneName):\(recordName)"
    }

    mutating func takeSyntheticRevision() -> Int {
        defer { nextSyntheticRevision += 1 }
        return nextSyntheticRevision
    }

    /// Whether a decoded file is usable by this adapter build.
    var isReadable: Bool { adapterStateVersion <= CloudKitAdapterState.currentVersion }
}

/// Persistence for `CloudKitAdapterState`.
protocol CloudKitAdapterStateStore: Sendable {
    func load() async -> CloudKitAdapterState
    func save(_ state: CloudKitAdapterState) async
}

/// In-memory store — the deterministic tests, and explicit construction where
/// persistence is not wanted. **Real wiring uses `FileCloudKitAdapterStateStore`
/// (via `CloudKitPersonalCloudService.makePersisted`).**
actor InMemoryCloudKitAdapterStateStore: CloudKitAdapterStateStore {
    private var state: CloudKitAdapterState
    init(_ initial: CloudKitAdapterState = .empty) { self.state = initial }
    func load() async -> CloudKitAdapterState { state }
    func save(_ state: CloudKitAdapterState) async { self.state = state }
}

/// File-backed store. Sealed on disk through the injected `DocumentFileStoring`
/// (`EncryptedDocumentFile` in production, `PlaintextDocumentFile` in tests),
/// the same mechanism the local memory cache uses. Writes are **atomic**
/// (`DocumentFileStoring.write` uses `Data.write(options: [.atomic, …])`).
///
/// **Failure is always safe for canonical data:** a missing, unreadable,
/// corrupt, or too-new file yields `.empty` (a clean re-bootstrap — the
/// adapter re-fetches from a `nil` token and re-binds to the current iCloud
/// account). Nothing here can touch the Personal AI memory store.
actor FileCloudKitAdapterStateStore: CloudKitAdapterStateStore {
    private let url: URL
    private let file: any DocumentFileStoring
    private var cache: CloudKitAdapterState?

    init(url: URL, file: any DocumentFileStoring) {
        self.url = url
        self.file = file
    }

    func load() async -> CloudKitAdapterState {
        if let cache { return cache }

        var loaded = CloudKitAdapterState.empty
        do {
            if let data = try file.read(from: url) {
                if let decoded = try? JSONDecoder().decode(CloudKitAdapterState.self, from: data), decoded.isReadable {
                    loaded = decoded
                } else {
                    DiagnosticTrace.log("PERSONAL_AI_CLOUDKIT", "ADAPTER_STATE_UNREADABLE — safe reset (metadata only)")
                }
            }
        } catch {
            DiagnosticTrace.log("PERSONAL_AI_CLOUDKIT", "ADAPTER_STATE_READ_FAILED code=\(PersonalAISyncEngine.code(for: error)) — safe reset")
        }
        cache = loaded
        return loaded
    }

    func save(_ state: CloudKitAdapterState) async {
        cache = state
        guard let data = try? JSONEncoder().encode(state) else { return }
        do {
            try file.write(data, to: url)
        } catch {
            // A failed metadata write is non-fatal — the in-memory cache holds
            // the current value and the next save retries. Canonical data is
            // untouched regardless.
            DiagnosticTrace.log("PERSONAL_AI_CLOUDKIT", "ADAPTER_STATE_WRITE_FAILED code=\(PersonalAISyncEngine.code(for: error))")
        }
    }
}
