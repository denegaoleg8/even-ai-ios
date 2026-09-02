import Testing
import Foundation
import CryptoKit
@testable import EvenAI

/// **LOCAL CONTRACT TESTS** for the future real Cloudflare Worker + R2 backup
/// deployment (see `PHASE2_R2_DEPLOYMENT_READINESS.md`). Every test here runs
/// with **no network and no Cloudflare resource** — it pins a contract that the
/// deployed Worker must also satisfy, or exercises client-side behaviour that
/// must hold before deployment.
///
/// What these do **not** cover — flagged `REAL DEPLOYMENT TEST REQUIRED` in the
/// readiness doc: real presigned-URL semantics, real R2 durability, real
/// atomic replay/idempotency storage, real token verification, real
/// cross-user isolation against a live bucket.
@Suite("R2 deployment: local contracts", .serialized)
struct R2DeploymentContractTests {

    // MARK: - §4  Owner-tag v1 — cross-language proof

    /// The SAME fixtures and SAME expected hex as
    /// `cloudflare/backup-worker/test/owner-tag-vectors.test.ts`. Both suites
    /// compute the tag independently and assert equality with these constants,
    /// so a drift between the Swift `BackupOwnerTag.tag(_:)` and the Worker
    /// `deriveOwnerTagV1` fails one side. Non-secret fixtures.
    static let ownerTagVectors: [(input: String, expectedHex: String)] = [
        ("user-A", "d5f24b52433196da1ad2febc17e66dabedc36cb2ffdd9ea6cdcf3f833d1cc97a"),
        ("user-B", "1c32fe9cff154e280ea15e0c5e16c2971bc96d0ed5f11c405826936f70b919be"),
        ("dev:user-A", "07728a26cbf2f8e5f0b46fd2faf83c93c3aa1bbe74f5c5c656b00c6cf0cfca1f"),
        ("00000000-0000-0000-0000-000000000000", "ed31e07852bf2b78a069ed3e1d463cea6ef329897fc2c5df06e13c92ff01b047"),
        ("apple:001234.abcdef0123456789.4242", "d705978cd84758a519aa6be52eb077e3a4cf6eebd6420d3d6da22f454ad81e4f"),
        ("", "4d39a7717a77088a526b6705c8b6df986d4f1f39c2557bb1ddd13930bf9f09a1"),
        ("u", "0bd54f91e37a90c4d1d0392328a932f1490c03fc5d289a614591d61f0683db9e"),
        ("éè-user", "7bf412a428cb37dc7435a1e803038b84868b0f74b97c73a6ae8134e609e039c8"),
        (String(repeating: "a", count: 256), "91870690d1fdab8952fe0b1214493484d3fb4f350728ff656384bd5bf2036c83"),
    ]

