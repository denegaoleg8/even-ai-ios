import Foundation

/// Real backend-backed implementation of `AuthServicing`. Holds no
/// mutable state of its own — every session mutation (installing a new
/// access/refresh token pair, clearing one) is delegated to the shared
/// `AuthenticatedAPIClient`, which is what makes it safe for this to be
/// a plain `Sendable` struct rather than an actor.
struct NetworkAuthService: AuthServicing {
    private let apiClient: AuthenticatedAPIClient
    private let deviceIdentityStore: DeviceIdentityStoring
    private let platform = "ios"

    init(
        apiClient: AuthenticatedAPIClient,
        deviceIdentityStore: DeviceIdentityStoring = KeychainDeviceIdentityStore()
    ) {
        self.apiClient = apiClient
        self.deviceIdentityStore = deviceIdentityStore
    }

    func restoreSession() async throws -> User {
        do {
            return try await apiClient.recoverSession()
        } catch {
            throw Self.mapError(error)
        }
    }

    func signUp(email: String, password: String, displayName: String?) async throws -> User {
        var payload: [String: String] = ["email": email, "password": password]
        if let displayName { payload["displayName"] = displayName }

        do {
            let body = try JSONEncoder.evenAI.encode(payload)
            let data = try await apiClient.post("auth/signup", body: body)
            return try JSONDecoder.evenAI.decode(SignupResponseDTO.self, from: data).account.toDomain()
        } catch {
            throw Self.mapError(error)
        }
    }

    func signIn(email: String, password: String) async throws -> AuthResult {
        let deviceID = deviceIdentityStore.currentDeviceID()
        let payload: [String: String] = [
            "email": email,
            "password": password,
            "deviceId": deviceID.uuidString,
            "platform": platform,
            "appVersion": Self.appVersion,
        ]

        do {
            let body = try JSONEncoder.evenAI.encode(payload)
            // recoverOn401: false — a 401 here always means wrong
            // credentials (login doesn't depend on any existing
            // session), never "no session established yet," so
            // attempting recovery would just waste a round trip before
            // surfacing the same invalid-credentials error.
            let data = try await apiClient.post("auth/login", body: body, recoverOn401: false)
            let decoded = try JSONDecoder.evenAI.decode(LoginResponseDTO.self, from: data)
            await apiClient.installSession(accessToken: decoded.accessToken, refreshToken: decoded.refreshToken)
            return AuthResult(user: decoded.account.toDomain(), mergeAvailableFrom: decoded.mergeAvailableFrom)
        } catch {
            throw Self.mapError(error)
        }
    }

    // Deliberately never throws, regardless of the protocol's `throws`
    // signature: signing out must always succeed locally — clearing the
    // session is what "the app must never break because authentication
    // fails" means here. The server-side revoke is best-effort; if it
    // fails (offline, server down), the local session still clears.
    func signOut() async throws {
        if let refreshToken = await apiClient.currentRefreshToken() {
            let body = try? JSONEncoder.evenAI.encode(["refreshToken": refreshToken])
            _ = try? await apiClient.post("auth/logout", body: body)
        }
        await apiClient.clearSession()
    }

    func signOutEverywhere() async throws {
        _ = try? await apiClient.post("auth/logout-all", body: nil)
        await apiClient.clearSession()
    }

    func mergeAccount(fromAccountID: User.ID) async throws -> Int {
        do {
            let body = try JSONEncoder.evenAI.encode(["fromAccountId": fromAccountID.uuidString])
            let data = try await apiClient.post("auth/merge", body: body)
            return try JSONDecoder.evenAI.decode(MergeResponseDTO.self, from: data).mergedChatCount
        } catch {
            throw Self.mapError(error)
        }
    }

    // MARK: - Private

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    private static func mapError(_ error: Error) -> AuthError {
        guard let clientError = error as? AuthenticatedAPIClientError else { return .unknown }
        switch clientError {
        case .offline:
            return .offline
        case .sessionExpired, .notAuthenticated:
            return .sessionExpired
        case .invalidResponse, .underlying:
            return .serverUnavailable
        case .http(let status, let code):
            switch code {
            case "INVALID_CREDENTIALS": return .invalidCredentials
            case "EMAIL_ALREADY_EXISTS": return .emailAlreadyExists
            case "ACCOUNT_ALREADY_CLAIMED": return .accountAlreadyClaimed
            case "ACCOUNT_NOT_FOUND": return .accountNotFound
            case "CANNOT_MERGE_CLAIMED_ACCOUNT": return .cannotMergeClaimedAccount
            case "UNAUTHORIZED": return .sessionExpired
            default: return status >= 500 ? .serverUnavailable : .unknown
            }
        }
    }
}
