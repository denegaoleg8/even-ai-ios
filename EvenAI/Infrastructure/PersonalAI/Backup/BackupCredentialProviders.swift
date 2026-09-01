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
/// ## The grant scope is server-authoritative
///
/// This provider is constructed bound to the Personal AI user id it is
/// **authenticated as** (`authenticatedOwnerTag`), wired by the DI container
/// from the *same* signed-in session as `identityToken`. On every `presign`:
///
/// 1. The caller-supplied `ownerTag` argument is treated as *intent only* — it
///    is honoured solely when it equals `authenticatedOwnerTag`. The client
///    never signs for an owner on the caller's say-so.
/// 2. The Worker **must** return the `scope` it authoritatively granted
///    (derived server-side from the verified identity, never from our request
///    body). A response with no scope is refused (`scopeMissing`) — the client
///    does not manufacture authority the server did not confer.
/// 3. That server scope's `ownerTag` must be the identity we are authenticated
///    as, or the grant is refused (`scopeMismatch`).
/// 4. The returned `PresignedBackupRequest.scope` is the **server's** scope
///    verbatim — so the downstream `BackupAuthorizationClient.covers(...)`
///    check compares the authoritative grant against caller intent (operation
///    + key), instead of comparing the request to a copy of itself.
///
/// Compiled, **not instantiated by any shipping build** — there is no Worker
/// URL and no identity-token provider configured. Wiring it is a later,
/// separately-approved step (see PHASE2_R2_INDEPENDENT_BACKUP.md →
/// "REQUIRED MANUAL CLOUDFLARE SETUP FOR LATER").
struct WorkerBackupCredentialProvider: BackupCredentialProviding {

    /// The Worker's presign endpoint, e.g. `https://backup.evenai.workers.dev/presign`.
    let endpoint: URL
    /// The salted owner tag of the Personal AI user this provider is
    /// **authenticated as** — derived from `authenticatedUserID` at
    /// construction, never from a per-call argument. Every grant this provider
    /// hands back is bound to this tag.
    let authenticatedOwnerTag: String
    /// Returns a fresh identity token (short-lived) to prove who is asking.
    /// Must resolve to the same authenticated session as `authenticatedUserID`.
    let identityToken: @Sendable () async throws -> String
    let session: URLSession

    init(
        endpoint: URL,
        authenticatedUserID: String,
        identityToken: @escaping @Sendable () async throws -> String,
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.authenticatedOwnerTag = BackupOwnerTag.tag(authenticatedUserID)
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
        // 1. The caller-supplied `ownerTag` is *intent*, not authority. Honour
        //    it only when it is the identity we are authenticated as — never
        //    ask the Worker to sign for another owner because a caller said so.
        guard ownerTag == authenticatedOwnerTag else {
            throw BackupCredentialError.scopeMismatch
        }
        // 2. Defence in depth: never ask for a malformed key or one outside our
        //    own namespace.
        guard BackupAuthorizationScope.keyIsInOwnerNamespace(key, ownerTag: authenticatedOwnerTag) else {
            throw BackupCredentialError.keyOutsideOwnerScope
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let token = try await identityToken()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(
            PresignRequestBody(operation: operation.rawValue, key: key, ownerTag: authenticatedOwnerTag)
        )

        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw BackupCredentialError.network }

        guard let http = response as? HTTPURLResponse else { throw BackupCredentialError.network }
        switch http.statusCode {
        case 200: break
        case 401, 403: throw BackupCredentialError.unauthorized
        case 409: throw BackupCredentialError.replayed
        default: throw BackupCredentialError.network
        }

        guard let body = try? JSONDecoder().decode(PresignResponseBody.self, from: data) else {
            throw BackupCredentialError.network
        }

        // 3. The Worker MUST return the scope it authoritatively granted,
        //    derived server-side from the verified identity. No scope → the
        //    grant is unbound → refuse it (never synthesise one from our own
        //    request — that would make the downstream `covers` check a no-op).
        guard let serverScope = body.scope,
              let serverOperation = BackupObjectOperation(rawValue: serverScope.operation) else {
            throw BackupCredentialError.scopeMissing
        }

        // 4. The server-derived owner tag is the authority. It must be the
        //    identity we are authenticated as — a Worker that derived a
        //    different tag means our identity token and our owner identity
        //    disagree, and we must not use the grant.
        guard serverScope.ownerTag == authenticatedOwnerTag else {
            throw BackupCredentialError.scopeMismatch
        }

        // 5. Carry the SERVER's scope through verbatim (operation + key as the
        //    Worker granted them). `BackupAuthorizationClient.covers(operation,
        //    key, ownerTag)` then compares this authoritative grant against
        //    caller intent — a real check, because the two sides now come from
        //    independent sources (the HTTP response vs. the call arguments).
        let scope = BackupAuthorizationScope(
            ownerTag: serverScope.ownerTag,
            objectKey: serverScope.objectKey,
            operation: serverOperation
        )

        return PresignedBackupRequest(
            url: body.url,
            headers: body.headers ?? [:],
            expiresAt: Date().addingTimeInterval(body.expiresInSeconds),
            grantID: body.grantID ?? UUID().uuidString,
            scope: scope
        )
    }
}
