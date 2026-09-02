import Foundation
import CryptoKit

/// A high-entropy **recovery key** for Personal AI backups.
///
/// It is *not* the key that encrypts a backup. It is a **key-encryption key**
/// (KEK): each backup gets a fresh random data-encryption key (DEK), and that
/// DEK is wrapped (AES-GCM) once with the device key and once with this
/// recovery key (see `AESGCMBackupEncryption` / `BackupKeyWrapping`). On a new
/// iPhone, where the device key is gone, the user supplies this recovery key
/// and the DEK — and therefore the backup — is recoverable.
///
/// - **256 bits of entropy** (`SymmetricKey(size: .bits256)`). Never derived
///   from a passphrase — a passphrase path would require a memory-hard KDF
///   (Argon2id / scrypt), which is a deliberate future choice, not this.
/// - **Versioned** (`version`), **integrity-protected** (a truncated SHA-256
///   checksum inside the export string catches a mistyped code before any
///   decryption is attempted), and **round-trips** through `recoveryCode` and
///   `serialized()`.
/// - `keyID` is a deterministic, non-reversible fingerprint. It is what a
///   backup envelope records ("this DEK slot is wrapped for recovery key X"),
///   so on import the supplied key can be matched to the right slot. It is
///   **not** the key and reveals nothing about it.
/// - **No plaintext key** goes into a log, a backup manifest, an envelope
///   header, or any remote payload. The `recoveryCode` / `serialized()` forms
///   ARE key material and must be handled like a password.
struct PersonalAIRecoveryKey: Sendable, Equatable {

    /// Bump when the derivation of `keyID` / `checksum` / the code format
    /// changes. A backup envelope records the version it was wrapped under.
    static let currentVersion = 1

    let version: Int
    /// 16-hex-char deterministic fingerprint of the raw key. Safe to store in
    /// an envelope header.
    let keyID: String
    /// The raw 256-bit key. Never serialized except inside `recoveryCode` /
    /// `serialized()`, never logged.
    let rawKey: SymmetricKey

    enum RecoveryKeyError: Error, Equatable, Sendable {
        case unsupportedVersion(Int)
        case malformedCode
        case checksumMismatch
        case malformedSerialization
        case wrongKeyLength
    }

    private init(version: Int, keyID: String, rawKey: SymmetricKey) {
        self.version = version
        self.keyID = keyID
        self.rawKey = rawKey
    }

    // MARK: - Generation

    /// A fresh random recovery key.
    static func generate() -> PersonalAIRecoveryKey {
        make(from: SymmetricKey(size: .bits256))
    }

    /// Rebuild from exactly 32 raw bytes (e.g. after unwrapping from storage).
    static func fromRawBytes(_ bytes: Data) throws -> PersonalAIRecoveryKey {
        guard bytes.count == 32 else { throw RecoveryKeyError.wrongKeyLength }
        return make(from: SymmetricKey(data: bytes))
    }

    private static func make(from key: SymmetricKey) -> PersonalAIRecoveryKey {
        PersonalAIRecoveryKey(version: currentVersion, keyID: Self.keyID(for: key), rawKey: key)
    }

    private var rawKeyBytes: Data { rawKey.withUnsafeBytes { Data($0) } }

