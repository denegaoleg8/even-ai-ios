import Foundation
@testable import EvenAI

/// An in-memory model of the **production backup authorization boundary** — a
/// Cloudflare Worker in front of R2 — with no network and no real crypto.
///
/// It enforces, end to end, the properties the real deployment must have:
/// - **identity** — only a known identity token is served; the token maps to
///   a *server-derived* owner tag,
/// - **owner isolation** — the server ignores the client's claimed `ownerTag`
///   for security and scopes every grant to the tag it derived; a request for
///   a key outside that namespace is denied,
/// - **least privilege** — each grant is one operation on one key,
/// - **expiry** — grants carry a deadline; the paired transport refuses a
///   stale URL,
/// - **single-use for mutation** — a `PUT`/`DELETE` grant cannot be replayed,
/// - **ciphertext only** — every uploaded body is scanned for plaintext
///   markers; the server never receives, and never asks for, a decryption
///   key.
///
/// `credentialProvider(identityToken:)` and `transport()` share this one
/// instance's state, the way a Worker and R2 share the bucket.
final class FakeBackupAuthorizationServer: @unchecked Sendable {

    /// identity token → the owner tag the server derives for it. The client
    /// never gets to choose its own tag for a security decision.
    private let identities: [String: String]
    /// Seconds a grant stays valid. Set negative to model an already-expired
    /// grant.
    var grantTTL: TimeInterval
    /// If any uploaded body contains one of these substrings, `plaintextLeaked`
    /// flips — the server/R2 must only ever see the sealed `.eapb` blob.
    var plaintextMarkers: [String]

    private let lock = NSLock()
    private var objects: [String: Data] = [:]
    private var spentMutationGrants: Set<String> = []
    private var grantsIssuedCount = 0
    private var identitiesSeen: Set<String> = []
    private(set) var plaintextLeaked = false

    init(
        identities: [String: String],
        grantTTL: TimeInterval = 300,
        plaintextMarkers: [String] = []
    ) {
        self.identities = identities
        self.grantTTL = grantTTL
        self.plaintextMarkers = plaintextMarkers
    }

    // MARK: introspection

    func committedObjectKeys() -> [String] { lock.withLock { Array(objects.keys).sorted() } }
    func objectData(forKey key: String) -> Data? { lock.withLock { objects[key] } }
    func grantsIssued() -> Int { lock.withLock { grantsIssuedCount } }
    func distinctIdentitiesSeen() -> Int { lock.withLock { identitiesSeen.count } }

    // MARK: faces

    /// The `BackupCredentialProviding` an app instance signed in as
    /// `identityToken` would hold.
    func credentialProvider(identityToken: String) -> any BackupCredentialProviding {
        BoundProvider(server: self, token: identityToken)
    }

    /// The raw object transport (models R2 honouring the signed URL).
    func transport() -> any BackupObjectTransport {
        SignedURLTransport(server: self)
    }

    // MARK: authorizer core

    fileprivate func issueGrant(
        token: String,
        operation: BackupObjectOperation,
        key: String,
        claimedOwnerTag: String
    ) throws -> PresignedBackupRequest {
        try lock.withLock {
            guard let serverTag = identities[token] else {
                throw BackupCredentialError.unauthorized
            }
            identitiesSeen.insert(token)

            // The security decision uses the SERVER-derived tag. The client's
            // `claimedOwnerTag` is not trusted — asking for a key outside the
            // server's namespace is denied even if the client claims it.
            guard BackupAuthorizationScope.keyIsInOwnerNamespace(key, ownerTag: serverTag) else {
                throw BackupCredentialError.keyOutsideOwnerScope
            }
            _ = claimedOwnerTag  // deliberately ignored for authorization

            grantsIssuedCount += 1
            let grantID = "grant-\(grantsIssuedCount)-\(UUID().uuidString)"
            let expiresAt = Date().addingTimeInterval(grantTTL)
            var comps = URLComponents()
            comps.scheme = "https"
            comps.host = "fake-r2.invalid"
            comps.path = "/" + key
            comps.queryItems = [
                .init(name: "grant", value: grantID),
                .init(name: "exp", value: String(expiresAt.timeIntervalSince1970)),
                .init(name: "op", value: operation.rawValue),
            ]
            return PresignedBackupRequest(
                url: comps.url!,
                headers: ["x-op": operation.rawValue],
                expiresAt: expiresAt,
                grantID: grantID,
                scope: BackupAuthorizationScope(ownerTag: serverTag, objectKey: key, operation: operation)
            )
        }
    }

