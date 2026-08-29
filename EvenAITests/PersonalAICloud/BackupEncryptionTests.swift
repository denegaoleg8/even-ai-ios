import Testing
import Foundation
import CryptoKit
@testable import EvenAI

/// `BackupEncryptionProviding` + `EncryptedBackupEnvelope` — sealing, opening,
/// framing, and every rejection path.
@Suite("Backup: encryption & envelope")
struct BackupEncryptionTests {

    private func encryption(seed: UInt8 = 0x11, owner: String = "user-1") -> AESGCMBackupEncryption {
        AESGCMBackupEncryption(keyStore: InMemorySymmetricKeyStore(seed: seed), ownerID: { owner })
    }

    @Test("seal → open round-trips arbitrary bytes")
    func roundTrip() throws {
        let enc = encryption()
        let plaintext = Data("the quick brown fox — Personal AI memory bundle".utf8)
        let sealed = try enc.seal(plaintext)
        #expect(sealed != plaintext)
        #expect(try enc.open(sealed) == plaintext)
    }

    @Test("the sealed blob is EncryptedBackupEnvelope-framed with minimal, content-free metadata")
    func envelopeFraming() throws {
        let enc = encryption(owner: "user-abc")
        let sealed = try enc.seal(Data("secret content here".utf8))
        let parsed = try EncryptedBackupEnvelope.parse(sealed)
        #expect(parsed != nil)
        let header = parsed!.header
        #expect(header.encryptionScheme == "AES-GCM-256")
        #expect(header.ciphertextLength == parsed!.ciphertext.count)
        #expect(header.ciphertextSHA256 == parsed!.ciphertext.sha256Hex)
        // The owner is a salted hash, never the id, and not the content.
        #expect(header.ownerTag == BackupOwnerTag.tag("user-abc"))
        #expect(!header.ownerTag.contains("user-abc"))
        // No plaintext leaked into the header bytes.
        let sealedString = String(decoding: sealed, as: UTF8.self)
        #expect(!sealedString.contains("secret content here"))
    }

    @Test("wrong key → open fails, never returns garbage")
    func wrongKeyRejected() throws {
        let sealed = try encryption(seed: 0x11).seal(Data("payload".utf8))
        #expect(throws: BackupEncryptionError.self) {
            _ = try encryption(seed: 0x22).open(sealed)
        }
    }

    @Test("tampered ciphertext → integrity mismatch")
    func tamperRejected() throws {
        let enc = encryption()
        var sealed = try enc.seal(Data("payload payload payload".utf8))
        var bytes = [UInt8](sealed)
        bytes[bytes.count - 5] ^= 0xFF   // flip a ciphertext byte
        sealed = Data(bytes)
        #expect(throws: BackupEncryptionError.self) { _ = try enc.open(sealed) }
    }

    @Test("unsupported envelope version is rejected")
    func unsupportedEnvelopeVersion() throws {
        let enc = encryption()
        var sealed = [UInt8](try enc.seal(Data("x".utf8)))
        sealed[4] = 0x39 // '9' — a format digit this build doesn't know
        #expect {
            _ = try enc.open(Data(sealed))
        } throws: { error in
            if case BackupEncryptionError.unsupportedEnvelopeVersion = error { return true }
            return false
        }
    }

    @Test("legacy raw AES-GCM combined blob still opens (pre-envelope backups)")
    func legacyRawOpens() throws {
        let key = InMemorySymmetricKeyStore(seed: 0x33)
        let plaintext = Data("legacy backup".utf8)
        // Old format: bare combined box, no envelope.
        let combined = try AES.GCM.seal(plaintext, using: key.key()).combined!
        let enc = AESGCMBackupEncryption(keyStore: key, ownerID: { "u" })
        #expect(try enc.open(combined) == plaintext)
    }

    @Test("owner tag is stable per user and differs between users")
    func ownerTagStability() {
        #expect(BackupOwnerTag.tag("u-1") == BackupOwnerTag.tag("u-1"))
        #expect(BackupOwnerTag.tag("u-1") != BackupOwnerTag.tag("u-2"))
        #expect(BackupOwnerTag.tag("").count == 64) // sha-256 hex even for empty
    }

    @Test("passthrough encryption is a true identity (test isolation helper)")
    func passthroughIdentity() throws {
        let enc = PassthroughBackupEncryption()
        let data = Data([1, 2, 3, 4, 5])
        #expect(try enc.seal(data) == data)
        #expect(try enc.open(data) == data)
    }
}
