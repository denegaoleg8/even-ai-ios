import Foundation

// MARK: - Backup encryption

/// Seals / opens a backup payload. The domain layer knows only this — never
/// `CryptoKit`, never a provider. The default production conformer is
/// `AESGCMBackupEncryption` (AES-256-GCM, key from the Keychain
/// `SymmetricKeyStore`, the same key class as the local cache).
///
/// **Nothing that reaches a `BackupStore` is ever plaintext.** The coordinator
/// seals the `PersonalDataBundle` with this before `putBackup`.
protocol BackupEncryptionProviding: Sendable {
    /// Plaintext → an opaque, self-describing encrypted blob
    /// (`EncryptedBackupEnvelope` framing).
    func seal(_ plaintext: Data) throws -> Data
    /// Encrypted blob → plaintext. Throws on a wrong key, tampering, an
    /// unsupported envelope version, or an unknown scheme.
    func open(_ sealed: Data) throws -> Data
    /// Stable id of the algorithm + key class, recorded in the envelope
    /// header so a future scheme change is detectable.
    var schemeIdentifier: String { get }
}

enum BackupEncryptionError: Error, Equatable, Sendable {
    case unsupportedEnvelopeVersion(found: Int, supported: Int)
    case unsupportedScheme(String)
    case integrityMismatch
    case malformedEnvelope
    case sealFailed
    case openFailed          // wrong key / tampered ciphertext

    var code: String {
        switch self {
        case .unsupportedEnvelopeVersion: return "envelope-version"
        case .unsupportedScheme: return "scheme"
        case .integrityMismatch: return "integrity"
        case .malformedEnvelope: return "malformed-envelope"
        case .sealFailed: return "seal"
        case .openFailed: return "open"
        }
    }
}

// MARK: - Object transport (the raw HTTPS verbs)

/// One object in a backup object store, as seen from outside the payload.
struct BackupObjectRef: Codable, Hashable, Sendable {
    var key: String
    var size: Int
    var etag: String?
    var lastModified: Date?
}

/// The raw object-storage operations, over **already-authorised URLs**
/// (pre-signed — see `BackupCredentialProviding`). Provider-neutral: an S3 /
/// R2 / GCS pre-signed URL all look the same here. Carries **no credentials
/// of its own**.
///
/// Production default: `DormantBackupObjectTransport` (throws `.notConfigured`).
protocol BackupObjectTransport: Sendable {
    func put(_ data: Data, to url: URL, headers: [String: String]) async throws
    func get(_ url: URL) async throws -> Data
    func delete(_ url: URL) async throws
    /// Object metadata, or `nil` for a 404.
    func head(_ url: URL) async throws -> BackupObjectRef?
}

enum BackupTransportError: Error, Equatable, Sendable {
    case notConfigured
    case network
    case http(status: Int)
    case notFound
    case truncated(expected: Int, got: Int)

    var code: String {
        switch self {
        case .notConfigured: return "not-configured"
        case .network: return "network"
        case .http(let s): return "http\(s)"
        case .notFound: return "not-found"
        case .truncated: return "truncated"
        }
    }

    var isRetryable: Bool {
        switch self {
        case .network, .truncated: return true
        case .http(let s): return s >= 500 || s == 429
        case .notConfigured, .notFound: return false
        }
    }
}

// MARK: - Credential seam (how the app is allowed to touch the store)

enum BackupObjectOperation: String, Sendable, CaseIterable {
    case put, get, delete, head, list
}

/// A short-lived, single-operation, key-scoped authorisation to touch the
/// backup object store.
struct PresignedBackupRequest: Sendable {
    var url: URL
    var headers: [String: String]
    var expiresAt: Date
    var isExpired: Bool { Date() >= expiresAt }
}

/// **The security boundary.** A production iPhone app must never embed a
/// permanent object-store secret (an R2 access key). Instead it asks an
/// authenticated server endpoint — a small Cloudflare Worker — for a
/// short-lived **pre-signed URL** for exactly one operation on exactly one
/// key, scoped to the caller's own `ownerTag` prefix. The Worker holds the R2
/// credentials; it verifies the caller's identity token (Sign in with Apple /
/// the EvenAI account token) before signing.
///
/// Production default: `NotConfiguredBackupCredentialProvider`
/// (`isConfigured == false`, every call throws). Nothing about R2 is live
/// until a Worker URL is configured — which is a later, separately-approved
/// step.
protocol BackupCredentialProviding: Sendable {
    func presign(_ operation: BackupObjectOperation, key: String, ownerTag: String) async throws -> PresignedBackupRequest
    /// `false` in production today — no backup infra is deployed.
    var isConfigured: Bool { get }
}

enum BackupCredentialError: Error, Equatable, Sendable {
    case notConfigured
    case unauthorized
    case keyOutsideOwnerScope
    case network

    var code: String {
        switch self {
        case .notConfigured: return "not-configured"
        case .unauthorized: return "unauthorized"
        case .keyOutsideOwnerScope: return "scope"
        case .network: return "network"
        }
    }
}
