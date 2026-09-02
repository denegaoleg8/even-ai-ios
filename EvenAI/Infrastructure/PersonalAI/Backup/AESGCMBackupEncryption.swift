import Foundation
import CryptoKit

/// Production `BackupEncryptionProviding` — AES-256-GCM.
///
/// ## Two envelope formats
///
/// - **Direct (`"EAPB1"`)** — used when no recovery key is configured. The
///   payload is sealed straight with the `SymmetricKeyStore` key (Keychain,
///   `…ThisDeviceOnly`). Restorable **only on the same device**. Unchanged
///   from the original design.
/// - **Wrapped (`"EAPB2"`)** — used when a `PersonalAIRecoveryKey` is
///   configured. A fresh random **data key (DEK)** seals the payload; the DEK
///   is then wrapped (AES-GCM) once with the device key and once with the
///   recovery key (`BackupKeyWrapping`). Same-device restore uses the device
///   slot; a **new iPhone** uses `open(_:using:)` with the recovery key.
///
/// `open` also still parses a legacy bare `AES.GCM.SealedBox(combined:)` blob.
///
/// **The recovery key, the device key, and the DEK never appear in a log, a
/// backup manifest, an envelope header, or any remote payload.** Every
/// `wrappedKey` in the header is itself ciphertext.
struct AESGCMBackupEncryption: BackupEncryptionProviding {

    private let keyStore: SymmetricKeyStore
    private let ownerIDProvider: @Sendable () -> String?
    private let bundleSchemaVersion: Int
    private let clock: @Sendable () -> Date
    /// Supplies the recovery key to wrap each backup's DEM for, or `nil` to
    /// keep writing the direct format. Resolved fresh on every `seal` so key
    /// rotation takes effect on the next backup.
    private let recoveryKeyProvider: @Sendable () -> PersonalAIRecoveryKey?

    init(
        keyStore: SymmetricKeyStore,
        ownerID: @escaping @Sendable () -> String? = { nil },
        bundleSchemaVersion: Int = BackupManifest.currentSchemaVersion,
        clock: @escaping @Sendable () -> Date = { Date() },
        recoveryKey: @escaping @Sendable () -> PersonalAIRecoveryKey? = { nil }
    ) {
        self.keyStore = keyStore
        self.ownerIDProvider = ownerID
        self.bundleSchemaVersion = bundleSchemaVersion
        self.clock = clock
        self.recoveryKeyProvider = recoveryKey
    }

    var schemeIdentifier: String { "AES-GCM-256" }

    // MARK: - Seal

