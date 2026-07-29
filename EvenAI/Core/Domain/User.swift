import Foundation

/// Domain-level account model. Mirrors the trimmed `account` object the
/// backend returns (`toPublicAccount` server-side) — never a password
/// hash, subscription internals, or settings/profile blobs nothing reads
/// yet. `email == nil` means this is an anonymous, unclaimed account
/// (see the Even AI authentication architecture: every device gets one
/// automatically, claimed in place by signing up — same id before and
/// after, never a different account).
struct User: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var email: String?
    var displayName: String?
}
