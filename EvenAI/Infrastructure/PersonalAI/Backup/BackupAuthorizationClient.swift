import Foundation

/// The **single client-side chokepoint** for reaching the backup object store.
/// Wraps any `BackupCredentialProviding` (in production, a
/// `WorkerBackupCredentialProvider`) and enforces the rules the app must obey
/// even though the authoritative checks are server-side:
///
/// 1. **Never ask outside our own namespace** — a request for a malformed key,
///    or one not under `<ownerTag>/`, is refused locally before it hits the
///    network (`keyIsInOwnerNamespace` also runs `keyIsWellFormed`).
/// 2. **Never use an expired grant** — a grant past `expiresAt` is discarded;
///    the caller must re-request.
/// 3. **Never use an unscoped or mis-scoped grant** — a production grant must
///    carry a `scope`, and that scope must be byte-for-byte the operation,
///    key, and owner tag we asked for. A grant with no scope is refused
///    (`scopeMissing`).
///
/// It conforms to `BackupCredentialProviding` itself, so it slots in
/// transparently wherever the app expects a credential provider — including
/// inside `R2BackupStore`, which now **only** builds itself with this guard in
/// the chain (`R2BackupStore.authorized` / `.dormant`; the raw initializer is
/// private). It holds **no credentials** and makes **no network call** of its
/// own; it only tightens what the wrapped provider returns.
struct BackupAuthorizationClient: BackupCredentialProviding {

    private let upstream: any BackupCredentialProviding

    init(wrapping upstream: any BackupCredentialProviding) {
        // Idempotent — double-wrapping just runs the checks twice, so unwrap.
        if let already = upstream as? BackupAuthorizationClient {
            self.upstream = already.upstream
        } else {
            self.upstream = upstream
        }
    }

    var isConfigured: Bool { upstream.isConfigured }

    func presign(_ operation: BackupObjectOperation, key: String, ownerTag: String) async throws -> PresignedBackupRequest {
        // 1. Local namespace + well-formedness guard.
        guard BackupAuthorizationScope.keyIsInOwnerNamespace(key, ownerTag: ownerTag) else {
            throw BackupCredentialError.keyOutsideOwnerScope
        }

        let grant = try await upstream.presign(operation, key: key, ownerTag: ownerTag)

        // 2. Expiry guard.
        guard !grant.isExpired else {
            throw BackupCredentialError.expired
        }

        // 3. Scope guard — a production grant must be scoped, and the
        //    authoritative (server-derived) scope must be exactly what we asked
        //    for (operation + key + owner tag). This is a real check, not a
        //    tautology: `grant.scope` originates from the authorizer's
        //    response, an independent source from these call arguments, so a
        //    grant issued for a different operation, key, or owner is caught
        //    here. The signed URL's own server-side constraints remain
        //    authoritative.
        guard grant.scope != nil else {
            throw BackupCredentialError.scopeMissing
        }
        guard grant.covers(operation, key: key, ownerTag: ownerTag) else {
            throw BackupCredentialError.scopeMismatch
        }

        return grant
    }
}
