import Foundation
import CryptoKit

/// SHA-256 over a bundle's payload with the manifest excluded, so a
/// truncated / tampered / partially-written backup is caught on import. The
/// hash is over a canonical (sorted-keys) JSON encoding so it is stable
/// across encode passes and platforms.
enum PersonalBundleChecksum {
    static func compute(for bundle: PersonalDataBundle) -> String {
        var payload = bundle
        payload.manifest = BackupManifest(bundleVersion: bundle.manifest.bundleVersion) // zeroed, deterministic
        payload.manifest.checksum = ""
        payload.manifest.counts = [:]
        payload.manifest.createdAt = Date(timeIntervalSince1970: 0)
        guard let data = try? canonicalEncoder.encode(payload) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func verify(_ bundle: PersonalDataBundle) -> Bool {
        !bundle.manifest.checksum.isEmpty && compute(for: bundle) == bundle.manifest.checksum
    }

    static var canonicalEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }
}

/// Turns the live Personal AI dataset into a portable, versioned
/// `PersonalDataBundle` and serializes it to a single JSON file. The file is
/// inspectable **without an EvenAI server** — it is plain JSON with a
/// self-describing manifest.
///
/// It composes only the user's Personal AI content. Auth tokens, refresh
/// tokens, API keys, session secrets and private keys are structurally
/// absent — they are not part of any type the bundle references.
struct PersonalDataExporter: Sendable {

    /// Build a bundle from a full memory document + conversations.
    static func makeBundle(
        memory: PersonalMemoryDocument,
        conversations: [PersonalAIConversation],
        messages: [PersonalAIChatMessage],
        selection: ExportSelection,
        bundleVersion: Int,
        deviceID: String? = nil,
        ownerID: String? = nil,
        appVersion: String = ""
    ) -> PersonalDataBundle {
        var mem = memory
        var convs = conversations
        var msgs = messages

        switch selection {
        case .everything:
            break
        case .memoriesOnly:
            convs = []
            msgs = []
        case .conversationsOnly:
            mem = PersonalMemoryDocument(
                styleProfile: memory.styleProfile,
                memoryEnabledGlobally: memory.memoryEnabledGlobally
            )
        }

        // Never export the contents of a "do not remember" conversation.
        let excluded = Set(convs.filter { $0.doNotRemember }.map { $0.id })
        convs.removeAll { excluded.contains($0.id) }
        msgs.removeAll { excluded.contains($0.conversationID) }

        var bundle = PersonalDataBundle(
            manifest: BackupManifest(
                bundleVersion: bundleVersion,
                deviceID: deviceID,
                ownerID: ownerID,
                appVersion: appVersion
            ),
            memory: mem,
            conversations: convs,
            messages: msgs,
            revisions: selection == .conversationsOnly ? [] : mem.revisions
        )
        bundle.manifest.counts = bundle.recordCounts
        bundle.manifest.checksum = PersonalBundleChecksum.compute(for: bundle)
        return bundle
    }

    /// Serialize a bundle to a JSON file at `url`. Returns the byte count.
    @discardableResult
    static func write(_ bundle: PersonalDataBundle, to url: URL) throws -> Int {
        let data = try PersonalBundleChecksum.canonicalEncoder.encode(bundle)
        try data.write(to: url, options: [.atomic])
        return data.count
    }

    static func data(for bundle: PersonalDataBundle) throws -> Data {
        try PersonalBundleChecksum.canonicalEncoder.encode(bundle)
    }
}
