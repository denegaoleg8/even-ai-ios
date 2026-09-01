import Testing
import Foundation
import CryptoKit
@testable import EvenAI

/// The production R2 backup path: an authenticated authorizer (Worker) in
/// front of R2, the app holding no store secret. These tests exercise the
/// **authorization boundary** specifically — identity, per-user isolation,
/// least-privilege grants, expiry, replay, and "the server only ever sees
/// ciphertext". Wrong-key / corruption / interrupted-upload / outage safety
/// is covered by `BackupHardeningTests` and `BackupEncryptionTests`; the
/// two integration checks at the end confirm those still hold through the
/// new stack.
@Suite("R2 production path: authorization & isolation", .serialized)
struct R2ProductionPathSecurityTests {

    private let tagA = BackupOwnerTag.tag("user-A")
    private let tagB = BackupOwnerTag.tag("user-B")

    private func handle(id: String = UUID().uuidString, version: Int = 1, size: Int, checksum: String = "c") -> BackupHandle {
        BackupHandle(id: id, createdAt: Date(), bundleVersion: version, sizeBytes: size, checksum: checksum, tier: "daily")
    }

    private func server(ttl: TimeInterval = 300, markers: [String] = []) -> FakeBackupAuthorizationServer {
        FakeBackupAuthorizationServer(
            identities: ["token-A": tagA, "token-B": tagB],
            grantTTL: ttl,
            plaintextMarkers: markers
        )
    }

    // MARK: - no embedded secret