    static func keyID(for key: SymmetricKey) -> String {
        let bytes = key.withUnsafeBytes { Data($0) }
        let digest = SHA256.hash(data: Data("evenai.personal-ai.recovery-key.v1.id".utf8) + bytes)
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func checksum(for keyBytes: Data) -> Data {
        Data(SHA256.hash(data: Data("evenai.personal-ai.recovery-key.v1.checksum".utf8) + keyBytes).prefix(4))
    }

    // MARK: - Export / import — the human-transferable "recovery code"

    /// `EARK1-XXXX-XXXX-…` — RFC 4648 base32 (upper, no padding) of
    /// `rawKey(32) ‖ checksum(4)`, grouped in 4s. This IS key material.
    var recoveryCode: String {
        let payload = rawKeyBytes + Self.checksum(for: rawKeyBytes)
        let body = Base32.encode(payload)
        let groups = stride(from: 0, to: body.count, by: 4).map { start -> String in
            let s = body.index(body.startIndex, offsetBy: start)
            let e = body.index(s, offsetBy: 4, limitedBy: body.endIndex) ?? body.endIndex
            return String(body[s..<e])
        }
        return (["EARK\(version)"] + groups).joined(separator: "-")
    }

    /// Parse a `recoveryCode`. Case-insensitive; spaces and the grouping
    /// dashes *within the body* are optional — the `EARK<version>-` head and
    /// its separating dash are required (the version digit would otherwise run
    /// into the body). Rejects a wrong version, a bad charset, a wrong length,
    /// or a checksum mismatch (a mistyped code) — *before* it can be used for
    /// decryption.
    init(recoveryCode code: String) throws {
        // Spaces are accepted anywhere a dash is (so "EARK1 XXXX XXXX" works).
        let compact = code.uppercased().replacingOccurrences(of: " ", with: "-")
        guard let firstDash = compact.firstIndex(of: "-") else { throw RecoveryKeyError.malformedCode }
        let head = String(compact[..<firstDash])
        let body = String(compact[compact.index(after: firstDash)...]).replacingOccurrences(of: "-", with: "")
        guard head.hasPrefix("EARK"), let v = Int(head.dropFirst(4)) else { throw RecoveryKeyError.malformedCode }
        guard v == Self.currentVersion else { throw RecoveryKeyError.unsupportedVersion(v) }
        guard !body.isEmpty, let payload = Base32.decode(body), payload.count == 36 else {
            throw RecoveryKeyError.malformedCode
        }
        let keyBytes = payload.prefix(32)
        let given = Data(payload.suffix(4))
        guard given == Self.checksum(for: Data(keyBytes)) else { throw RecoveryKeyError.checksumMismatch }
        self = Self.make(from: SymmetricKey(data: keyBytes))
    }

    // MARK: - Export / import — the programmatic "recovery file"

    /// A small framed binary form for programmatic storage (e.g. a document the
    /// user keeps in Files / on a Mac). Same content as `recoveryCode`; still
    /// key material.
    ///
    /// ```
    /// "EARKF" + versionByte(1) + UInt16BE(headerLen) + headerJSON{version,keyID} + rawKey(32) + checksum(4)
    /// ```
    func serialized() -> Data {
        let header = try! JSONEncoder().encode(SerializedHeader(version: version, keyID: keyID))
        var out = Data("EARKF".utf8)
        out.append(UInt8(version & 0xFF))
        var len = UInt16(header.count).bigEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(header)
        out.append(rawKeyBytes)
        out.append(Self.checksum(for: rawKeyBytes))
        return out
    }

    init(serialized data: Data) throws {
        let magic = Data("EARKF".utf8)
        guard data.count > magic.count + 3, data.prefix(magic.count) == magic else {
            throw RecoveryKeyError.malformedSerialization
        }
        var cursor = data.index(data.startIndex, offsetBy: magic.count)
        let versionByte = Int(data[cursor]); cursor = data.index(after: cursor)
        guard versionByte == Self.currentVersion else { throw RecoveryKeyError.unsupportedVersion(versionByte) }
        let lenBytes = data[cursor ..< data.index(cursor, offsetBy: 2)]
        let headerLen = Int(UInt16(bigEndian: lenBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }))
        cursor = data.index(cursor, offsetBy: 2)
        guard data.distance(from: cursor, to: data.endIndex) == headerLen + 32 + 4 else {
            throw RecoveryKeyError.malformedSerialization
        }
        cursor = data.index(cursor, offsetBy: headerLen)   // header content not required to reconstruct
        let keyBytes = Data(data[cursor ..< data.index(cursor, offsetBy: 32)])
        let given = Data(data[data.index(cursor, offsetBy: 32) ..< data.endIndex])
        guard given == Self.checksum(for: keyBytes) else { throw RecoveryKeyError.checksumMismatch }
        self = Self.make(from: SymmetricKey(data: keyBytes))
    }

    private struct SerializedHeader: Codable { var version: Int; var keyID: String }
}

// MARK: - RFC 4648 base32 (upper, no padding)

private enum Base32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    static func encode(_ data: Data) -> String {
        var out = ""
        var buffer = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[(buffer >> bits) & 0x1F])
                buffer &= (1 << bits) - 1
            }
        }
        if bits > 0 {
            out.append(alphabet[(buffer << (5 - bits)) & 0x1F])
        }
        return out
    }

    static func decode(_ string: String) -> Data? {
        var lookup: [Character: Int] = [:]
        for (i, c) in alphabet.enumerated() { lookup[c] = i }
        var out = Data()
        var buffer = 0
        var bits = 0
        for c in string {
            guard let value = lookup[c] else { return nil }
            buffer = (buffer << 5) | value
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> bits) & 0xFF))
                buffer &= (1 << bits) - 1
            }
        }
        return out
    }
}