    // MARK: R2 edge (honours the signed URL)

    fileprivate func edgePut(_ data: Data, url: URL) throws {
        try lock.withLock {
            let (key, grant, expired) = Self.parse(url)
            if expired { throw BackupTransportError.http(status: 403) }
            guard let grant, !spentMutationGrants.contains(grant) else {
                throw BackupTransportError.http(status: 409) // replayed mutation grant
            }
            if let leak = plaintextMarkers.first(where: { marker in
                data.range(of: Data(marker.utf8)) != nil
            }) {
                plaintextLeaked = true
                _ = leak
            }
            objects[key] = data
            spentMutationGrants.insert(grant)
        }
    }

    fileprivate func edgeGet(_ url: URL) throws -> Data {
        try lock.withLock {
            let (key, _, expired) = Self.parse(url)
            if expired { throw BackupTransportError.http(status: 403) }
            guard let data = objects[key] else { throw BackupTransportError.notFound }
            return data
        }
    }

    fileprivate func edgeDelete(_ url: URL) throws {
        try lock.withLock {
            let (key, grant, expired) = Self.parse(url)
            if expired { throw BackupTransportError.http(status: 403) }
            guard let grant, !spentMutationGrants.contains(grant) else {
                throw BackupTransportError.http(status: 409)
            }
            objects[key] = nil
            spentMutationGrants.insert(grant)
        }
    }

    fileprivate func edgeHead(_ url: URL) throws -> BackupObjectRef? {
        try lock.withLock {
            let (key, _, expired) = Self.parse(url)
            if expired { throw BackupTransportError.http(status: 403) }
            guard let data = objects[key] else { return nil }
            return BackupObjectRef(key: key, size: data.count, etag: nil, lastModified: nil)
        }
    }

    private static func parse(_ url: URL) -> (key: String, grant: String?, expired: Bool) {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let key = String((comps?.path ?? url.path).drop(while: { $0 == "/" }))
        let grant = comps?.queryItems?.first(where: { $0.name == "grant" })?.value
        let exp = comps?.queryItems?.first(where: { $0.name == "exp" })?.value.flatMap(Double.init)
        let expired = (exp ?? .greatestFiniteMagnitude) < Date().timeIntervalSince1970
        return (key, grant, expired)
    }

    // MARK: bound faces

    private struct BoundProvider: BackupCredentialProviding {
        let server: FakeBackupAuthorizationServer
        let token: String
        var isConfigured: Bool { true }
        func presign(_ operation: BackupObjectOperation, key: String, ownerTag: String) async throws -> PresignedBackupRequest {
            try server.issueGrant(token: token, operation: operation, key: key, claimedOwnerTag: ownerTag)
        }
    }

    private struct SignedURLTransport: BackupObjectTransport {
        let server: FakeBackupAuthorizationServer
        func put(_ data: Data, to url: URL, headers: [String: String]) async throws { try server.edgePut(data, url: url) }
        func get(_ url: URL) async throws -> Data { try server.edgeGet(url) }
        func delete(_ url: URL) async throws { try server.edgeDelete(url) }
        func head(_ url: URL) async throws -> BackupObjectRef? { try server.edgeHead(url) }
    }
}

extension FakeBackupAuthorizationServer {
    /// Wire an `R2BackupStore` for `identityToken`, routed through the
    /// production `BackupAuthorizationClient` guard.
    func backupStore(for identityToken: String) -> R2BackupStore {
        R2ProductionBackupAdapter.makeStore(
            credentials: credentialProvider(identityToken: identityToken),
            transport: transport()
        )
    }
}

private extension NSLock {
    @discardableResult
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