    @Test("ownerTag v1 — Swift matches the shared cross-language vectors byte-for-byte")
    func ownerTagV1CrossLanguageVectors() {
        // Independent recomputation of the canonical algorithm, to catch a
        // change to BackupOwnerTag itself (not just a copy-paste of its output).
        let domain = Data("evenai.personal-ai.backup.owner-tag.v1".utf8)
        for (input, expected) in Self.ownerTagVectors {
            let reference = SHA256.hash(data: domain + Data(input.utf8))
                .map { String(format: "%02x", $0) }.joined()
            #expect(reference == expected, "reference algo drifted for \(input.debugDescription)")
            #expect(BackupOwnerTag.tag(input) == expected,
                    "BackupOwnerTag.tag drifted for \(input.debugDescription)")
        }
    }

    @Test("ownerTag v1 — opaque, no PII, deterministic, per-user distinct")
    func ownerTagV1Properties() {
        let sensitive = "auth0|deneganestor1976@example.com"
        let tag = BackupOwnerTag.tag(sensitive)
        #expect(tag.count == 64)
        #expect(tag.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) })
        #expect(!tag.contains("@"))
        #expect(!tag.lowercased().contains("denega"))
        #expect(!tag.lowercased().contains("example"))
        #expect(BackupOwnerTag.tag(sensitive) == tag)                 // deterministic
        #expect(BackupOwnerTag.tag(sensitive + "x") != tag)           // per-user distinct
        // Not trivially reversible: the tag reveals nothing about input length.
        #expect(BackupOwnerTag.tag("a").count == BackupOwnerTag.tag(String(repeating: "a", count: 4096)).count)
    }

    // MARK: - §7  Canonical object namespace

    private func handle(id: String = UUID().uuidString, version: Int = 3, tier: String = "daily", size: Int = 0) -> BackupHandle {
        BackupHandle(id: id, createdAt: Date(timeIntervalSince1970: 1_760_000_000), bundleVersion: version,
                     sizeBytes: size, checksum: "sha256-checksum-hex", tier: tier)
    }

    @Test("object keys the client produces are owner-scoped, PII-free, deterministic, and well-formed")
    func objectKeyNamespaceContract() async throws {
        let (store, transport) = FakeR2.store()
        let rawUserID = "auth0|user-1234@example.com"
        let tag = BackupOwnerTag.tag(rawUserID)
        try await store.putBackup(Data("sealed".utf8), handle: handle(id: "h-1"), ownerID: rawUserID)

        let keys = transport.keys().map { URL(string: $0)!.path.drop(while: { $0 == "/" }) }.map(String.init)
        #expect(!keys.isEmpty)
        for key in keys {
            #expect(key.hasPrefix("backup/v\(BackupObjectNamespace.currentVersion)/\(tag)/"), "key not under versioned owner namespace: \(key)")
            #expect(BackupObjectNamespace.isCurrentVersionKey(key, ownerTag: tag), "not a canonical current-version key: \(key)")
            #expect(BackupAuthorizationScope.keyIsInOwnerNamespace(key, ownerTag: tag), "malformed/out-of-namespace: \(key)")
            #expect(!key.contains(rawUserID))
            #expect(!key.contains("@"))
            #expect(!key.lowercased().contains("example"))
            #expect(!key.lowercased().contains("denega"))
            #expect(key.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F })
        }
        #expect(keys.contains { $0.hasSuffix("/catalog.json") })
        #expect(keys.contains { $0.hasSuffix(".eapb") })

        // Deterministic: the same (owner, handle) re-derives the same key.
        let (store2, transport2) = FakeR2.store()
        try await store2.putBackup(Data("sealed".utf8), handle: handle(id: "h-1"), ownerID: rawUserID)
        #expect(Set(transport2.keys().map { URL(string: $0)!.path }) == Set(transport.keys().map { URL(string: $0)!.path }))
    }

    @Test("path traversal and malformed keys are rejected by the shared key-validity primitive")
    func pathTraversalAndMalformedKeysRejected() {
        let a = BackupOwnerTag.tag("user-A")
        let b = BackupOwnerTag.tag("user-B")
        let rejected = [
            "", "/\(a)/x", "\(a)//x", "\(a)/x/", "\(a)/./x", "\(a)/../\(b)/x",
            "\(a)/objects/../../\(a)/catalog.json", "\(a)/\u{0007}x", String(repeating: "z", count: 513),
        ]
        for key in rejected {
            #expect(!BackupAuthorizationScope.keyIsWellFormed(key), "should reject: \(key.debugDescription)")
        }
        #expect(!BackupAuthorizationScope.keyIsInOwnerNamespace("\(b)/objects/x.eapb", ownerTag: a)) // cross-owner
        #expect(BackupAuthorizationScope.keyIsInOwnerNamespace("\(a)/objects/3-daily-\(UUID().uuidString).eapb", ownerTag: a))
        #expect(BackupAuthorizationScope.keyIsWellFormed("\(a)/catalog.json"))
    }

    // MARK: - §9  Remote catalog / manifest carries no plaintext or PII

    @Test("the remote catalog (the only server-visible index) contains only structural handle metadata")
    func remoteCatalogCarriesNoPlaintextOrPII() async throws {
        let marker = "TOP-SECRET-MEMORY-\(UUID().uuidString)"
        let rawUserID = "auth0|private-user-\(UUID().uuidString)@example.com"
        let (store, transport) = FakeR2.store()

        let enc = AESGCMBackupEncryption(keyStore: InMemorySymmetricKeyStore(seed: 11), ownerID: { rawUserID })
        let sealed = try enc.seal(Data("{\"memory\":\"\(marker)\"}".utf8))
        try await store.putBackup(sealed, handle: handle(id: "cat-1", size: sealed.count), ownerID: rawUserID)

        let catalog = try #require(transport.rawData(forKeySuffix: "catalog.json"))
        let text = String(decoding: catalog, as: UTF8.self)
        #expect(!text.contains(marker))                       // no plaintext memory
        #expect(!text.contains(rawUserID))                    // no raw user id
        #expect(!text.contains("@"))                          // no email
        #expect(!text.contains("BEGIN"))                      // no key material

        let json = try #require(try JSONSerialization.jsonObject(with: catalog) as? [String: Any])
        #expect(Set(json.keys).isSubset(of: ["version", "handles"]))
        let handles = try #require(json["handles"] as? [[String: Any]])
        let allowed: Set<String> = ["id", "createdAt", "bundleVersion", "sizeBytes", "checksum", "tier"]
        for h in handles {
            #expect(Set(h.keys).isSubset(of: allowed), "unexpected catalog field: \(Set(h.keys).subtracting(allowed))")
        }
    }

    // MARK: - §2 / §8  Scope binds operation + object + owner

    @Test("an authorization scope binds exactly one operation, one object, one owner")
    func scopeBindsOperationObjectOwner() {
        let a = BackupOwnerTag.tag("user-A")
        let b = BackupOwnerTag.tag("user-B")
        let key = "\(a)/objects/3-daily-\(UUID().uuidString).eapb"
        let scope = BackupAuthorizationScope(ownerTag: a, objectKey: key, operation: .put)

        #expect(scope.authorizes(.put, key: key, ownerTag: a))
        #expect(!scope.authorizes(.get, key: key, ownerTag: a))                       // wrong operation
        #expect(!scope.authorizes(.delete, key: key, ownerTag: a))
        #expect(!scope.authorizes(.put, key: "\(a)/objects/other.eapb", ownerTag: a)) // wrong object
        #expect(!scope.authorizes(.put, key: key, ownerTag: b))                       // wrong owner
        #expect(!scope.authorizes(.put, key: "\(a)/../\(b)/x", ownerTag: a))          // traversal
    }

    // MARK: - §8  Expired authorization is unusable client-side

    @Test("an expired grant is never used — the client re-requests")
    func expiredAuthorizationIsUnusable() async {
        let client = BackupAuthorizationClient(wrapping: FakePresignProvider(grantTTL: -1))
        await #expect(throws: BackupCredentialError.expired) {
            _ = try await client.presign(.get, key: "\(BackupOwnerTag.tag("user-A"))/catalog.json",
                                         ownerTag: BackupOwnerTag.tag("user-A"))
        }
        let past = PresignedBackupRequest(
            url: URL(string: "https://signed.invalid/x")!, headers: [:],
            expiresAt: Date().addingTimeInterval(-0.001),
            scope: BackupAuthorizationScope(ownerTag: "t", objectKey: "t/x", operation: .get))
        #expect(past.isExpired)
    }

    // MARK: - §2 / §12  Account switch → disjoint namespace

    @Test("two Personal AI identities derive disjoint, non-overlapping object namespaces")
    func accountSwitchProducesDisjointNamespace() async throws {
        let (a, ta) = (FakeR2.store(), BackupOwnerTag.tag("acct-A"))
        let (b, tb) = (FakeR2.store(), BackupOwnerTag.tag("acct-B"))
        try await a.store.putBackup(Data("a".utf8), handle: handle(id: "a1"), ownerID: "acct-A")
        try await b.store.putBackup(Data("b".utf8), handle: handle(id: "b1"), ownerID: "acct-B")

        let aKeys = a.transport.keys().map { URL(string: $0)!.path }
        let bKeys = b.transport.keys().map { URL(string: $0)!.path }
        #expect(ta != tb)
        #expect(aKeys.allSatisfy { $0.contains(ta) && !$0.contains(tb) })
        #expect(bKeys.allSatisfy { $0.contains(tb) && !$0.contains(ta) })
        // B's store, asked for A's identity, would key under A's tag — but B
        // never holds A's grant, so cross-read is structurally impossible.
        #expect(try await b.store.listBackups(ownerID: "acct-B").count == 1)
    }

    // MARK: - §5  Idempotency-key format contract (spec pinned; not yet wired)

    /// The format the future presign request body's `idempotencyKey` must use.
    /// A pure validator so the deployed Worker and the client agree on what a
    /// well-formed key is *before* either implements the wire field.
    /// Contract: lowercase UUIDv4 string, exactly 36 chars, `8-4-4-4-12` hex.
    static func isWellFormedIdempotencyKey(_ s: String) -> Bool {
        guard s.count == 36 else { return false }
        guard s == s.lowercased() else { return false }
        guard let uuid = UUID(uuidString: s) else { return false }
        // UUIDv4: version nibble == 4, variant bits == 10xx.
        let bytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }
        return (bytes[6] >> 4) == 0x4 && (bytes[8] >> 6) == 0b10
    }

    @Test("idempotency-key format contract accepts a v4 UUID and rejects everything else")
    func idempotencyKeyFormatContract() {
        #expect(Self.isWellFormedIdempotencyKey(UUID().uuidString.lowercased()))
        #expect(!Self.isWellFormedIdempotencyKey(UUID().uuidString))                       // uppercase
        #expect(!Self.isWellFormedIdempotencyKey("not-a-uuid"))
        #expect(!Self.isWellFormedIdempotencyKey(""))
        #expect(!Self.isWellFormedIdempotencyKey("00000000-0000-0000-0000-000000000000"))  // nil UUID, not v4
        #expect(!Self.isWellFormedIdempotencyKey("123e4567-e89b-12d3-a456-426614174000"))  // v1
        #expect(!Self.isWellFormedIdempotencyKey(UUID().uuidString.lowercased() + " "))
    }

    // MARK: - §14  Audit-event redaction contract (spec pinned)

    /// The ONLY fields a production audit log line may carry. Anything not on
    /// this allowlist — token, presigned URL, ciphertext bytes, plaintext,
    /// keys, R2 credentials, raw user id, email — must be structurally
    /// impossible to log. Pinned here so the deployed Worker's logger has an
    /// executable target.
    static let auditEventAllowlist: Set<String> = [
        "event", "ts", "ownerTag", "operation", "objectKeySuffix",
        "grantID", "requestID", "outcome", "ciphertextBytes", "latencyMs",
    ]
    static let auditEventForbiddenSubstrings = [
        "Authorization", "Bearer ", "X-Amz-Signature", "X-Amz-Credential",
        "https://", "BEGIN ", "SymmetricKey", "recoveryKey", "R2_SECRET",
    ]

    @Test("a well-formed audit event carries only allowlisted, non-sensitive fields")
    func auditEventRedactionContract() {
        let event: [String: String] = [
            "event": "presign_issued",
            "ts": "2026-09-01T00:00:00Z",
            "ownerTag": BackupOwnerTag.tag("user-A"),
            "operation": "put",
            "objectKeySuffix": "3-daily-abc.eapb",
            "grantID": UUID().uuidString,
            "requestID": UUID().uuidString,
            "outcome": "ok",
            "ciphertextBytes": "20480",
            "latencyMs": "12",
        ]
        #expect(Set(event.keys).isSubset(of: Self.auditEventAllowlist))
        let serialized = event.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        for bad in Self.auditEventForbiddenSubstrings {
            #expect(!serialized.contains(bad), "audit line leaked \(bad)")
        }
        // The owner tag is the only owner identifier permitted, and it is
        // already opaque (proven above).
        #expect(!serialized.contains("@"))
    }

    // MARK: - guardrail

    @Test("the new deployment-readiness doc and Worker sources carry no credential or plaintext")
    func newArtifactsIntroduceNoSecret() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let banned = ["AKIA", "aws_secret_access_key", "-----BEGIN", "CLOUDFLARE_API_TOKEN"]
        var files = [root.appendingPathComponent("PHASE2_R2_DEPLOYMENT_READINESS.md")]
        let workerSrc = root.appendingPathComponent("cloudflare/backup-worker/src")
        let e = FileManager.default.enumerator(at: workerSrc, includingPropertiesForKeys: nil)
        while let u = e?.nextObject() as? URL {
            if u.pathExtension == "ts" { files.append(u) }
        }
        for file in files {
            let src = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            for token in banned {
                #expect(!src.contains(token), "\(file.lastPathComponent) contains \(token)")
            }
        }
    }
}
