import Testing
import Foundation
@testable import EvenAI

/// PART B — the canonical, **versioned** R2 object namespace
/// (`BackupObjectNamespace`). The version is defined in one place; generation
/// validates and rejects unsafe input; the reader never reinterprets an
/// unknown version.
///
/// No real R2 data exists, so there is **no migration** — the versioned layout
/// is simply what every object written from now on uses.
@Suite("Backup: versioned object namespace")
struct BackupObjectNamespaceTests {

    private let tagA = BackupOwnerTag.tag("user-A")
    private let tagB = BackupOwnerTag.tag("user-B")
    private let backupID = UUID().uuidString

    // MARK: - canonical generation

    @Test("the canonical v1 catalog and object keys have the exact expected shape")
    func canonicalV1Paths() throws {
        #expect(BackupObjectNamespace.currentVersion == 1)
        let catalog = try BackupObjectNamespace.catalogKey(ownerTag: tagA)
        #expect(catalog == "backup/v1/\(tagA)/catalog.json")

        let object = try BackupObjectNamespace.objectKey(
            ownerTag: tagA, bundleVersion: 7, tier: "daily", backupID: backupID
        )
        #expect(object == "backup/v1/\(tagA)/objects/7-daily-\(backupID).eapb")
        #expect(try BackupObjectNamespace.objectsPrefix(ownerTag: tagA) == "backup/v1/\(tagA)/objects")
        #expect(try BackupObjectNamespace.ownerRoot(ownerTag: tagA) == "backup/v1/\(tagA)")
    }

    @Test("the same inputs always produce the same path")
    func deterministic() throws {
        let a = try BackupObjectNamespace.objectKey(ownerTag: tagA, bundleVersion: 2, tier: "weekly", backupID: backupID)
        let b = try BackupObjectNamespace.objectKey(ownerTag: tagA, bundleVersion: 2, tier: "weekly", backupID: backupID)
        #expect(a == b)
    }

    @Test("different users and different backups never collide")
    func noCollisions() throws {
        let id1 = UUID().uuidString, id2 = UUID().uuidString
        let userAKey = try BackupObjectNamespace.objectKey(ownerTag: tagA, bundleVersion: 1, tier: "daily", backupID: id1)
        let userBKey = try BackupObjectNamespace.objectKey(ownerTag: tagB, bundleVersion: 1, tier: "daily", backupID: id1)
        let backup2Key = try BackupObjectNamespace.objectKey(ownerTag: tagA, bundleVersion: 1, tier: "daily", backupID: id2)
        #expect(userAKey != userBKey)
        #expect(userAKey != backup2Key)
        #expect(!userAKey.hasPrefix("backup/v1/\(tagB)"))
        #expect(!userBKey.hasPrefix("backup/v1/\(tagA)"))
    }

    @Test("no PII / raw id / memory text can be in a key — the owner tag is opaque hex")
    func noPIILeakage() throws {
        let key = try BackupObjectNamespace.objectKey(
            ownerTag: BackupOwnerTag.tag("auth0|nestor@example.com"),
            bundleVersion: 1, tier: "daily", backupID: backupID
        )
        #expect(!key.contains("@"))
        #expect(!key.lowercased().contains("nestor"))
        #expect(!key.lowercased().contains("example"))
        // owner segment is 64 lowercase hex
        let ownerSeg = key.split(separator: "/")[2]
        #expect(ownerSeg.count == 64)
        #expect(ownerSeg.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    // MARK: - rejection of unsafe input

    @Test("generation rejects a malformed owner tag")
    func rejectsMalformedOwnerTag() {
        for bad in ["", "SHORT", tagA.uppercased(), tagA + "x", "../" + tagA, tagA.replacingOccurrences(of: "a", with: "/")] {
            #expect(throws: BackupObjectNamespace.NamespaceError.self) {
                _ = try BackupObjectNamespace.objectKey(ownerTag: bad, bundleVersion: 1, tier: "daily", backupID: backupID)
            }
        }
    }