    @Test("the iOS backup layer embeds no static R2 / Cloudflare / AWS secret")
    func noStaticStoreSecret() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let backupDir = root.appendingPathComponent("EvenAI/Infrastructure/PersonalAI/Backup")
        let core = root.appendingPathComponent("EvenAI/Core/Domain/PersonalAI")
        var files: [URL] = []
        for dir in [backupDir, core] {
            let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
            while let u = e?.nextObject() as? URL {
                if u.pathExtension == "swift" { files.append(u) }
            }
        }
        let banned = ["AKIA", "aws_secret_access_key", "R2_SECRET", "R2_ACCESS_KEY_ID",
                      "CLOUDFLARE_API_TOKEN", "cloudflarestorage.com", "-----BEGIN"]
        for file in files {
            let src = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            for token in banned {
                #expect(!src.contains(token), "\(file.lastPathComponent) contains \(token)")
            }
        }
    }

    @Test("the credential / transport / authorizer APIs never take a decryption key")
    func authorizerNeverNeedsDecryptionKey() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for rel in ["EvenAI/Infrastructure/PersonalAI/Backup/R2BackupStore.swift",
                    "EvenAI/Infrastructure/PersonalAI/Backup/BackupCredentialProviders.swift",
                    "EvenAI/Infrastructure/PersonalAI/Backup/BackupObjectTransports.swift",
                    "EvenAI/Infrastructure/PersonalAI/Backup/BackupAuthorizationClient.swift",
                    "EvenAI/Infrastructure/PersonalAI/Backup/R2ProductionBackupAdapter.swift"] {
            let src = (try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)) ?? ""
            #expect(!src.contains("SymmetricKey"), "\(rel) references a SymmetricKey")
            #expect(!src.contains("keyStore"), "\(rel) references a keyStore")
        }
    }

    // MARK: - identity & isolation

    @Test("an unknown identity token gets no grant")
    func unknownIdentityDenied() async {
        let s = server()
        let creds = s.credentialProvider(identityToken: "not-a-real-token")
        await #expect(throws: BackupCredentialError.self) {
            _ = try await creds.presign(.put, key: "\(tagA)/objects/x.eapb", ownerTag: tagA)
        }
    }

    @Test("user B cannot list or read user A's backups")
    func crossUserReadDenied() async throws {
        let s = server()
        let a = s.backupStore(for: "token-A")
        let b = s.backupStore(for: "token-B")
        let data = Data("sealed-A".utf8)
        let h = handle(size: data.count)
        try await a.putBackup(data, handle: h, ownerID: "user-A")

        // B's store keys off B's tag — it sees an empty catalog.
        let bList = try await b.listBackups(ownerID: "user-B")
        #expect(bList.isEmpty)
        // And B cannot fetch A's object by handle — the grant is denied.
        await #expect(throws: (any Error).self) {
            _ = try await b.getBackup(h, ownerID: "user-B")
        }
    }

    @Test("the authorizer ignores the client's claimed owner tag and scopes to the identity")
    func serverIgnoresClaimedTag() async {
        let s = server()
        // Signed in as A, but asking for a key in B's namespace while *claiming*
        // to be B. The server derives A's tag and denies.
        let credsA = s.credentialProvider(identityToken: "token-A")
        await #expect(throws: BackupCredentialError.self) {
            _ = try await credsA.presign(.put, key: "\(tagB)/objects/steal.eapb", ownerTag: tagB)
        }
    }

    @Test("the client refuses to even request a key outside its own namespace")
    func clientNamespaceGuard() async {
        // A misconfigured/buggy caller asks for another tag's key; the
        // BackupAuthorizationClient stops it before any network call.
        let client = BackupAuthorizationClient(wrapping: FakePresignProvider())
        await #expect(throws: BackupCredentialError.self) {
            _ = try await client.presign(.put, key: "\(tagB)/objects/x.eapb", ownerTag: tagA)
        }
    }

    // MARK: - least privilege

    @Test("a grant authorizes exactly one operation on exactly one key")
    func grantIsLeastPrivilege() async throws {
        let s = server()
        let creds = s.credentialProvider(identityToken: "token-A")
        let key = "\(tagA)/objects/7-daily-\(UUID().uuidString).eapb"
        let grant = try await creds.presign(.put, key: key, ownerTag: tagA)

        #expect(grant.scope?.operation == .put)
        #expect(grant.scope?.objectKey == key)
        #expect(grant.scope?.ownerTag == tagA)
        #expect(grant.covers(.put, key: key, ownerTag: tagA))
        #expect(!grant.covers(.get, key: key, ownerTag: tagA))                       // wrong operation
        #expect(!grant.covers(.put, key: "\(tagA)/objects/other.eapb", ownerTag: tagA)) // wrong object
        #expect(!grant.covers(.put, key: key, ownerTag: tagB))                       // wrong owner
    }

    // MARK: - expiry

    @Test("an already-expired grant is rejected before use")
    func expiredGrantRejected() async {
        let s = server(ttl: -10)
        let creds = BackupAuthorizationClient(wrapping: s.credentialProvider(identityToken: "token-A"))
        await #expect(throws: BackupCredentialError.expired) {
            _ = try await creds.presign(.put, key: "\(tagA)/objects/x.eapb", ownerTag: tagA)
        }
    }

    @Test("the R2 edge refuses an expired signed URL even if the client tries it")
    func expiredURLRefusedAtEdge() async throws {
        let expiredServer = server(ttl: -1)
        let creds = expiredServer.credentialProvider(identityToken: "token-A")
        let grant = try await creds.presign(.put, key: "\(tagA)/objects/x.eapb", ownerTag: tagA)
        let transport = expiredServer.transport()
        await #expect(throws: BackupTransportError.self) {
            try await transport.put(Data("x".utf8), to: grant.url, headers: grant.headers)
        }
    }

    // MARK: - path traversal / malformed keys

    @Test("a key with a `..` path segment is rejected by client and authorizer")
    func pathTraversalKeyRejected() async {
        #expect(!BackupAuthorizationScope.keyIsInOwnerNamespace("\(tagA)/../\(tagB)/objects/x.eapb", ownerTag: tagA))
        let s = server()
        let client = BackupAuthorizationClient(wrapping: s.credentialProvider(identityToken: "token-A"))
        await #expect(throws: BackupCredentialError.self) {
            _ = try await client.presign(.put, key: "\(tagA)/../\(tagB)/x.eapb", ownerTag: tagA)
        }
    }

    @Test("empty / doubled-separator / leading-slash / control-char / over-long keys are rejected")
    func malformedKeysRejected() {
        #expect(!BackupAuthorizationScope.keyIsWellFormed(""))
        #expect(!BackupAuthorizationScope.keyIsWellFormed("\(tagA)//objects/x"))
        #expect(!BackupAuthorizationScope.keyIsWellFormed("/\(tagA)/objects/x"))
        #expect(!BackupAuthorizationScope.keyIsWellFormed("\(tagA)/objects/\u{0007}x"))
        #expect(!BackupAuthorizationScope.keyIsWellFormed("\(tagA)/objects/x/"))
        #expect(!BackupAuthorizationScope.keyIsWellFormed(String(repeating: "a", count: 513)))
        #expect(!BackupAuthorizationScope.keyIsWellFormed("\(tagA)/./x"))
        // a real machine-generated key is fine
        #expect(BackupAuthorizationScope.keyIsWellFormed("\(tagA)/objects/7-daily-\(UUID().uuidString).eapb"))
        #expect(BackupAuthorizationScope.keyIsWellFormed("\(tagA)/catalog.json"))
        #expect(BackupAuthorizationScope.keyIsWellFormed(tagA))
    }

    @Test("user B cannot get a grant to write user A's catalog (finalize isolation)")
    func crossUserCatalogWriteDenied() async {
        let s = server()
        let credsB = s.credentialProvider(identityToken: "token-B")
        await #expect(throws: BackupCredentialError.self) {
            _ = try await credsB.presign(.put, key: "\(tagA)/catalog.json", ownerTag: tagA)
        }
    }

    @Test("a grant issued to one identity is useless to another (account-switch safety)")
    func staleGrantAcrossIdentitySwitch() async throws {
        let s = server()
        // A obtains a valid grant for its own object.
        let credsA = s.credentialProvider(identityToken: "token-A")
        let key = "\(tagA)/objects/x.eapb"
        let grantA = try await credsA.presign(.put, key: key, ownerTag: tagA)

        // "Account switches to B": B's store derives B's tag and never touches
        // A's key or A's grant. B cannot produce a grant for A's key.
        let credsB = s.credentialProvider(identityToken: "token-B")
        await #expect(throws: BackupCredentialError.self) {
            _ = try await credsB.presign(.put, key: key, ownerTag: tagB)
        }
        // A's grant still works for A (it was never consumed by the switch),
        // proving nothing about B's session invalidated A's namespace.
        try await s.transport().put(Data("a".utf8), to: grantA.url, headers: grantA.headers)
        #expect(s.committedObjectKeys().contains(key))
    }

    // MARK: - replay

    @Test("a mutation grant cannot be replayed")
    func mutationGrantSingleUse() async throws {
        let s = server()
        let creds = s.credentialProvider(identityToken: "token-A")
        let transport = s.transport()
        let key = "\(tagA)/objects/x.eapb"
        let grant = try await creds.presign(.put, key: key, ownerTag: tagA)

        try await transport.put(Data("v1".utf8), to: grant.url, headers: grant.headers)
        await #expect(throws: BackupTransportError.self) {
            try await transport.put(Data("v2".utf8), to: grant.url, headers: grant.headers)
        }
    }

    // MARK: - object namespace

    @Test("object keys carry only the salted owner tag — no id, email, or username")
    func opaqueObjectKeys() async throws {
        let s = server()
        let a = s.backupStore(for: "token-A")
        try await a.putBackup(Data("sealed".utf8), handle: handle(size: 6), ownerID: "user-A")

        for key in s.committedObjectKeys() {
            #expect(key.hasPrefix(tagA))
            #expect(!key.contains("user-A"))
            #expect(!key.contains("@"))
            #expect(!key.lowercased().contains("email"))
        }
        #expect(s.committedObjectKeys().contains { $0.hasSuffix("catalog.json") })
    }

    @Test("a staged object with no catalog entry is never a restore candidate")
    func stagedObjectNotRestorable() async throws {
        let s = server()
        let a = s.backupStore(for: "token-A")
        // Upload a raw object directly through a grant, but never catalog it.
        let creds = s.credentialProvider(identityToken: "token-A")
        let key = "\(tagA)/objects/9-daily-orphan.eapb"
        let grant = try await creds.presign(.put, key: key, ownerTag: tagA)
        try await s.transport().put(Data("orphan".utf8), to: grant.url, headers: grant.headers)

        // The store lists only committed (catalogued) backups.
        let list = try await a.listBackups(ownerID: "user-A")
        #expect(list.isEmpty)
    }

    @Test("re-putting the same backup id does not create a second catalog entry")
    func duplicateUploadNoDuplication() async throws {
        let s = server()
        let a = s.backupStore(for: "token-A")
        let h = handle(id: "fixed-id", size: 6)
        try await a.putBackup(Data("sealed1".utf8), handle: h, ownerID: "user-A")
        try await a.putBackup(Data("sealed2".utf8), handle: h, ownerID: "user-A")
        let list = try await a.listBackups(ownerID: "user-A")
        #expect(list.count == 1)
    }

    // MARK: - delete isolation

    @Test("user B's delete cannot address, and never removes, user A's backup object")
    func deleteIsolatedPerUser() async throws {
        let s = server()
        let a = s.backupStore(for: "token-A")
        let h = handle(id: "a-1", size: 4)
        try await a.putBackup(Data("keep".utf8), handle: h, ownerID: "user-A")

        // B runs a delete for the same handle. Every key B's store derives is
        // under B's own tag, so B physically cannot name A's object — the
        // delete is a no-op in B's (empty) namespace.
        let b = s.backupStore(for: "token-B")
        try await b.deleteBackup(h, ownerID: "user-B")

        // A's backup is still there, catalogued, and readable.
        #expect(try await a.listBackups(ownerID: "user-A").contains { $0.id == h.id })
        #expect(try await a.getBackup(h, ownerID: "user-A") == Data("keep".utf8))
        #expect(s.committedObjectKeys().contains { $0.hasPrefix(tagA) && $0.hasSuffix(".eapb") })
    }

    @Test("one user deleting all their backups cannot touch another user's")
    func accountDeletionScoped() async throws {
        let s = server()
        let a = s.backupStore(for: "token-A")
        let b = s.backupStore(for: "token-B")
        let ha = handle(id: "a-1", size: 2)
        let hb = handle(id: "b-1", size: 2)
        try await a.putBackup(Data("aa".utf8), handle: ha, ownerID: "user-A")
        try await b.putBackup(Data("bb".utf8), handle: hb, ownerID: "user-B")

        for h in try await a.listBackups(ownerID: "user-A") {
            try await a.deleteBackup(h, ownerID: "user-A")
        }
        #expect(try await a.listBackups(ownerID: "user-A").isEmpty)
        let bList = try await b.listBackups(ownerID: "user-B")
        #expect(bList.count == 1)
        #expect(try await b.getBackup(hb, ownerID: "user-B") == Data("bb".utf8))
    }

    // MARK: - ciphertext only

    @Test("the server never receives the plaintext archive")
    func serverSeesOnlyCiphertext() async throws {
        let marker = "TOP-SECRET-MEMORY-MARKER-\(UUID().uuidString)"
        let s = server(markers: [marker])
        let a = s.backupStore(for: "token-A")

        let enc = AESGCMBackupEncryption(keyStore: InMemorySymmetricKeyStore(seed: 7), ownerID: { "user-A" })
        let plaintext = Data("{\"memory\":\"\(marker)\"}".utf8)
        let sealed = try enc.seal(plaintext)
        try await a.putBackup(sealed, handle: handle(size: sealed.count), ownerID: "user-A")

        #expect(s.plaintextLeaked == false)
        // sanity: the detector works when handed the plaintext directly
        let creds = s.credentialProvider(identityToken: "token-A")
        let g = try await creds.presign(.put, key: "\(tagA)/leak.bin", ownerTag: tagA)
        try await s.transport().put(plaintext, to: g.url, headers: g.headers)
        #expect(s.plaintextLeaked == true)
    }

    // MARK: - end-to-end still safe through the new stack

    @Test("seal → authorized upload → download → open → validate round-trips")
    func fullRoundTripThroughAuthorizer() async throws {
        let s = server()
        let a = s.backupStore(for: "token-A")
        let enc = AESGCMBackupEncryption(keyStore: InMemorySymmetricKeyStore(seed: 3), ownerID: { "user-A" })

        let bundle = PersonalDataExporter.makeBundle(
            memory: .empty, conversations: [], messages: [],
            selection: .everything, bundleVersion: 1, ownerID: "user-A"
        )
        let sealed = try enc.seal(try PersonalDataExporter.data(for: bundle))
        let h = handle(version: 1, size: sealed.count, checksum: bundle.manifest.checksum)
        try await a.putBackup(sealed, handle: h, ownerID: "user-A")

        let fetched = try await a.getBackup(h, ownerID: "user-A")
        let opened = try enc.open(fetched)
        guard case .success(let restored) = PersonalDataImporter.validate(opened) else {
            Issue.record("validation failed"); return
        }
        #expect(restored.manifest.checksum == bundle.manifest.checksum)
    }

    @Test("a byte flipped in the object at rest is rejected on open")
    func corruptedObjectRejected() async throws {
        let s = server()
        let a = s.backupStore(for: "token-A")
        let enc = AESGCMBackupEncryption(keyStore: InMemorySymmetricKeyStore(seed: 9), ownerID: { "user-A" })
        let sealed = try enc.seal(Data("{\"manifest\":{}}".utf8))
        let h = handle(size: sealed.count)
        try await a.putBackup(sealed, handle: h, ownerID: "user-A")

        // Corrupt the stored bytes.
        var bytes = [UInt8](s.objectData(forKey: s.committedObjectKeys().first { $0.hasSuffix(".eapb") }!)!)
        bytes[bytes.count / 2] ^= 0xFF
        let creds = s.credentialProvider(identityToken: "token-A")
        let key = s.committedObjectKeys().first { $0.hasSuffix(".eapb") }!
        let g = try await creds.presign(.put, key: key, ownerTag: tagA)
        try await s.transport().put(Data(bytes), to: g.url, headers: g.headers)

        let fetched = try await a.getBackup(h, ownerID: "user-A")
        #expect(throws: (any Error).self) { _ = try enc.open(fetched) }
    }

    @Test("the inert adapter is the production posture — every op throws notConfigured")
    func inertAdapterPosture() async {
        let inert = R2ProductionBackupAdapter.inert
        await #expect(throws: (any Error).self) {
            _ = try await inert.listBackups(ownerID: "user-A")
        }
        await #expect(throws: (any Error).self) {
            try await inert.putBackup(Data("x".utf8), handle: handle(size: 1), ownerID: "user-A")
        }
    }

    @Test("an R2 outage as a composite secondary never fails the local backup")
    func outageNeverFailsLocalBackup() async throws {
        let local = LocalDirectoryBackupStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("r2prodpath-\(UUID().uuidString)", isDirectory: true))
        let composite = CompositeBackupStore(primary: local, secondaries: [R2ProductionBackupAdapter.inert])
        let h = handle(size: 4)
        try await composite.putBackup(Data("keep".utf8), handle: h, ownerID: "user-A")

        let list = try await composite.listBackups(ownerID: "user-A")
        #expect(list.contains { $0.id == h.id })
        #expect(try await composite.getBackup(h, ownerID: "user-A") == Data("keep".utf8))
    }

    // MARK: - R1: safe composition is compiler-enforced, not documented

    @Test("no code constructs R2BackupStore through its raw initializer — only the guarded factories")
    func noRawR2BackupStoreConstruction() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for dir in ["EvenAI", "EvenAITests"] {
            let base = root.appendingPathComponent(dir)
            let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
            while let u = e?.nextObject() as? URL {
                guard u.pathExtension == "swift" else { continue }
                // `R2BackupStore.swift` declares the private init; this file
                // *names* the pattern in this very assertion.
                guard u.lastPathComponent != "R2BackupStore.swift",
                      u.lastPathComponent != "R2ProductionPathSecurityTests.swift" else { continue }
                let src = (try? String(contentsOf: u, encoding: .utf8)) ?? ""
                // The raw initializer takes `credentials:` — a call of that
                // shape anywhere else would be an authorization bypass. The
                // raw `init` is `private`, so a compiling call can only be to
                // the guarded `.authorized(` / `.dormant` factories.
                let collapsed = src.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\n", with: "")
                #expect(!collapsed.contains("R2BackupStore(credentials:"),
                        "\(u.lastPathComponent) constructs R2BackupStore via its raw initializer")
            }
        }
    }

    @Test("the guarded factory always has the authorization client in the chain (expired grant is refused)")
    func guardedFactoryEnforcesAuthorization() async {
        // A provider that issues a scoped-but-expired grant. If the guard were
        // missing, putBackup would try to use it; with the guard, it fails.
        // `R2ProductionBackupAdapter.makeStore` is the ONLY way to compose a
        // remote store — `R2BackupStore.authorized` cannot be called elsewhere
        // (it needs a `RemoteBackupCompositionAuthority`, mintable only in
        // `R2ProductionBackupAdapter.swift`).
        let viaAdapter = R2ProductionBackupAdapter.makeStore(
            credentials: FakePresignProvider(grantTTL: -30), transport: InMemoryBackupObjectTransport())
        await #expect(throws: BackupCredentialError.self) {
            try await viaAdapter.putBackup(Data("x".utf8), handle: handle(size: 1), ownerID: "user-A")
        }
    }

    // MARK: - R2: production grant scope is meaningful, not a no-op

    @Test("a provider that omits scope is refused by the client (scopeMissing)")
    func unscopedGrantRefused() async {
        let client = BackupAuthorizationClient(wrapping: FakePresignProvider(omitScope: true))
        await #expect(throws: BackupCredentialError.scopeMissing) {
            _ = try await client.presign(.put, key: "\(tagA)/objects/x.eapb", ownerTag: tagA)
        }
    }

    @Test("scope survives provider → client and still matches the exact request")
    func scopeSurvivesProviderToClient() async throws {
        let client = BackupAuthorizationClient(wrapping: FakePresignProvider())
        let key = "\(tagA)/objects/3-daily-\(UUID().uuidString).eapb"
        let grant = try await client.presign(.put, key: key, ownerTag: tagA)
        #expect(grant.scope != nil)
        #expect(grant.covers(.put, key: key, ownerTag: tagA))
        #expect(!grant.covers(.delete, key: key, ownerTag: tagA))
        #expect(!grant.covers(.put, key: "\(tagA)/objects/z.eapb", ownerTag: tagA))
        #expect(!grant.covers(.put, key: key, ownerTag: tagB))
    }

    @Test("an expired scoped grant is still rejected")
    func expiredScopedGrantRejected() async {
        let client = BackupAuthorizationClient(wrapping: FakePresignProvider(grantTTL: -1))
        await #expect(throws: BackupCredentialError.expired) {
            _ = try await client.presign(.get, key: "\(tagA)/catalog.json", ownerTag: tagA)
        }
    }

    @Test("a valid exact-scope grant is accepted end to end")
    func validScopeAccepted() async throws {
        let (store, transport) = FakeR2.store()
        try await store.putBackup(Data("sealed".utf8), handle: handle(size: 6), ownerID: "user-A")
        #expect(try await store.listBackups(ownerID: "user-A").count == 1)
        #expect(transport.keys().contains { $0.hasSuffix(".eapb") })
    }

    /// A Worker `/presign` response modelling a *correct* authorizer: it grants
    /// exactly `(operation, key)` under the given server-derived `ownerTag`.
    private func stubWorkerGranting(
        ownerTag: String,
        operation: String = "put",
        key: String,
        expiresInSeconds: Int = 300
    ) {
        let json = """
        {"url":"https://signed.invalid/\(operation)","expiresInSeconds":\(expiresInSeconds),"grantID":"grant-xyz",
         "scope":{"ownerTag":"\(ownerTag)","objectKey":"\(key)","operation":"\(operation)"}}
        """
        StubURLProtocol.handler = { _ in .init(status: 200, body: Data(json.utf8)) }
    }

    private func workerProvider(authenticatedUserID: String = "user-A") -> WorkerBackupCredentialProvider {
        WorkerBackupCredentialProvider(
            endpoint: URL(string: "https://backup.invalid/presign")!,
            authenticatedUserID: authenticatedUserID,
            identityToken: { "test-identity" },
            session: StubURLProtocol.makeSession()
        )
    }

    @Test("WorkerBackupCredentialProvider carries the server's authoritative scope through to the grant")
    func workerProviderProducesScopedGrant() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        let key = "\(tagA)/objects/5-daily-\(UUID().uuidString).eapb"
        stubWorkerGranting(ownerTag: tagA, key: key)
        let provider = workerProvider()
        let grant = try await provider.presign(.put, key: key, ownerTag: tagA)
        #expect(grant.scope?.operation == .put)
        #expect(grant.scope?.objectKey == key)
        #expect(grant.scope?.ownerTag == tagA)
        #expect(grant.grantID == "grant-xyz")
        #expect(grant.covers(.put, key: key, ownerTag: tagA))
        // and the whole thing passes the client guard
        let client = BackupAuthorizationClient(wrapping: provider)
        _ = try await client.presign(.put, key: key, ownerTag: tagA)
    }

    @Test("WorkerBackupCredentialProvider refuses a response with no scope (never synthesises one)")
    func workerProviderRefusesUnscopedResponse() async {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        StubURLProtocol.handler = { _ in
            .init(status: 200, body: Data(#"{"url":"https://signed.invalid/put","expiresInSeconds":300}"#.utf8))
        }
        let provider = workerProvider()
        await #expect(throws: BackupCredentialError.scopeMissing) {
            _ = try await provider.presign(.put, key: "\(tagA)/objects/x.eapb", ownerTag: tagA)
        }
    }

    @Test("WorkerBackupCredentialProvider rejects a server-returned scope for a different owner")
    func workerProviderRejectsMismatchedServerScope() async {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        StubURLProtocol.handler = { _ in
            // Server claims a grant under a *different* owner tag.
            let json = #"{"url":"https://signed.invalid/put","expiresInSeconds":300,"scope":{"ownerTag":"OTHER","objectKey":"OTHER/x","operation":"put"}}"#
            return .init(status: 200, body: Data(json.utf8))
        }
        let provider = workerProvider()
        await #expect(throws: BackupCredentialError.scopeMismatch) {
            _ = try await provider.presign(.put, key: "\(tagA)/objects/x.eapb", ownerTag: tagA)
        }
    }

    @Test("WorkerBackupCredentialProvider will not sign for an owner it is not authenticated as")
    func workerProviderRefusesForeignOwnerRequest() async {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        stubWorkerGranting(ownerTag: tagB, key: "\(tagB)/objects/x.eapb")
        let provider = workerProvider(authenticatedUserID: "user-A")   // authenticated as A
        await #expect(throws: BackupCredentialError.scopeMismatch) {
            // caller asks to act under B's tag
            _ = try await provider.presign(.put, key: "\(tagB)/objects/x.eapb", ownerTag: tagB)
        }
    }

    @Test("these fixes introduce no R2 credential or plaintext")
    func fixesIntroduceNoSecretOrPlaintext() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for rel in ["EvenAI/Core/Domain/PersonalAI/BackupAuthorization.swift",
                    "EvenAI/Core/Domain/PersonalAI/BackupProviderProtocols.swift",
                    "EvenAI/Infrastructure/PersonalAI/Backup/BackupAuthorizationClient.swift",
                    "EvenAI/Infrastructure/PersonalAI/Backup/BackupCredentialProviders.swift",
                    "EvenAI/Infrastructure/PersonalAI/Backup/R2BackupStore.swift",
                    "EvenAI/Infrastructure/PersonalAI/Backup/R2ProductionBackupAdapter.swift"] {
            let src = (try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)) ?? ""
            for token in ["AKIA", "aws_secret_access_key", "R2_SECRET", "R2_ACCESS_KEY_ID",
                          "CLOUDFLARE_API_TOKEN", "cloudflarestorage.com", "-----BEGIN"] {
                #expect(!src.contains(token), "\(rel) contains \(token)")
            }
        }
    }
}

