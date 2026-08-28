import Testing
import Foundation
@testable import EvenAI

@Suite("Personal AI Cloud: local encryption at rest")
struct EncryptedDocumentFileTests {

    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("enc-\(UUID().uuidString).bin")
    }

    @Test("sealed bytes are not plaintext and open back to the original")
    func sealAndOpen() throws {
        let store = EncryptedDocumentFile(keyStore: InMemorySymmetricKeyStore())
        let url = tempFile()
        let plaintext = Data(#"{"secret":"the launch budget is 4 million"}"#.utf8)

        try store.write(plaintext, to: url)
        let onDisk = try Data(contentsOf: url)
        #expect(onDisk != plaintext)
        #expect(String(data: onDisk, encoding: .utf8)?.contains("launch budget") != true)

        let reopened = try store.read(from: url)
        #expect(reopened == plaintext)
    }

    @Test("a wrong key cannot open the file")
    func wrongKeyFails() throws {
        let url = tempFile()
        try EncryptedDocumentFile(keyStore: InMemorySymmetricKeyStore(seed: 0x01)).write(Data("hi".utf8), to: url)
        #expect(throws: (any Error).self) {
            _ = try EncryptedDocumentFile(keyStore: InMemorySymmetricKeyStore(seed: 0x02)).read(from: url)
        }
    }

    @Test("a Phase 1 plaintext file is read transparently and re-sealed on next write")
    func plaintextMigration() throws {
        let url = tempFile()
        let legacy = Data(#"{"schemaVersion":1,"records":[]}"#.utf8)
        try legacy.write(to: url)  // Phase 1 wrote plain JSON

        let store = EncryptedDocumentFile(keyStore: InMemorySymmetricKeyStore())
        let read = try store.read(from: url)
        #expect(read == legacy)  // transparent read

        // Next write seals it.
        try store.write(legacy, to: url)
        let onDisk = try Data(contentsOf: url)
        #expect(String(data: onDisk, encoding: .utf8)?.hasPrefix("{") != true)
        #expect(try store.read(from: url) == legacy)
    }

    @Test("reading a missing file returns nil, not an error")
    func missingFileIsNil() throws {
        let store = EncryptedDocumentFile(keyStore: InMemorySymmetricKeyStore())
        #expect(try store.read(from: tempFile()) == nil)
    }
}
