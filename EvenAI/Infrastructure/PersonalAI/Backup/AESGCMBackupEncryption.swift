import Foundation
import CryptoKit

/// Production `BackupEncryptionProviding` — AES-256-GCM with the key from
/// `SymmetricKeyStore` (Keychain, `…ThisDeviceOnly`, its own service, never
/// shared with `AuthTokenStore`). Random 96-bit nonce per seal. Output is
/// wrapped in `EncryptedBackupEnvelope` framing so the object store can
/// integrity-check and owner-scope it without the key.
///
/// `open` also parses legacy raw `AES.GCM.SealedBox(combined:)` blobs (the
/// pre-envelope format the coordinator wrote before this layer) so old
/// on-device backups still restore.
struct AESGCMBackupEncryption: BackupEncryptionProviding {

    private let keyStore: SymmetricKeyStore
    private let ownerIDProvider: @Sendable () -> String?
    private let bundleSchemaVersion: Int
    private let clock: @Sendable () -> Date

    init(
        keyStore: SymmetricKeyStore,
        ownerID: @escaping @Sendable () -> String? = { nil },
        bundleSchemaVersion: Int = BackupManifest.currentSchemaVersion,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.keyStore = keyStore
        self.ownerIDProvider = ownerID
        self.bundleSchemaVersion = bundleSchemaVersion
        self.clock = clock
    }

    var schemeIdentifier: String { "AES-GCM-256" }

    func seal(_ plaintext: Data) throws -> Data {
        let key = try keyStore.key()
        guard let box = try? AES.GCM.seal(plaintext, using: key), let combined = box.combined else {
            throw BackupEncryptionError.sealFailed
        }
        let header = EncryptedBackupEnvelopeHeader(
            encryptionScheme: schemeIdentifier,
            createdAt: clock(),
            ownerTag: BackupOwnerTag.tag(ownerIDProvider() ?? ""),
            bundleSchemaVersion: bundleSchemaVersion,
            bundleVersion: Self.bundleVersion(in: plaintext),
            ciphertextSHA256: combined.sha256Hex,
            ciphertextLength: combined.count
        )
        return try EncryptedBackupEnvelope.frame(header: header, ciphertext: combined)
    }

    func open(_ sealed: Data) throws -> Data {
        let key = try keyStore.key()

        if let (header, ciphertext) = try EncryptedBackupEnvelope.parse(sealed) {
            guard header.encryptionScheme == schemeIdentifier else {
                throw BackupEncryptionError.unsupportedScheme(header.encryptionScheme)
            }
            guard ciphertext.count == header.ciphertextLength,
                  ciphertext.sha256Hex == header.ciphertextSHA256 else {
                throw BackupEncryptionError.integrityMismatch
            }
            guard let box = try? AES.GCM.SealedBox(combined: ciphertext),
                  let plaintext = try? AES.GCM.open(box, using: key) else {
                throw BackupEncryptionError.openFailed
            }
            return plaintext
        }

        // Legacy: a bare `AES.GCM` combined box, no envelope.
        guard let box = try? AES.GCM.SealedBox(combined: sealed),
              let plaintext = try? AES.GCM.open(box, using: key) else {
            throw BackupEncryptionError.openFailed
        }
        return plaintext
    }

    /// Read `manifest.bundleVersion` out of the bundle JSON for the envelope
    /// header, without a full decode. Best-effort — 0 if not found.
    private static func bundleVersion(in bundleJSON: Data) -> Int {
        guard let obj = try? JSONSerialization.jsonObject(with: bundleJSON) as? [String: Any],
              let manifest = obj["manifest"] as? [String: Any],
              let v = manifest["bundleVersion"] as? Int
        else { return 0 }
        return v
    }
}

/// Test/preview helper — a `BackupEncryptionProviding` that does **not**
/// encrypt (identity). Isolates the storage / catalog / verification logic
/// from CryptoKit in tests that aren't about encryption.
struct PassthroughBackupEncryption: BackupEncryptionProviding {
    var schemeIdentifier: String { "passthrough" }
    func seal(_ plaintext: Data) throws -> Data { plaintext }
    func open(_ sealed: Data) throws -> Data { sealed }
}
