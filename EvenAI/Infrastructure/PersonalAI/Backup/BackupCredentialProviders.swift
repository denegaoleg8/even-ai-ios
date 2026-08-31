import Foundation

/// **Production default.** No backup credential service (Worker) is deployed,
/// so no operation can be authorised. `isConfigured == false`; every
/// `presign` throws. This is what `PersonalAIContainer.live` uses today.
struct NotConfiguredBackupCredentialProvider: BackupCredentialProviding {
    var isConfigured: Bool { false }
    func presign(_ operation: BackupObjectOperation, key: String, ownerTag: String) async throws -> PresignedBackupRequest {
        throw BackupCredentialError.notConfigured
    }
}

/// Fetches a short-lived, single-operation, `ownerTag`-scoped pre-signed URL
/// from an **authenticated Cloudflare Worker**. The app sends its identity
/// token (Sign in with Apple / EvenAI account); the Worker verifies it, then
/// signs an R2 URL limited to `PUT|GET|DELETE|HEAD|LIST` on one key under
/// `<ownerTag>/…`. **The R2 access key never leaves the Worker; the app never
/// holds it.**
///
/// Compiled, **not instantiated by any shipping build** — there is no Worker
/// URL and no identity-token provider configured. Wiring it is a later,
/// separately-approved step (see PHASE2_R2_INDEPENDENT_BACKUP.md →
/// "REQUIRED MANUAL CLOUDFLARE SETUP FOR LATER").
struct WorkerBackupCredentialProvider: BackupCredentialProviding {

    /// The Worker's presign endpoint, e.g. `https://backup.evenai.workers.dev/presign`.
    let endpoint: URL
    /// Returns a fresh identity token (short-lived) to prove who is asking.
    let identityToken: @Sendable () async throws -> String
    let session: URLSession

    init(
        endpoint: URL,
        identityToken: @escaping @Sendable () async throws -> String,
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.identityToken = identityToken
        self.session = session
    }

    var isConfigured: Bool { true }

    private struct PresignRequestBody: Encodable {
        var operation: String
        var key: String
        var ownerTag: String
    }
    private struct PresignResponseBody: Decodable {
        var url: URL
        var headers: [String: String]?
        var expiresInSeconds: Double
        /// Optional — a future Worker returns the scope it *authoritatively*
        /// granted (with the server-derived owner tag). When present it must
        /// still match what we asked for; when absent the client synthesises
        /// the scope from the request as defence-in-depth.
        var grantID: String?
        var scope: GrantScope?
        struct GrantScope: Decodable {
            var ownerTag: String
            var objectKey: String
            var operation: String
        }
    }

    func presign(_ operation: BackupObjectOperation, key: String, ownerTag: String) async throws -> PresignedBackupRequest {
        // Defence in depth: never ask for a URL outside our own prefix, and
        // never for a malformed key.
        guard BackupAuthorizationScope.keyIsInOwnerNamespace(key, ownerTag: ownerTag) else {
            throw BackupCredentialError.keyOutsideOwnerScope
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let token = try await identityToken()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(
            PresignRequestBody(operation: operation.rawValue, key: key, ownerTag: ownerTag)
        )

        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw BackupCredentialError.network }

        guard let http = response as? HTTPURLResponse else { throw BackupCredentialError.network }
        switch http.statusCode {
        case 200: break
        case 401, 403: throw BackupCredentialError.unauthorized
        default: throw BackupCredentialError.network
        }

        guard let body = try? JSONDecoder().decode(PresignResponseBody.self, from: data) else {
            throw BackupCredentialError.network
        }

        // Bind the grant to a scope. If the Worker returned one, it is
        // authoritative — but it must still be exactly what we asked for
        // (same operation, same key, same owner tag), or we refuse it.
        if let s = body.scope {
            guard s.operation == operation.rawValue, s.objectKey == key, s.ownerTag == ownerTag else {
                throw BackupCredentialError.keyOutsideOwnerScope
            }
        }
        let scope = BackupAuthorizationScope(ownerTag: ownerTag, objectKey: key, operation: operation)

        return PresignedBackupRequest(
            url: body.url,
            headers: body.headers ?? [:],
            expiresAt: Date().addingTimeInterval(body.expiresInSeconds),
            grantID: body.grantID ?? UUID().uuidString,
            scope: scope
        )
    }
}
