import Foundation

/// A compile-time capability: proof that a remote-capable `R2BackupStore`
/// (one with a live credential provider + transport) is being composed **here**,
/// at the single audited production boundary.
///
/// Its initializer is `fileprivate`, so `R2ProductionBackupAdapter` — defined
/// in this file — is the only code in the entire module that can mint one.
/// `R2BackupStore.authorized(...)` requires it, so no other production code and
/// no test can build a remote-capable store by any other path. `R2BackupStore`
/// itself has a `private` initializer and its only unauthenticated form
/// (`.dormant`) reaches no network. Together this makes "you cannot get a
/// remote-capable backup store except through `R2ProductionBackupAdapter`" a
/// fact the compiler enforces, not a convention.
struct RemoteBackupCompositionAuthority {
    fileprivate init() {}
}

/// The **named production boundary** for Personal AI disaster-recovery
/// backups to Cloudflare R2. It is a *composition point only* — it holds no
/// Cloudflare SDK, no account id, no endpoint constant, no R2 access key, and
/// no identity token.
///
/// R2 is reached exclusively through the two provider-neutral seams:
/// - `BackupCredentialProviding` — a short-lived, single-operation,
///   owner-scoped grant from an authenticated authorizer (a Cloudflare
///   Worker). The R2 secret lives only in the Worker.
/// - `BackupObjectTransport` — raw HTTPS over the granted URL, no credentials
///   of its own.
///
/// Every store this factory produces routes its credential provider through
/// `BackupAuthorizationClient`, so the app can never use an expired or
/// mis-scoped grant, and never asks for a key outside its own namespace.
///
/// A shipping build can only ever hold `inert` — nothing here can reach real
/// R2 without a configured `BackupCredentialProviding` **and** a live
/// `BackupObjectTransport`, both of which are injected, never constructed
/// here.
enum R2ProductionBackupAdapter {

    /// Compose a backup store from injected auth + transport. Delegates to
    /// `R2BackupStore.authorized`, so the client-side authorization guard is
    /// always in the chain (the raw `R2BackupStore` initializer is private —
    /// there is no unguarded path). Used by a future, separately approved
    /// `PersonalAIContainer` wiring once a real Worker URL and an
    /// identity-token source exist.
    static func makeStore(
        credentials: any BackupCredentialProviding,
        transport: any BackupObjectTransport
    ) -> R2BackupStore {
        R2BackupStore.authorized(
            credentials: credentials,
            transport: transport,
            authority: RemoteBackupCompositionAuthority()
        )
    }

    /// The **only posture a shipping build has today**: no authorizer, no
    /// transport. Every operation throws `notConfigured`; the on-device
    /// backup is completely unaffected. `PersonalAIContainer.live` does not
    /// even construct this — it exists so the dormant posture is nameable and
    /// testable.
    static var inert: R2BackupStore { R2BackupStore.dormant }

    /// The object-key layout the Worker maps under the bucket — the canonical
    /// **versioned** namespace, defined once in `BackupObjectNamespace`. The
    /// client and the (future) Worker agree on it without sharing code (the
    /// Worker mirrors it in `cloudflare/backup-worker/src/scope.ts`).
    /// ```
    /// backup/v1/<ownerTag>/catalog.json                        the committed BackupHandle list
    /// backup/v1/<ownerTag>/objects/<version>-<tier>-<id>.eapb   one sealed backup each
    /// ```
    /// `<ownerTag>` is `BackupOwnerTag.tag(personalAIUserID)` — a salted
    /// SHA-256, never the id, never an email or username.
    static func objectNamespaceRoot(ownerTag: String) throws -> String {
        try BackupObjectNamespace.ownerRoot(ownerTag: ownerTag)
    }
}