    func seal(_ plaintext: Data) throws -> Data {
        let deviceKey = try keyStore.key()

        if let recovery = recoveryKeyProvider() {
            return try sealWrapped(plaintext, deviceKey: deviceKey, recovery: recovery)
        }

        // Direct format — unchanged.
        guard let box = try? AES.GCM.seal(plaintext, using: deviceKey), let combined = box.combined else {
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

    private func sealWrapped(_ plaintext: Data, deviceKey: SymmetricKey, recovery: PersonalAIRecoveryKey) throws -> Data {
        let dek = SymmetricKey(size: .bits256)
        guard let box = try? AES.GCM.seal(plaintext, using: dek), let combined = box.combined else {
            throw BackupEncryptionError.sealFailed
        }
        let wrapping = BackupKeyWrapping(
            version: 1,
            algorithm: schemeIdentifier,
            slots: [
                .init(kind: BackupKeyWrapping.deviceKind,
                      keyID: Self.deviceKeyID(deviceKey),
                      wrappedKey: try Self.wrap(dek, with: deviceKey)),
                .init(kind: BackupKeyWrapping.recoveryKind,
                      keyID: recovery.keyID,
                      wrappedKey: try Self.wrap(dek, with: recovery.rawKey)),
            ]
        )
        let header = EncryptedBackupEnvelopeHeader(
            encryptionScheme: schemeIdentifier,
            createdAt: clock(),
            ownerTag: BackupOwnerTag.tag(ownerIDProvider() ?? ""),
            bundleSchemaVersion: bundleSchemaVersion,
            bundleVersion: Self.bundleVersion(in: plaintext),
            ciphertextSHA256: combined.sha256Hex,
            ciphertextLength: combined.count,
            keyWrapping: wrapping
        )
        return try EncryptedBackupEnvelope.frame(header: header, ciphertext: combined)
    }

    // MARK: - Open (same device)

    func open(_ sealed: Data) throws -> Data {
        let deviceKey = try keyStore.key()

        if let (header, ciphertext) = try EncryptedBackupEnvelope.parse(sealed) {
            try Self.checkEnvelope(header: header, ciphertext: ciphertext, scheme: schemeIdentifier)

            if let wrapping = header.keyWrapping {
                guard let slot = wrapping.slot(kind: BackupKeyWrapping.deviceKind),
                      let dek = Self.unwrap(slot.wrappedKey, with: deviceKey) else {
                    throw BackupEncryptionError.openFailed
                }
                return try Self.decrypt(ciphertext, with: dek)
            }

            return try Self.decrypt(ciphertext, with: deviceKey)
        }

        // Legacy: a bare `AES.GCM` combined box, no envelope.
        guard let box = try? AES.GCM.SealedBox(combined: sealed),
              let plaintext = try? AES.GCM.open(box, using: deviceKey) else {
            throw BackupEncryptionError.openFailed
        }
        return plaintext
    }

    // MARK: - Open (new device, via a recovery key)

    /// Decrypt a **wrapped** backup on a device that does not have the original
    /// Keychain key, using the recovery key the user supplied.
    ///
    /// Fails without touching anything if: the backup is not a wrapped envelope
    /// (`recoveryNotAvailable`); no slot matches this recovery key — e.g. a
    /// rotated key opening a pre-rotation backup (`recoveryKeyMismatch`); or the
    /// wrapped key / ciphertext is corrupt (`openFailed` / `integrityMismatch`).
    func open(_ sealed: Data, using recoveryKey: PersonalAIRecoveryKey) throws -> Data {
        guard let (header, ciphertext) = try EncryptedBackupEnvelope.parse(sealed) else {
            throw BackupEncryptionError.recoveryNotAvailable
        }
        try Self.checkEnvelope(header: header, ciphertext: ciphertext, scheme: schemeIdentifier)

        guard let wrapping = header.keyWrapping else {
            throw BackupEncryptionError.recoveryNotAvailable
        }
        guard let slot = wrapping.slot(kind: BackupKeyWrapping.recoveryKind, keyID: recoveryKey.keyID) else {
            throw BackupEncryptionError.recoveryKeyMismatch
        }
        guard let dek = Self.unwrap(slot.wrappedKey, with: recoveryKey.rawKey) else {
            throw BackupEncryptionError.openFailed
        }
        return try Self.decrypt(ciphertext, with: dek)
    }

    /// The recovery-key ids a wrapped backup can be opened with (`[]` for a
    /// direct backup). Lets a restore UI tell the user *which* recovery key to
    /// supply without attempting a decrypt.
    static func recoverySlotKeyIDs(in sealed: Data) -> [String] {
        guard let parsed = (try? EncryptedBackupEnvelope.parse(sealed)) ?? nil,
              let wrapping = parsed.header.keyWrapping else { return [] }
        return wrapping.slots.filter { $0.kind == BackupKeyWrapping.recoveryKind }.map(\.keyID)
    }

    // MARK: - Primitives

    private static func wrap(_ dek: SymmetricKey, with kek: SymmetricKey) throws -> Data {
        let raw = dek.withUnsafeBytes { Data($0) }
        guard let box = try? AES.GCM.seal(raw, using: kek), let combined = box.combined else {
            throw BackupEncryptionError.sealFailed
        }
        return combined
    }

    private static func unwrap(_ wrapped: Data, with kek: SymmetricKey) -> SymmetricKey? {
        guard let box = try? AES.GCM.SealedBox(combined: wrapped),
              let raw = try? AES.GCM.open(box, using: kek),
              raw.count == 32 else { return nil }
        return SymmetricKey(data: raw)
    }

    private static func decrypt(_ ciphertext: Data, with key: SymmetricKey) throws -> Data {
        guard let box = try? AES.GCM.SealedBox(combined: ciphertext),
              let plaintext = try? AES.GCM.open(box, using: key) else {
            throw BackupEncryptionError.openFailed
        }
        return plaintext
    }

    private static func checkEnvelope(header: EncryptedBackupEnvelopeHeader, ciphertext: Data, scheme: String) throws {
        guard header.encryptionScheme == scheme else {
            throw BackupEncryptionError.unsupportedScheme(header.encryptionScheme)
        }
        guard ciphertext.count == header.ciphertextLength,
              ciphertext.sha256Hex == header.ciphertextSHA256 else {
            throw BackupEncryptionError.integrityMismatch
        }
    }

    /// Non-reversible fingerprint of a device key — a slot selector, not the key.
    static func deviceKeyID(_ key: SymmetricKey) -> String {
        let bytes = key.withUnsafeBytes { Data($0) }
        return Data(SHA256.hash(data: Data("evenai.personal-ai.backup.device-key-id.v1".utf8) + bytes).prefix(8))
            .map { String(format: "%02x", $0) }.joined()
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
