import Foundation

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
        R2BackupStore.authorized(credentials: credentials, transport: transport)
    }

    /// The **only posture a shipping build has today**: no authorizer, no
    /// transport. Every operation throws `notConfigured`; the on-device
    /// backup is completely unaffected. `PersonalAIContainer.live` does not
    /// even construct this — it exists so the dormant posture is nameable and
    /// testable.
    static var inert: R2BackupStore { R2BackupStore.dormant }

    /// The object-key layout the Worker maps under the bucket. Documented here
    /// so the client and the (future) Worker agree without sharing code.
    /// ```
    /// <ownerTag>/catalog.json                        the committed BackupHandle list
    /// <ownerTag>/objects/<version>-<tier>-<id>.eapb   one sealed backup each
    /// ```
    /// `<ownerTag>` is `BackupOwnerTag.tag(personalAIUserID)` — a salted
    /// SHA-256, never the id, never an email or username.
    static func objectNamespaceRoot(ownerTag: String) -> String { ownerTag }
}
