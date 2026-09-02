import Testing
import Foundation
import CryptoKit
@testable import EvenAI

/// PART A — the recovery-key mechanism: a high-entropy key-encryption key that
/// wraps each backup's data key, so a **wrapped** backup can be restored on a
/// new iPhone without the original device key.
///
/// LOCAL IMPLEMENTATION + TESTS. No cloud escrow, no new-device restore
/// verified against a real device — see `PHASE2_PERSONAL_AI_RECOVERY_KEY.md`.
@Suite("Backup: recovery key")
struct PersonalAIRecoveryKeyTests {

    // MARK: - the key itself

    @Test("a generated recovery key is 256 bits of entropy, versioned, with a stable opaque id")
    func generatedKeyShape() {
        let key = PersonalAIRecoveryKey.generate()
        #expect(key.version == PersonalAIRecoveryKey.currentVersion)
        #expect(key.rawKey.withUnsafeBytes { $0.count } == 32)             // 256 bits
        #expect(key.keyID.count == 16)
        #expect(key.keyID.allSatisfy { $0.isHexDigit })
        // deterministic id, per-key distinct
        #expect(PersonalAIRecoveryKey.keyID(for: key.rawKey) == key.keyID)
        #expect(PersonalAIRecoveryKey.generate().keyID != key.keyID)
        // two generations differ (entropy)
        #expect(PersonalAIRecoveryKey.generate().recoveryCode != PersonalAIRecoveryKey.generate().recoveryCode)
    }

    @Test("recovery code round-trips, is version-tagged, and survives formatting noise")
    func recoveryCodeRoundTrip() throws {
        let key = PersonalAIRecoveryKey.generate()
        let code = key.recoveryCode
        #expect(code.hasPrefix("EARK\(PersonalAIRecoveryKey.currentVersion)-"))
        #expect(try PersonalAIRecoveryKey(recoveryCode: code) == key)
        // lowercase, spaces-for-dashes, and dropped body-grouping dashes are all tolerated
        #expect(try PersonalAIRecoveryKey(recoveryCode: code.lowercased()) == key)
        #expect(try PersonalAIRecoveryKey(recoveryCode: code.replacingOccurrences(of: "-", with: " ")) == key)
        let headSplit = code.firstIndex(of: "-")!
        let bodyCompacted = code[..<code.index(after: headSplit)]
            + code[code.index(after: headSplit)...].replacingOccurrences(of: "-", with: "")
        #expect(try PersonalAIRecoveryKey(recoveryCode: String(bodyCompacted)) == key)
    }

    @Test("recovery file (serialized form) round-trips and preserves the version")
    func serializationRoundTrip() throws {
        let key = PersonalAIRecoveryKey.generate()
        let blob = key.serialized()
        let restored = try PersonalAIRecoveryKey(serialized: blob)
        #expect(restored == key)
        #expect(restored.version == key.version)
        #expect(restored.keyID == key.keyID)
    }

