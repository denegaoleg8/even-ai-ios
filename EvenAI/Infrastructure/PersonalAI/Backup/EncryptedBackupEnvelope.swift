import Foundation
import CryptoKit

/// The **minimum** metadata carried *outside* the encrypted payload of a
/// backup object — just enough for a store, an operator, or a restore to
/// identify, order, integrity-check, and owner-scope an object **without the
/// key**, and nothing more. No record counts, no content, no identifiers
/// beyond a *salted hash* of the owner.
struct EncryptedBackupEnvelopeHeader: Codable, Hashable, Sendable {
    var encryptionScheme: String      // e.g. "AES-GCM-256"
    var createdAt: Date
    /// Salted SHA-256 of the Personal AI user id — **never the id itself**.
    /// Lets a restore reject another user's backup pre-decrypt.
    var ownerTag: String
    /// `BackupManifest.schemaVersion` of the sealed bundle (for "too new" checks).
    var bundleSchemaVersion: Int
    var bundleVersion: Int
    /// SHA-256 (hex) of the ciphertext bytes — detects truncation / bit-rot
    /// at rest before a decrypt is even attempted.
    var ciphertextSHA256: String
    var ciphertextLength: Int
    /// Present only for a **wrapped** (recovery-capable) envelope: the
    /// per-backup data key, encrypted once per key-encryption key. `nil` means
    /// the ciphertext is sealed directly with the device key (the original
    /// format — same-device restore only). **Contains no raw key material** —
    /// every `wrappedKey` is itself AES-GCM ciphertext, every `keyID` is a
    /// non-reversible fingerprint.
    var keyWrapping: BackupKeyWrapping?

    init(
        encryptionScheme: String,
        createdAt: Date,
        ownerTag: String,
        bundleSchemaVersion: Int,
        bundleVersion: Int,
        ciphertextSHA256: String,
        ciphertextLength: Int,
        keyWrapping: BackupKeyWrapping? = nil
    ) {
        self.encryptionScheme = encryptionScheme
        self.createdAt = createdAt
        self.ownerTag = ownerTag
        self.bundleSchemaVersion = bundleSchemaVersion
        self.bundleVersion = bundleVersion
        self.ciphertextSHA256 = ciphertextSHA256
        self.ciphertextLength = ciphertextLength
        self.keyWrapping = keyWrapping
    }
}

/// Envelope-encryption metadata: the backup ciphertext is sealed with a random
/// per-backup **data key** (DEK); that DEK is then wrapped (AES-256-GCM) once
/// for each **key-encryption key** (KEK) that is allowed to open this backup.
///
/// Standard key-wrapping — no home-grown crypto. Carries **no plaintext key**:
/// each `Slot.wrappedKey` is an AES-GCM combined box of the 32-byte DEK, and
/// each `Slot.keyID` is a truncated SHA-256 fingerprint of its KEK.
struct BackupKeyWrapping: Codable, Hashable, Sendable {
    /// Bump if the wrapping scheme changes.
    var version: Int
    /// Algorithm the DEK seals the payload with, and the KEKs wrap the DEK
    /// with — currently both `"AES-GCM-256"`.
    var algorithm: String
    var slots: [Slot]

    struct Slot: Codable, Hashable, Sendable {
        /// `"device"` (the Keychain key on the machine that made the backup) or
        /// `"recovery"` (a `PersonalAIRecoveryKey`).
        var kind: String
        /// Fingerprint of the KEK — `PersonalAIRecoveryKey.keyID` for a
        /// recovery slot; a device-key fingerprint for a device slot. Selects
        /// the slot; is not the key.
        var keyID: String
        /// AES-GCM combined box of the 32-byte DEK, encrypted under this KEK.
        var wrappedKey: Data
    }

    static let deviceKind = "device"
    static let recoveryKind = "recovery"

    func slot(kind: String, keyID: String? = nil) -> Slot? {
        slots.first { $0.kind == kind && (keyID == nil || $0.keyID == keyID) }
    }
}

