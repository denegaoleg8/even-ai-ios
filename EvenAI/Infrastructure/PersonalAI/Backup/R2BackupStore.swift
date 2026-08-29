import Foundation

/// `BackupStore` for **Cloudflare R2** — the planned first independent
/// disaster-recovery target. It is an *object store adapter only*: it never
/// becomes the primary Personal AI database, the sync database, a G2 source,
/// or a per-request source.
///
/// **No Cloudflare SDK, no Cloudflare API types, no hard-coded credentials.**
/// R2 is reached exclusively through two provider-neutral seams:
/// - `BackupCredentialProviding` — a short-lived, key-scoped **pre-signed
///   URL** from an authenticated Worker (the R2 secret lives only in the
///   Worker),
/// - `BackupObjectTransport` — raw HTTPS `PUT/GET/DELETE/HEAD` over that URL.
///
/// Production wires `NotConfiguredBackupCredentialProvider` +
/// `DormantBackupObjectTransport`, so every call throws harmlessly and the
/// on-device backup (`LocalDirectoryBackupStore`) is unaffected. Nothing about
/// R2 is live until a Worker URL is configured — a later, separate step.
///
/// Object layout (keys are relative; the Worker maps them under the bucket):
/// ```
/// <ownerTag>/catalog.json                          the BackupHandle list
/// <ownerTag>/objects/<version>-<tier>-<id>.eapb     one sealed backup each
/// ```
/// `<ownerTag>` is a salted hash of the Personal AI user id — never the id.
struct R2BackupStore: BackupStore {

    private let credentials: any BackupCredentialProviding
    private let transport: any BackupObjectTransport
    private let ownerTagger: @Sendable (String) -> String

    init(
        credentials: any BackupCredentialProviding,
        transport: any BackupObjectTransport,
        ownerTagger: @escaping @Sendable (String) -> String = { BackupOwnerTag.tag($0) }
    ) {
        self.credentials = credentials
        self.transport = transport
        self.ownerTagger = ownerTagger
    }

    /// Convenience: the production-dormant composition.
    static var dormant: R2BackupStore {
        R2BackupStore(
            credentials: NotConfiguredBackupCredentialProvider(),
            transport: DormantBackupObjectTransport()
        )
    }

    // MARK: keys

    private func catalogKey(_ tag: String) -> String { "\(tag)/catalog.json" }
    private func objectKey(_ tag: String, _ handle: BackupHandle) -> String {
        "\(tag)/objects/\(handle.bundleVersion)-\(handle.tier)-\(handle.id).eapb"
    }

    private struct Catalog: Codable, Sendable {
        var version = 1
        var handles: [BackupHandle] = []
    }

    // MARK: BackupStore

    func putBackup(_ sealed: Data, handle: BackupHandle, ownerID: String) async throws {
        try ensureConfigured()
        let tag = ownerTagger(ownerID)

        // 1. Upload the sealed object first. A failure here throws and leaves
        //    the catalog — hence every prior backup — completely untouched.
        let put = try await credentials.presign(.put, key: objectKey(tag, handle), ownerTag: tag)
        try await transport.put(sealed, to: put.url, headers: put.headers)

        // 2. Publish it by rewriting the catalog. If this fails the new object
        //    is an unreferenced orphan (harmless; pruned later) and readers
        //    still see the previous verified set.
        var catalog = try await loadCatalog(tag: tag)
        catalog.handles.removeAll { $0.id == handle.id }
        catalog.handles.append(handle)
        try await writeCatalog(catalog, tag: tag)
    }

    func listBackups(ownerID: String) async throws -> [BackupHandle] {
        try ensureConfigured()
        let tag = ownerTagger(ownerID)
        let catalog = try await loadCatalog(tag: tag)
        return catalog.handles.sorted { $0.createdAt > $1.createdAt }
    }

    func getBackup(_ handle: BackupHandle, ownerID: String) async throws -> Data {
        try ensureConfigured()
        let tag = ownerTagger(ownerID)
        let get = try await credentials.presign(.get, key: objectKey(tag, handle), ownerTag: tag)
        let data = try await transport.get(get.url)
        guard data.count == handle.sizeBytes || handle.sizeBytes == 0 else {
            throw BackupTransportError.truncated(expected: handle.sizeBytes, got: data.count)
        }
        return data
    }

    func deleteBackup(_ handle: BackupHandle, ownerID: String) async throws {
        try ensureConfigured()
        let tag = ownerTagger(ownerID)
        let del = try await credentials.presign(.delete, key: objectKey(tag, handle), ownerTag: tag)
        try? await transport.delete(del.url)     // object may already be gone
        var catalog = try await loadCatalog(tag: tag)
        catalog.handles.removeAll { $0.id == handle.id }
        try await writeCatalog(catalog, tag: tag)
    }

    // MARK: catalog IO

    private func loadCatalog(tag: String) async throws -> Catalog {
        let get = try await credentials.presign(.get, key: catalogKey(tag), ownerTag: tag)
        do {
            let data = try await transport.get(get.url)
            return (try? JSONDecoder.personalAI.decode(Catalog.self, from: data)) ?? Catalog()
        } catch BackupTransportError.notFound {
            return Catalog()
        }
    }

    private func writeCatalog(_ catalog: Catalog, tag: String) async throws {
        let put = try await credentials.presign(.put, key: catalogKey(tag), ownerTag: tag)
        let data = try JSONEncoder.personalAI.encode(catalog)
        try await transport.put(data, to: put.url, headers: put.headers)
    }

    private func ensureConfigured() throws {
        guard credentials.isConfigured else { throw BackupTransportError.notConfigured }
    }
}