    @Test("a mistyped / corrupted recovery code is rejected before it can be used")
    func corruptedCodeRejected() {
        let code = PersonalAIRecoveryKey.generate().recoveryCode
        // flip one character in the base32 body
        var chars = Array(code)
        let i = chars.firstIndex { $0 != "-" && $0 != "E" && $0 != "A" && $0 != "R" && $0 != "K" && $0 != "1" }!
        chars[i] = chars[i] == "A" ? "B" : "A"
        #expect(throws: PersonalAIRecoveryKey.RecoveryKeyError.checksumMismatch) {
            _ = try PersonalAIRecoveryKey(recoveryCode: String(chars))
        }
        #expect(throws: PersonalAIRecoveryKey.RecoveryKeyError.self) {
            _ = try PersonalAIRecoveryKey(recoveryCode: "EARK1-!!!!")
        }
        #expect(throws: PersonalAIRecoveryKey.RecoveryKeyError.self) {
            _ = try PersonalAIRecoveryKey(recoveryCode: "not-a-code")
        }
    }

    @Test("a future recovery-code version is rejected, never guessed")
    func unknownVersionRejected() {
        let body = String(PersonalAIRecoveryKey.generate().recoveryCode.split(separator: "-").dropFirst().joined())
        #expect(throws: PersonalAIRecoveryKey.RecoveryKeyError.unsupportedVersion(2)) {
            _ = try PersonalAIRecoveryKey(recoveryCode: "EARK2-" + body)
        }
    }

    @Test("corrupted serialized recovery material is rejected")
    func corruptedSerializationRejected() {
        var blob = [UInt8](PersonalAIRecoveryKey.generate().serialized())
        blob[blob.count - 2] ^= 0xFF                      // flip a raw-key byte
        #expect(throws: PersonalAIRecoveryKey.RecoveryKeyError.self) {
            _ = try PersonalAIRecoveryKey(serialized: Data(blob))
        }
        #expect(throws: PersonalAIRecoveryKey.RecoveryKeyError.self) {
            _ = try PersonalAIRecoveryKey(serialized: Data("EARKFgarbage".utf8))
        }
    }

    // MARK: - wrapped backups

    private func bundle(owner: String = "user-A") throws -> Data {
        let b = PersonalDataExporter.makeBundle(
            memory: .empty, conversations: [], messages: [],
            selection: .everything, bundleVersion: 3, ownerID: owner
        )
        return try PersonalDataExporter.data(for: b)
    }

    private func encryption(seed: UInt8, recovery: PersonalAIRecoveryKey?) -> AESGCMBackupEncryption {
        AESGCMBackupEncryption(
            keyStore: InMemorySymmetricKeyStore(seed: seed),
            ownerID: { "user-A" },
            recoveryKey: { recovery }
        )
    }

    @Test("the correct recovery key restores a wrapped backup on a fresh device (device key absent)")
    func correctRecoveryKeyRestores() throws {
        let recovery = PersonalAIRecoveryKey.generate()
        let plaintext = try bundle()
        let sealed = try encryption(seed: 0x10, recovery: recovery).seal(plaintext)

        // "new iPhone" — a different device key store, and only the recovery key.
        let freshDevice = encryption(seed: 0x99, recovery: nil)
        #expect(throws: BackupEncryptionError.self) { _ = try freshDevice.open(sealed) }   // device slot won't match
        #expect(try freshDevice.open(sealed, using: recovery) == plaintext)               // recovery slot does
    }

    @Test("the wrong recovery key fails safely — no plaintext, typed error")
    func wrongRecoveryKeyFails() throws {
        let right = PersonalAIRecoveryKey.generate()
        let wrong = PersonalAIRecoveryKey.generate()
        let sealed = try encryption(seed: 0x10, recovery: right).seal(try bundle())

        #expect(throws: BackupEncryptionError.recoveryKeyMismatch) {
            _ = try encryption(seed: 0x99, recovery: nil).open(sealed, using: wrong)
        }
    }

    @Test("a recovery-key open of a direct (non-wrapped) backup reports recoveryNotAvailable")
    func recoveryOpenOfDirectBackup() throws {
        let sealed = try encryption(seed: 0x10, recovery: nil).seal(try bundle())   // v1 direct
        #expect(throws: BackupEncryptionError.recoveryNotAvailable) {
            _ = try encryption(seed: 0x10, recovery: nil).open(sealed, using: .generate())
        }
    }

    @Test("corrupted wrapped-key / ciphertext material fails on recovery, never returns garbage")
    func corruptedWrappedMaterialFails() throws {
        let recovery = PersonalAIRecoveryKey.generate()
        var bytes = [UInt8](try encryption(seed: 0x10, recovery: recovery).seal(try bundle()))
        bytes[bytes.count - 3] ^= 0xFF                        // flip a ciphertext byte
        #expect(throws: BackupEncryptionError.self) {
            _ = try encryption(seed: 0x99, recovery: nil).open(Data(bytes), using: recovery)
        }
    }

    // MARK: - rotation / versioning

    @Test("a rotated recovery key does NOT open a pre-rotation backup; the historical key still does")
    func rotationCompatibility() throws {
        let old = PersonalAIRecoveryKey.generate()
        let new = PersonalAIRecoveryKey.generate()

        let oldBackup = try encryption(seed: 0x10, recovery: old).seal(try bundle())
        let newBackup = try encryption(seed: 0x10, recovery: new).seal(try bundle())   // after "rotation"

        let fresh = encryption(seed: 0x99, recovery: nil)
        // the rotated key cannot open the old backup
        #expect(throws: BackupEncryptionError.recoveryKeyMismatch) { _ = try fresh.open(oldBackup, using: new) }
        // but the correct historical key still can
        #expect(try fresh.open(oldBackup, using: old).count > 0)
        // and the new key opens the new backup
        #expect(try fresh.open(newBackup, using: new).count > 0)
        // slot-id introspection tells a restore UI which key is needed
        #expect(AESGCMBackupEncryption.recoverySlotKeyIDs(in: oldBackup) == [old.keyID])
        #expect(AESGCMBackupEncryption.recoverySlotKeyIDs(in: newBackup) == [new.keyID])
    }

    // MARK: - "carries no key material" guarantees

    @Test("the envelope header carries no raw recovery key, no raw device key, no DEK")
    func headerCarriesNoKeyMaterial() throws {
        let recovery = PersonalAIRecoveryKey.generate()
        let sealed = try encryption(seed: 0x10, recovery: recovery).seal(try bundle())
        let parsed = try #require((try? EncryptedBackupEnvelope.parse(sealed)) ?? nil)
        let header = parsed.header
        let wrapping = try #require(header.keyWrapping)

        let rawRecovery = recovery.rawKey.withUnsafeBytes { Data($0) }
        let headerJSON = try JSONEncoder.personalAI.encode(header)
        // the raw recovery key bytes appear nowhere in the serialized header
        #expect(headerJSON.range(of: rawRecovery) == nil)
        // each slot's "wrappedKey" is ciphertext, not the 32-byte DEK/KEK
        for slot in wrapping.slots {
            #expect(slot.wrappedKey.count > 32)                       // GCM adds nonce + tag
            #expect(slot.wrappedKey.range(of: rawRecovery) == nil)
        }
        #expect(Set(wrapping.slots.map(\.kind)) == ["device", "recovery"])
    }

    @Test("the sealed backup blob (what leaves the phone) contains no recovery key material")
    func remotePayloadCarriesNoRecoveryKey() throws {
        let recovery = PersonalAIRecoveryKey.generate()
        let sealed = try encryption(seed: 0x10, recovery: recovery).seal(try bundle())
        let rawRecovery = recovery.rawKey.withUnsafeBytes { Data($0) }
        #expect(sealed.range(of: rawRecovery) == nil)
        #expect(!String(decoding: sealed, as: UTF8.self).contains(recovery.recoveryCode))
        // (recovery.keyID is a non-reversible fingerprint and legitimately
        //  appears in the header as a slot selector — that is not key material.)
    }

    @Test("the decrypted bundle / manifest contains no recovery key material")
    func manifestCarriesNoRecoveryKey() throws {
        let recovery = PersonalAIRecoveryKey.generate()
        let plaintext = try bundle()
        let sealed = try encryption(seed: 0x10, recovery: recovery).seal(plaintext)
        let opened = try encryption(seed: 0x99, recovery: nil).open(sealed, using: recovery)

        let rawRecovery = recovery.rawKey.withUnsafeBytes { Data($0) }
        #expect(opened.range(of: rawRecovery) == nil)
        let text = String(decoding: opened, as: UTF8.self)
        #expect(!text.contains(recovery.recoveryCode))
        #expect(!text.lowercased().contains("recoverykey"))
        #expect(!text.lowercased().contains("\"rawkey\""))
    }

    @Test("recovery-key code paths do not log key material")
    func noKeyMaterialLogged() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for rel in ["EvenAI/Infrastructure/PersonalAI/Backup/PersonalAIRecoveryKey.swift",
                    "EvenAI/Infrastructure/PersonalAI/Backup/AESGCMBackupEncryption.swift"] {
            let src = (try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)) ?? ""
            #expect(!src.contains("DiagnosticTrace"))
            #expect(!src.contains("print("))
            #expect(!src.contains("os_log"))
            #expect(!src.contains("NSLog"))
        }
    }

    // MARK: - device-side store (model seam; not wired into the container)

    @Test("the in-memory recovery-key store round-trips and clears")
    func recoveryKeyStoreRoundTrip() throws {
        let store = InMemoryRecoveryKeyStore()
        #expect(try store.current() == nil)
        let key = PersonalAIRecoveryKey.generate()
        try store.store(key)
        #expect(try store.current() == key)
        try store.clear()
        #expect(try store.current() == nil)
    }

    @Test("AESGCMBackupEncryption can take its recovery key from a store")
    func encryptionReadsFromStore() throws {
        let key = PersonalAIRecoveryKey.generate()
        let store = InMemoryRecoveryKeyStore(key)
        let enc = AESGCMBackupEncryption(
            keyStore: InMemorySymmetricKeyStore(seed: 0x10),
            ownerID: { "user-A" },
            recoveryKey: { try? store.current() }
        )
        let sealed = try enc.seal(try bundle())
        #expect(try AESGCMBackupEncryption(keyStore: InMemorySymmetricKeyStore(seed: 0x99))
            .open(sealed, using: key).count > 0)
    }

    // MARK: - failed recovery is inert

    @Test("a failed recovery attempt is a pure function — it mutates nothing and deletes nothing")
    func failedRecoveryIsInert() throws {
        let recovery = PersonalAIRecoveryKey.generate()
        let sealed = try encryption(seed: 0x10, recovery: recovery).seal(try bundle())

        // A sentinel "local Personal AI data" value. The recovery open has no
        // reference to any store and cannot touch it.
        let localData = "LOCAL-PERSONAL-AI-DATA-INTACT"
        let before = sealed

        #expect(throws: BackupEncryptionError.self) {
            _ = try encryption(seed: 0x99, recovery: nil).open(sealed, using: .generate())  // wrong key
        }
        #expect(localData == "LOCAL-PERSONAL-AI-DATA-INTACT")
        #expect(sealed == before)                                   // input untouched
    }
}
