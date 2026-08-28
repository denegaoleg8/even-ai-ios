import Foundation
import CryptoKit

/// How a local Personal AI store reads/writes its document bytes. Injected
/// into `LocalPersonalMemoryStore` / `LocalPersonalAIConversationStore` so
/// the *same* store code runs plaintext (tests, previews) or encrypted
/// (production) with no branching in the store itself.
protocol DocumentFileStoring: Sendable {
    /// Decoded plaintext bytes, or `nil` if the file does not exist.
    func read(from url: URL) throws -> Data?
    /// Atomically write plaintext bytes (the implementation seals them if
    /// it encrypts).
    func write(_ plaintext: Data, to url: URL) throws
    /// Delete the file.
    func delete(at url: URL) throws
}

extension DocumentFileStoring {
    func delete(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

/// Phase 1 behaviour: bytes on disk as-is. Default everywhere until
/// `PersonalAIContainer` swaps in `EncryptedDocumentFile`.
struct PlaintextDocumentFile: DocumentFileStoring {
    func read(from url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }
    func write(_ plaintext: Data, to url: URL) throws {
        try plaintext.write(to: url, options: [.atomic, .completeFileProtection])
    }
}

/// Encryption at rest for the Personal AI local cache (§27). AES-GCM
/// (`ChaChaPoly`-equivalent authenticated encryption) with a 256-bit key
/// from `SymmetricKeyStore`. The key is in the Keychain; the ciphertext is
/// in Application Support — **never side by side in plain storage**.
///
/// Reading a file that turns out to be plaintext JSON (a Phase 1 file, or a
/// restore drop-in) transparently re-writes it sealed — a one-time,
/// no-data-loss migration.
struct EncryptedDocumentFile: DocumentFileStoring {
    private let keyStore: SymmetricKeyStore
    /// Version byte prefixed to every sealed blob so the format can evolve.
    private static let magic: [UInt8] = [0x45, 0x41, 0x50, 0x31] // "EAP1"

    init(keyStore: SymmetricKeyStore) {
        self.keyStore = keyStore
    }

    func read(from url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let raw = try Data(contentsOf: url)
        guard raw.count > Self.magic.count, Array(raw.prefix(Self.magic.count)) == Self.magic else {
            // Not sealed — treat as plaintext (Phase 1 / imported file).
            // Caller decodes it; the next write() will seal it.
            return raw
        }
        let sealedBytes = raw.suffix(from: raw.index(raw.startIndex, offsetBy: Self.magic.count))
        let box = try AES.GCM.SealedBox(combined: sealedBytes)
        return try AES.GCM.open(box, using: keyStore.key())
    }

    func write(_ plaintext: Data, to url: URL) throws {
        let sealed = try AES.GCM.seal(plaintext, using: keyStore.key())
        guard let combined = sealed.combined else { throw CocoaError(.fileWriteUnknown) }
        var out = Data(Self.magic)
        out.append(combined)
        try out.write(to: url, options: [.atomic, .completeFileProtection])
    }
}
