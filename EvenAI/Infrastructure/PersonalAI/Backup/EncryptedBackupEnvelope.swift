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
    static let currentFormatDigit: UInt8 = 0x31 // '1'
    static let supportedFormatDigits: Set<UInt8> = [0x31]

    static func frame(header: EncryptedBackupEnvelopeHeader, ciphertext: Data) throws -> Data {
        guard let headerData = try? JSONEncoder.personalAI.encode(header) else {
            throw BackupEncryptionError.malformedEnvelope
        }
        var out = Data()
        out.append(magic)
        out.append(currentFormatDigit)
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
