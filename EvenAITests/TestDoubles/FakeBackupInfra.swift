import Foundation
@testable import EvenAI

/// In-memory `BackupObjectTransport` — a `[urlString: Data]` map with
/// injectable failures. No network, no files.
final class InMemoryBackupObjectTransport: BackupObjectTransport, @unchecked Sendable {

    private let lock = NSLock()
    private var objects: [String: Data] = [:]

    // Injection
    var failNextPut: Error?
    var failNextGet: Error?
    var alwaysFail: Error?
    /// Drop the last N bytes of the next `get` result (simulate truncation).
    var truncateNextGetBy = 0
    /// Flip one byte in the next `get` result (simulate bit-rot / tampering).
    var corruptNextGet = false
    /// Flip a byte in every `get` whose key ends `.eapb` (the backup object,
    /// not the catalog) — models an object corrupted at rest / in transit.
    var corruptObjectReads = false
    private(set) var putCount = 0
    private(set) var getCount = 0

    func put(_ data: Data, to url: URL, headers: [String: String]) async throws {
        try throwIfConfigured()
        try lock.withLock {
            putCount += 1
            if let e = failNextPut { failNextPut = nil; throw e }
            objects[url.absoluteString] = data
        }
    }

    func get(_ url: URL) async throws -> Data {
        try throwIfConfigured()
        return try lock.withLock {
            getCount += 1
            if let e = failNextGet { failNextGet = nil; throw e }
            guard var data = objects[url.absoluteString] else { throw BackupTransportError.notFound }
            if truncateNextGetBy > 0 {
                data = data.dropLast(truncateNextGetBy)
                truncateNextGetBy = 0
            }
            let corrupt = corruptNextGet || (corruptObjectReads && url.absoluteString.hasSuffix(".eapb"))
            if corrupt, !data.isEmpty {
                corruptNextGet = false
                var bytes = [UInt8](data)
                bytes[bytes.count / 2] ^= 0xFF
                data = Data(bytes)
            }
            return data
        }
    }

    func delete(_ url: URL) async throws {
        try throwIfConfigured()
        lock.withLock { _ = objects.removeValue(forKey: url.absoluteString) }
    }

    func head(_ url: URL) async throws -> BackupObjectRef? {
        try throwIfConfigured()
        return lock.withLock {
            guard let d = objects[url.absoluteString] else { return nil }
            return BackupObjectRef(key: url.lastPathComponent, size: d.count, etag: nil, lastModified: nil)
        }
    }

    // Introspection
    func rawObjectCount() -> Int { lock.withLock { objects.count } }
    func keys() -> [String] { lock.withLock { Array(objects.keys) } }
    func rawData(forKeySuffix suffix: String) -> Data? {
        lock.withLock { objects.first { $0.key.hasSuffix(suffix) }?.value }
    }

    private func throwIfConfigured() throws {
        if let e = (lock.withLock { alwaysFail }) { throw e }
    }
}

/// `BackupCredentialProviding` that hands out deterministic `https://fake/`
/// URLs the in-memory transport keys off — models the Worker→presigned-URL
/// flow without any network. Enforces the same `ownerTag` key-scoping the
/// real Worker would.
struct FakePresignProvider: BackupCredentialProviding {
    var isConfigured: Bool = true
    var rejectAllAsUnauthorized = false
    /// When set, the issued grant's `expiresAt` is `now + this` (negative =
    /// already expired).
    var grantTTL: TimeInterval = 300
    /// When true, the issued grant carries **no** `scope` (models a
    /// misbehaving provider — `BackupAuthorizationClient` must refuse it).
    var omitScope = false