// MARK: - R1 / R2 adversarial suite

/// A credential provider that hands back a grant carrying a **caller-chosen**
/// scope (or none), regardless of what was requested — the stand-in for a
/// buggy or hostile authorizer. Lets these tests prove that
/// `BackupAuthorizationClient` is the real enforcement point: the grant scope
/// and the request are independent inputs, and a disagreement is caught.
private struct FixedScopeProvider: BackupCredentialProviding {
    var isConfigured = true
    var scope: BackupAuthorizationScope?
    var ttl: TimeInterval = 300
    func presign(_ operation: BackupObjectOperation, key: String, ownerTag: String) async throws -> PresignedBackupRequest {
        PresignedBackupRequest(
            url: URL(string: "https://fixed.invalid/\(key)")!,
            headers: [:],
            expiresAt: Date().addingTimeInterval(ttl),
            grantID: "fixed-grant",
            scope: scope
        )
    }
}

/// The adversarial cases the hardening work must satisfy: the normal
/// production API cannot bypass the authorization layer (R1), and the grant
/// scope is a meaningful, server-authoritative binding — not a copy of the
/// request (R2).
@Suite("R2 production path: authorization bypass & scope integrity", .serialized)
struct R2ProductionPathAuthorizationBypassTests {

    private let tagA = BackupOwnerTag.tag("user-A")
    private let tagB = BackupOwnerTag.tag("user-B")
    private let key = "\(BackupOwnerTag.tag("user-A"))/objects/9-daily-fixed.eapb"

