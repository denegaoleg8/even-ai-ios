import Foundation

/// Provider-independent vocabulary for the **production backup authorization
/// boundary**. It names no concrete object store — a Worker, a Lambda@Edge
/// signer, or a self-hosted API all speak this shape. Provider-specific code
/// stays in the adapter layer.
///
/// The trust boundary:
/// ```
///  iOS app  ──►  authenticated EvenAI backup authorizer (Worker)  ──►  R2
///  (holds no      (holds the scoped R2 credential; derives the           (object
///   store secret)  owner tag from the verified identity, never trusts     store)
///                  the client's claimed tag; scopes every grant to
///                  one operation on one key; grants expire in minutes)
/// ```
///
/// **Object lifecycle** (not a stored enum — the catalog is the source of
/// truth): an object's bytes may be *staged* (uploaded but not yet in the
/// owner's `catalog.json`) or *committed* (catalogued **and** verified by
/// `PersonalAIBackupCoordinator`). `listBackups` returns only committed
/// entries, so a staged object from an interrupted upload is never a restore
/// candidate.

/// What a single authorization grant permits: **exactly one operation on
/// exactly one object key, under one owner's namespace.** A grant that
/// authorizes "everything" is a bug — every field here is required.
struct BackupAuthorizationScope: Codable, Hashable, Sendable {
    /// Salted, non-reversible hash of the Personal AI user id
    /// (`BackupOwnerTag.tag`). Never the raw id, never an email/username.
    var ownerTag: String
    /// The single object key this grant is good for, e.g.
    /// `<ownerTag>/objects/7-daily-<uuid>.eapb`.
    var objectKey: String
    /// The single verb this grant is good for.
    var operation: BackupObjectOperation

    /// True only when this grant is for byte-for-byte the operation, key, and
    /// owner namespace the caller is about to use — and the key is well-formed
    /// and inside that namespace.
    func authorizes(_ operation: BackupObjectOperation, key: String, ownerTag: String) -> Bool {
        operation == self.operation
            && key == objectKey
            && ownerTag == self.ownerTag
            && Self.keyIsInOwnerNamespace(key, ownerTag: ownerTag)
    }

    /// True when `key` is **well-formed** and, after stripping a *recognised*
    /// `backup/v<N>/` version prefix (see `BackupObjectNamespace`), sits at or
    /// strictly under `<ownerTag>/`. Rejects path traversal, empty / over-long
    /// keys, doubled or leading separators, control characters, and — crucially
    /// — an **unrecognised** namespace version (its `backup/vX/` prefix is not
    /// stripped, so it can't match the owner). A security primitive, enforced
    /// client-side (`BackupAuthorizationClient`) and, authoritatively, by the
    /// authorizer against the *derived* tag.
    ///
    /// A bare `<ownerTag>/…` key (no version prefix) is still accepted — there
    /// is no production R2 data, and the test doubles use the bare form.
    static func keyIsInOwnerNamespace(_ key: String, ownerTag: String) -> Bool {
        guard keyIsWellFormed(key) else { return false }
        let body = BackupObjectNamespace.strippingRecognisedVersionPrefix(key)
        return body == ownerTag || body.hasPrefix(ownerTag + "/")
    }

    /// Structural validity of an object key, independent of owner:
    /// - non-empty, ≤ 512 bytes,
    /// - no ASCII control characters,
    /// - no leading `/`, no `//`,
    /// - no `.` or `..` path segment (blocks traversal / canonicalisation
    ///   ambiguity).
    static func keyIsWellFormed(_ key: String) -> Bool {
        guard !key.isEmpty, key.utf8.count <= 512 else { return false }
        guard !key.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return false }
        guard !key.hasPrefix("/"), !key.contains("//") else { return false }
        let segments = key.split(separator: "/", omittingEmptySubsequences: false)
        guard !segments.contains(where: { $0 == "." || $0 == ".." || $0.isEmpty }) else { return false }
        return true
    }
}