    func presign(_ operation: BackupObjectOperation, key: String, ownerTag: String) async throws -> PresignedBackupRequest {
        if !isConfigured { throw BackupCredentialError.notConfigured }
        if rejectAllAsUnauthorized { throw BackupCredentialError.unauthorized }
        guard BackupAuthorizationScope.keyIsInOwnerNamespace(key, ownerTag: ownerTag) else {
            throw BackupCredentialError.keyOutsideOwnerScope
        }
        // The URL is stable per (key) so PUT then GET address the same object.
        return PresignedBackupRequest(
            url: URL(string: "https://fake.invalid/\(key)")!,
            headers: ["x-op": operation.rawValue],
            expiresAt: Date().addingTimeInterval(grantTTL),
            grantID: "fake-grant-\(UUID().uuidString)",
            scope: omitScope ? nil : BackupAuthorizationScope(ownerTag: ownerTag, objectKey: key, operation: operation)
        )
    }
}

extension NSLock {
    @discardableResult
    fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}

/// A `BackupStore` with **no owner scoping** — every `ownerID` sees every
/// object. Used to exercise the coordinator's defence-in-depth owner check
/// (a real store like `R2BackupStore` scopes by `ownerTag` and would never
/// hand one user another's object).
actor FlatInMemoryBackupStore: BackupStore {
    private var objects: [String: Data] = [:]
    private var handles: [String: BackupHandle] = [:]

    func putBackup(_ sealed: Data, handle: BackupHandle, ownerID: String) async throws {
        objects[handle.id] = sealed
        handles[handle.id] = handle
    }
    func listBackups(ownerID: String) async throws -> [BackupHandle] {
        handles.values.sorted { $0.createdAt > $1.createdAt }
    }
    func getBackup(_ handle: BackupHandle, ownerID: String) async throws -> Data {
        guard let d = objects[handle.id] else { throw BackupTransportError.notFound }
        return d
    }
    func deleteBackup(_ handle: BackupHandle, ownerID: String) async throws {
        objects[handle.id] = nil
        handles[handle.id] = nil
    }
}

/// Build an `R2BackupStore` over the in-memory fakes.
enum FakeR2 {
    static func store(
        transport: InMemoryBackupObjectTransport = InMemoryBackupObjectTransport(),
        configured: Bool = true
    ) -> (store: R2BackupStore, transport: InMemoryBackupObjectTransport) {
        let store = R2BackupStore.authorized(
            credentials: FakePresignProvider(isConfigured: configured),
            transport: transport
        )
        return (store, transport)
    }
}

/// A minimal reader for STORE-method zips produced by `StoredZipArchive`
/// (test-only — verifies the archive without a system unzip).
enum TestStoredZipReader {
    /// Returns `[path: data]` for every entry, via the central directory.
    static func entries(_ zip: Data) -> [String: Data] {
        var result: [String: Data] = [:]
        let bytes = [UInt8](zip)
        // Find EOCD (0x06054b50) from the end.
        guard let eocd = lastIndex(of: [0x50, 0x4b, 0x05, 0x06], in: bytes) else { return result }
        let centralOffset = Int(u32(bytes, eocd + 16))
        var p = centralOffset
        while p + 4 <= bytes.count, u32(bytes, p) == 0x02014b50 {
            let nameLen = Int(u16(bytes, p + 28))
            let extraLen = Int(u16(bytes, p + 30))
            let commentLen = Int(u16(bytes, p + 32))
            let localOffset = Int(u32(bytes, p + 42))
            let name = String(decoding: bytes[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            // Local header
            let lNameLen = Int(u16(bytes, localOffset + 26))
            let lExtraLen = Int(u16(bytes, localOffset + 28))
            let size = Int(u32(bytes, localOffset + 22))
            let dataStart = localOffset + 30 + lNameLen + lExtraLen
            result[name] = Data(bytes[dataStart..<(dataStart + size)])
            p += 46 + nameLen + extraLen + commentLen
        }
        return result
    }

    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | (UInt16(b[i + 1]) << 8) }
    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
    }
    private static func lastIndex(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard haystack.count >= needle.count else { return nil }
        for i in stride(from: haystack.count - needle.count, through: 0, by: -1) {
            if Array(haystack[i..<i + needle.count]) == needle { return i }
        }
        return nil
    }
}