    private func handle(size: Int = 4) -> BackupHandle {
        BackupHandle(id: UUID().uuidString, createdAt: Date(), bundleVersion: 1, sizeBytes: size, checksum: "c", tier: "daily")
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    // MARK: R1 — the normal production API cannot bypass authorization

    @Test("the remote-store composition authority can be minted ONLY inside R2ProductionBackupAdapter.swift")
    func compositionAuthorityIsConfined() {
        let root = repoRoot()
        var constructions: [String] = []
        for dir in ["EvenAI", "EvenAITests"] {
            let base = root.appendingPathComponent(dir)
            let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
            while let u = e?.nextObject() as? URL {
                guard u.pathExtension == "swift" else { continue }
                // This file names the pattern in its own assertions.
                guard u.lastPathComponent != "R2ProductionPathSecurityTests.swift" else { continue }
                let src = (try? String(contentsOf: u, encoding: .utf8)) ?? ""
                let collapsed = src.replacingOccurrences(of: " ", with: "")
                if collapsed.contains("RemoteBackupCompositionAuthority(") {
                    constructions.append(u.lastPathComponent)
                }
            }
        }
        // The type is *named* in a doc comment in R2BackupStore.swift; it is
        // *constructed* only in the adapter.
        #expect(constructions == ["R2ProductionBackupAdapter.swift"],
                "RemoteBackupCompositionAuthority() constructed in unexpected file(s): \(constructions)")
    }