    @Test("generation rejects traversal, slash / backslash injection, and percent-encoded separators in the backup id")
    func rejectsUnsafeBackupID() {
        let unsafe = [
            "", "..", ".", "a/b", "a\\b", "a%2Fb", "a%2fb", "a%5Cb", "a%2Eb",
            "../../etc", "x\u{0000}y", "x\u{0007}y", "x y", "id.with.dot",
            String(repeating: "a", count: 129),
        ]
        for id in unsafe {
            #expect(throws: BackupObjectNamespace.NamespaceError.self) {
                _ = try BackupObjectNamespace.objectKey(ownerTag: tagA, bundleVersion: 1, tier: "daily", backupID: id)
            }
        }
        // a real UUID is fine (upper or lower)
        #expect(throws: Never.self) {
            _ = try BackupObjectNamespace.objectKey(ownerTag: tagA, bundleVersion: 1, tier: "daily", backupID: UUID().uuidString)
        }
    }

    @Test("generation rejects an unknown tier and a negative bundle version")
    func rejectsBadTierAndVersion() {
        #expect(throws: BackupObjectNamespace.NamespaceError.invalidTier) {
            _ = try BackupObjectNamespace.objectKey(ownerTag: tagA, bundleVersion: 1, tier: "hourly", backupID: backupID)
        }
        #expect(throws: BackupObjectNamespace.NamespaceError.invalidBundleVersion) {
            _ = try BackupObjectNamespace.objectKey(ownerTag: tagA, bundleVersion: -1, tier: "daily", backupID: backupID)
        }
    }

    // MARK: - reading / parsing

    @Test("parse round-trips a canonical catalog and object key")
    func parseRoundTrip() throws {
        let cat = try BackupObjectNamespace.catalogKey(ownerTag: tagA)
        #expect(BackupObjectNamespace.parse(cat) == .init(version: 1, ownerTag: tagA, component: .catalog))

        let obj = try BackupObjectNamespace.objectKey(ownerTag: tagA, bundleVersion: 9, tier: "monthly", backupID: backupID)
        #expect(BackupObjectNamespace.parse(obj) == .init(
            version: 1, ownerTag: tagA,
            component: .object(bundleVersion: 9, tier: "monthly", backupID: backupID)
        ))
    }

    @Test("an UNKNOWN namespace version fails safely — parse returns nil, it is never reinterpreted")
    func unknownVersionFailsSafely() {
        let v2 = "backup/v2/\(tagA)/catalog.json"
        let v99 = "backup/v99/\(tagA)/objects/1-daily-\(backupID).eapb"
        let vx = "backup/vx/\(tagA)/catalog.json"
        for key in [v2, v99, vx] {
            #expect(BackupObjectNamespace.parse(key) == nil)
            #expect(!BackupObjectNamespace.isRecognisedVersionKey(key, ownerTag: tagA))
            #expect(!BackupObjectNamespace.isCurrentVersionKey(key, ownerTag: tagA))
            // and the authorizer refuses to grant against it — the unknown
            // prefix is NOT stripped, so it can't match the owner namespace.
            #expect(!BackupAuthorizationScope.keyIsInOwnerNamespace(key, ownerTag: tagA))
        }
        // A future build that adds 2 to `recognisedVersions` + a v2 reader is
        // how v2 coexists — until then, v2 is simply "not ours".
        #expect(BackupObjectNamespace.recognisedVersions == [1])
    }

    @Test("parse rejects malformed shapes without throwing")
    func parseRejectsMalformed() {
        for key in [
            "backup/v1/\(tagA)",                                   // no component
            "backup/v1/\(tagA)/catalog.txt",                       // wrong file
            "backup/v1/\(tagA)/objects/not-a-valid-object",        // no .eapb
            "backup/v1/\(tagA)/objects/1-hourly-\(backupID).eapb", // bad tier
            "backup/v1/\(tagA)/objects/x-daily-\(backupID).eapb",  // non-numeric version
            "backup/v1/SHORT/catalog.json",                        // bad owner tag
            "backup/v1/\(tagA)/../\(tagB)/catalog.json",           // traversal
            "\(tagA)/catalog.json",                                // bare (no version prefix) — not a v1 key
            "",
        ] {
            #expect(BackupObjectNamespace.parse(key) == nil, "should not parse: \(key)")
        }
    }

    // MARK: - authorizer namespace check (prefix-aware)

    @Test("keyIsInOwnerNamespace accepts a canonical v1 key and a bare legacy key, rejects cross-owner and unknown-version")
    func authorizerNamespaceCheck() throws {
        let v1 = try BackupObjectNamespace.objectKey(ownerTag: tagA, bundleVersion: 1, tier: "daily", backupID: backupID)
        #expect(BackupAuthorizationScope.keyIsInOwnerNamespace(v1, ownerTag: tagA))
        #expect(!BackupAuthorizationScope.keyIsInOwnerNamespace(v1, ownerTag: tagB))            // cross-owner
        #expect(BackupAuthorizationScope.keyIsInOwnerNamespace("\(tagA)/catalog.json", ownerTag: tagA)) // bare legacy
        #expect(!BackupAuthorizationScope.keyIsInOwnerNamespace("backup/v2/\(tagA)/catalog.json", ownerTag: tagA))
        #expect(!BackupAuthorizationScope.keyIsInOwnerNamespace("backup/v1/\(tagA)/../\(tagB)/x", ownerTag: tagA))
    }

    // MARK: - R2BackupStore uses the versioned namespace end-to-end

    @Test("every key R2BackupStore writes / reads / deletes is a canonical current-version key")
    func r2BackupStoreUsesVersionedNamespace() async throws {
        let s = FakeBackupAuthorizationServer(identities: ["token-A": tagA])
        let store = s.backupStore(for: "token-A")
        let h = BackupHandle(id: UUID().uuidString, createdAt: Date(), bundleVersion: 1,
                             sizeBytes: 0, checksum: "c", tier: "daily")

        try await store.putBackup(Data("sealed".utf8), handle: h, ownerID: "user-A")
        _ = try await store.listBackups(ownerID: "user-A")

        // after a put+catalog write, both key kinds are present and canonical
        let afterPut = s.committedObjectKeys()
        #expect(afterPut.contains { $0 == "backup/v1/\(tagA)/catalog.json" })
        #expect(afterPut.contains { BackupObjectNamespace.parse($0)?.component != .catalog && $0.hasSuffix(".eapb") })
        for key in afterPut {
            #expect(BackupObjectNamespace.isCurrentVersionKey(key, ownerTag: tagA), "not canonical: \(key)")
            let parsed = BackupObjectNamespace.parse(key)
            #expect(parsed?.version == 1)
            #expect(parsed?.ownerTag == tagA)
        }

        // delete stays scoped to the v1 namespace too
        try await store.deleteBackup(h, ownerID: "user-A")
        for key in s.committedObjectKeys() {
            #expect(BackupObjectNamespace.isCurrentVersionKey(key, ownerTag: tagA), "not canonical after delete: \(key)")
        }
    }

    @Test("a grant for user A's v1 namespace cannot be obtained for a key in user B's v1 namespace")
    func crossOwnerV1GrantRefused() async {
        let s = FakeBackupAuthorizationServer(identities: ["token-A": tagA, "token-B": tagB])
        let credsA = s.credentialProvider(identityToken: "token-A")
        let bKey = (try? BackupObjectNamespace.objectKey(ownerTag: tagB, bundleVersion: 1, tier: "daily", backupID: backupID)) ?? ""
        await #expect(throws: BackupCredentialError.self) {
            _ = try await credsA.presign(.put, key: bKey, ownerTag: tagB)
        }
    }
}
