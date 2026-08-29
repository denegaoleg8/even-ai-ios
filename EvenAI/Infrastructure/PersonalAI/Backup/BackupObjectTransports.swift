import Foundation

/// Production default. **No backup object store is configured** — every
/// operation throws `.notConfigured`. Wired wherever a `BackupObjectTransport`
/// is required until a real Worker + R2 bucket exist.
struct DormantBackupObjectTransport: BackupObjectTransport {
    func put(_ data: Data, to url: URL, headers: [String: String]) async throws {
        throw BackupTransportError.notConfigured
    }
    func get(_ url: URL) async throws -> Data { throw BackupTransportError.notConfigured }
    func delete(_ url: URL) async throws { throw BackupTransportError.notConfigured }
    func head(_ url: URL) async throws -> BackupObjectRef? { throw BackupTransportError.notConfigured }
}

/// Real HTTPS transport over **pre-signed URLs**. Holds no credentials of its
/// own — every URL it receives is already authorised (and expiring). This is
/// what will talk to Cloudflare R2 once a `WorkerBackupCredentialProvider` is
/// wired; it is **compiled but instantiated nowhere** in a shipping build
/// today.
struct URLSessionBackupObjectTransport: BackupObjectTransport {

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func put(_ data: Data, to url: URL, headers: [String: String]) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (_, response) = try await upload(data, for: request)
        try Self.check(response, allow: [200, 201, 204])
    }

    func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await data(for: request)
        try Self.check(response, allow: [200])
        return data
    }

    func delete(_ url: URL) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        let (_, response) = try await data(for: request)
        try Self.check(response, allow: [200, 202, 204, 404])
    }

    func head(_ url: URL) async throws -> BackupObjectRef? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let (_, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BackupTransportError.network }
        if http.statusCode == 404 { return nil }
        try Self.check(response, allow: [200])
        let size = Int(http.value(forHTTPHeaderField: "Content-Length") ?? "") ?? 0
        return BackupObjectRef(
            key: url.lastPathComponent,
            size: size,
            etag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: nil
        )
    }

    // MARK: helpers

    private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await session.data(for: request) }
        catch { throw BackupTransportError.network }
    }

    private func upload(_ body: Data, for request: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await session.upload(for: request, from: body) }
        catch { throw BackupTransportError.network }
    }

    private static func check(_ response: URLResponse, allow: Set<Int>) throws {
        guard let http = response as? HTTPURLResponse else { throw BackupTransportError.network }
        guard allow.contains(http.statusCode) else {
            if http.statusCode == 404 { throw BackupTransportError.notFound }
            throw BackupTransportError.http(status: http.statusCode)
        }
    }
}