    @Test("no code calls R2BackupStore.authorized directly — the adapter is the sole entry")
    func authorizedFactoryNotCalledDirectly() {
        let root = repoRoot()
        for dir in ["EvenAI", "EvenAITests"] {
            let base = root.appendingPathComponent(dir)
            let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
            while let u = e?.nextObject() as? URL {
                guard u.pathExtension == "swift" else { continue }
                // The declaration lives in R2BackupStore.swift; the *only*
                // permitted call site is R2ProductionBackupAdapter.swift.
                guard u.lastPathComponent != "R2BackupStore.swift",
                      u.lastPathComponent != "R2ProductionBackupAdapter.swift",
                      u.lastPathComponent != "R2ProductionPathSecurityTests.swift" else { continue }
                let collapsed = ((try? String(contentsOf: u, encoding: .utf8)) ?? "")
                    .replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\n", with: "")
                #expect(!collapsed.contains("R2BackupStore.authorized("),
                        "\(u.lastPathComponent) calls R2BackupStore.authorized directly")
            }
        }
    }

    @Test("a store built by the normal production API always enforces the authorization guard")
    func normalProductionAPICannotBypassGuard() async {
        // Every remote store the app can build comes from makeStore, and every
        // one of them refuses an expired grant, a mis-scoped grant, and an
        // unscoped grant — i.e. the BackupAuthorizationClient guard is always
        // in the chain, unconditionally.
        let expired = R2ProductionBackupAdapter.makeStore(
            credentials: FixedScopeProvider(scope: .init(ownerTag: tagA, objectKey: key, operation: .put), ttl: -30),
            transport: InMemoryBackupObjectTransport())
        await #expect(throws: BackupCredentialError.self) {
            try await expired.putBackup(Data("x".utf8), handle: handle(), ownerID: "user-A")
        }

        let unscoped = R2ProductionBackupAdapter.makeStore(
            credentials: FixedScopeProvider(scope: nil),
            transport: InMemoryBackupObjectTransport())
        await #expect(throws: BackupCredentialError.self) {
            try await unscoped.putBackup(Data("x".utf8), handle: handle(), ownerID: "user-A")
        }
    }

    // MARK: R2 — the grant scope is a meaningful, server-authoritative check

    @Test("exact valid scope succeeds end to end")
    func exactValidScopeSucceeds() async throws {
        let client = BackupAuthorizationClient(wrapping: FixedScopeProvider(
            scope: .init(ownerTag: tagA, objectKey: key, operation: .put)))
        let grant = try await client.presign(.put, key: key, ownerTag: tagA)
        #expect(grant.covers(.put, key: key, ownerTag: tagA))
        #expect(grant.scope?.ownerTag == tagA)
    }

    @Test("missing scope fails")
    func missingScopeFails() async {
        let client = BackupAuthorizationClient(wrapping: FixedScopeProvider(scope: nil))
        await #expect(throws: BackupCredentialError.scopeMissing) {
            _ = try await client.presign(.put, key: key, ownerTag: tagA)
        }
    }

    @Test("wrong operation fails")
    func wrongOperationFails() async {
        let client = BackupAuthorizationClient(wrapping: FixedScopeProvider(
            scope: .init(ownerTag: tagA, objectKey: key, operation: .delete)))   // granted delete
        await #expect(throws: BackupCredentialError.scopeMismatch) {
            _ = try await client.presign(.put, key: key, ownerTag: tagA)          // asked put
        }
    }

    @Test("wrong object / backup fails")
    func wrongObjectFails() async {
        let client = BackupAuthorizationClient(wrapping: FixedScopeProvider(
            scope: .init(ownerTag: tagA, objectKey: "\(tagA)/objects/SOMETHING-ELSE.eapb", operation: .put)))
        await #expect(throws: BackupCredentialError.scopeMismatch) {
            _ = try await client.presign(.put, key: key, ownerTag: tagA)
        }
    }

    @Test("wrong owner fails")
    func wrongOwnerFails() async {
        // The caller acts correctly under A's own key, but the authorizer
        // handed back a grant whose authoritative owner is B. The scope check
        // — comparing the grant's owner to the caller's — rejects it.
        let client = BackupAuthorizationClient(wrapping: FixedScopeProvider(
            scope: .init(ownerTag: tagB, objectKey: key, operation: .put)))
        await #expect(throws: BackupCredentialError.scopeMismatch) {
            _ = try await client.presign(.put, key: key, ownerTag: tagA)
        }
    }

    @Test("expired scoped grant fails")
    func expiredScopedGrantFails() async {
        let client = BackupAuthorizationClient(wrapping: FixedScopeProvider(
            scope: .init(ownerTag: tagA, objectKey: key, operation: .put), ttl: -1))
        await #expect(throws: BackupCredentialError.expired) {
            _ = try await client.presign(.put, key: key, ownerTag: tagA)
        }
    }

    // MARK: R2 — credential-provider → request → scope survives end-to-end

    @Test("the server-derived scope survives WorkerProvider → BackupAuthorizationClient unchanged")
    func scopeSurvivesEndToEnd() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        let k = "\(tagA)/objects/e2e-\(UUID().uuidString).eapb"
        // The Worker derives A's tag from the verified identity and returns it
        // as the authoritative scope.
        let json = """
        {"url":"https://signed.invalid/put","expiresInSeconds":300,"grantID":"g-e2e",
         "scope":{"ownerTag":"\(tagA)","objectKey":"\(k)","operation":"put"}}
        """
        StubURLProtocol.handler = { _ in .init(status: 200, body: Data(json.utf8)) }

        let provider = WorkerBackupCredentialProvider(
            endpoint: URL(string: "https://backup.invalid/presign")!,
            authenticatedUserID: "user-A",
            identityToken: { "identity-A" },
            session: StubURLProtocol.makeSession())
        let client = BackupAuthorizationClient(wrapping: provider)

        let grant = try await client.presign(.put, key: k, ownerTag: tagA)
        #expect(grant.scope?.ownerTag == tagA)         // server-derived, not caller-synthesised
        #expect(grant.scope?.objectKey == k)
        #expect(grant.scope?.operation == .put)
        #expect(grant.grantID == "g-e2e")
        #expect(grant.covers(.put, key: k, ownerTag: tagA))
    }

    @Test("an expired grant from the Worker is rejected by the client")
    func workerExpiredGrantRejected() async {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        let k = "\(tagA)/objects/exp-\(UUID().uuidString).eapb"
        let json = """
        {"url":"https://signed.invalid/put","expiresInSeconds":-5,
         "scope":{"ownerTag":"\(tagA)","objectKey":"\(k)","operation":"put"}}
        """
        StubURLProtocol.handler = { _ in .init(status: 200, body: Data(json.utf8)) }
        let provider = WorkerBackupCredentialProvider(
            endpoint: URL(string: "https://backup.invalid/presign")!,
            authenticatedUserID: "user-A",
            identityToken: { "identity-A" },
            session: StubURLProtocol.makeSession())
        let client = BackupAuthorizationClient(wrapping: provider)
        await #expect(throws: BackupCredentialError.expired) {
            _ = try await client.presign(.put, key: k, ownerTag: tagA)
        }
    }

    // MARK: no secret / no plaintext introduced

    @Test("the R1/R2 changes introduce no R2 credential, endpoint, or private key")
    func changesIntroduceNoSecret() {
        let root = repoRoot()
        for rel in ["EvenAI/Core/Domain/PersonalAI/BackupProviderProtocols.swift",
                    "EvenAI/Core/Domain/PersonalAI/BackupAuthorization.swift",
                    "EvenAI/Infrastructure/PersonalAI/Backup/BackupAuthorizationClient.swift",
                    "EvenAI/Infrastructure/PersonalAI/Backup/BackupCredentialProviders.swift",
                    "EvenAI/Infrastructure/PersonalAI/Backup/R2BackupStore.swift",
                    "EvenAI/Infrastructure/PersonalAI/Backup/R2ProductionBackupAdapter.swift"] {
            let src = (try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)) ?? ""
            for token in ["AKIA", "aws_secret_access_key", "R2_SECRET", "R2_ACCESS_KEY_ID",
                          "CLOUDFLARE_API_TOKEN", "cloudflarestorage.com", "-----BEGIN"] {
                #expect(!src.contains(token), "\(rel) contains \(token)")
            }
        }
        // The credential-provider surface still never takes a decryption key.
        for rel in ["EvenAI/Infrastructure/PersonalAI/Backup/BackupAuthorizationClient.swift",
                    "EvenAI/Infrastructure/PersonalAI/Backup/BackupCredentialProviders.swift",
                    "EvenAI/Infrastructure/PersonalAI/Backup/R2BackupStore.swift",
                    "EvenAI/Infrastructure/PersonalAI/Backup/R2ProductionBackupAdapter.swift"] {
            let src = (try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)) ?? ""
            #expect(!src.contains("SymmetricKey"), "\(rel) references a SymmetricKey")
        }
    }
}