/// Binary framing for a sealed backup:
///
/// ```
///  0 ..< 5     "EAPB1"            magic + envelope-format digit
///  5 ..< 9     UInt32 (BE)        headerJSON length
///  9 ..< 9+H   headerJSON         EncryptedBackupEnvelopeHeader
///  9+H ..< end ciphertext         raw AES-GCM combined box (never base64'd)
/// ```
///
/// The ciphertext stays raw (no base64 bloat on a multi-hundred-MB backup).
enum EncryptedBackupEnvelope {

    static let magic = Data("EAPB".utf8)
    static let currentFormatDigit: UInt8 = 0x31 // '1' — ciphertext sealed directly with the device key
    static let wrappedFormatDigit: UInt8 = 0x32 // '2' — ciphertext sealed with a wrapped DEK (recovery-capable)
    static let supportedFormatDigits: Set<UInt8> = [0x31, 0x32]

    static func frame(header: EncryptedBackupEnvelopeHeader, ciphertext: Data) throws -> Data {
        guard let headerData = try? JSONEncoder.personalAI.encode(header) else {
            throw BackupEncryptionError.malformedEnvelope
        }
        var out = Data()
        out.append(magic)
        // The digit follows the header shape: an old reader that only knows '1'
        // rejects a wrapped envelope cleanly (unsupportedEnvelopeVersion)
        // instead of failing an AES-GCM open with a confusing error.
        out.append(header.keyWrapping == nil ? currentFormatDigit : wrappedFormatDigit)
        var len = UInt32(headerData.count).bigEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(headerData)
        out.append(ciphertext)
        return out
    }

    /// Parse the framing. Returns `nil` if this is not an envelope at all
    /// (e.g. a legacy raw AES-GCM combined blob) so callers can fall back.
    /// Throws only for a *recognised but unusable* envelope.
    static func parse(_ data: Data) throws -> (header: EncryptedBackupEnvelopeHeader, ciphertext: Data)? {
        guard data.count >= magic.count + 1 + 4 else { return nil }
        guard data.prefix(magic.count) == magic else { return nil }
        let formatDigit = data[data.index(data.startIndex, offsetBy: magic.count)]
        guard supportedFormatDigits.contains(formatDigit) else {
            throw BackupEncryptionError.unsupportedEnvelopeVersion(
                found: Int(formatDigit) - 0x30,
                supported: Int(currentFormatDigit) - 0x30
            )
        }
        var cursor = data.index(data.startIndex, offsetBy: magic.count + 1)
        let lenBytes = data[cursor ..< data.index(cursor, offsetBy: 4)]
        let headerLen = Int(UInt32(bigEndian: lenBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
        cursor = data.index(cursor, offsetBy: 4)
        guard headerLen > 0, data.distance(from: cursor, to: data.endIndex) >= headerLen else {
            throw BackupEncryptionError.malformedEnvelope
        }
        let headerData = data[cursor ..< data.index(cursor, offsetBy: headerLen)]
        guard let header = try? JSONDecoder.personalAI.decode(EncryptedBackupEnvelopeHeader.self, from: headerData) else {
            throw BackupEncryptionError.malformedEnvelope
        }
        let ciphertext = Data(data[data.index(cursor, offsetBy: headerLen)...])
        return (header, ciphertext)
    }
}

/// The owner tag is a salted, non-reversible hash — it identifies "the same
/// user" across devices and scopes object keys, without ever putting the
/// Personal AI user id (or any account identifier) into a backup or an object
/// key path.
enum BackupOwnerTag {
    /// A per-install-stable salt is not needed: the tag must be reproducible
    /// for a given `personalAIUserID` on any device so a new iPhone can find
    /// its own backups. The salt is a fixed app constant — it defends against
    /// trivial rainbow-tabling of short ids, not against a determined
    /// attacker who has the app binary.
    private static let salt = Data("evenai.personal-ai.backup.owner-tag.v1".utf8)

    static func tag(_ personalAIUserID: String) -> String {
        var input = salt
        input.append(Data(personalAIUserID.utf8))
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }
}

extension Data {
    var sha256Hex: String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}
