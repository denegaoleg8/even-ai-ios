import Foundation
@testable import EvenAI

/// Records every request and authorization value it receives (for
/// asserting request-mapping / privacy properties) and returns a scripted
/// response or throws a scripted error — optionally after a delay, to
/// exercise `RemotePersonalAIModelProvider`'s timeout.
actor FakePersonalAIRemoteTransport: PersonalAIRemoteTransport {
    private(set) var requests: [PersonalAIRemoteRequest] = []
    private(set) var authorizationsSeen: [String] = []
    private let reply: String
    private let error: Error?
    private let delay: Duration?

    init(reply: String = "remote reply", error: Error? = nil, delay: Duration? = nil) {
        self.reply = reply
        self.error = error
        self.delay = delay
    }

    func generate(_ request: PersonalAIRemoteRequest, authorization: String) async throws -> PersonalAIRemoteResponse {
        requests.append(request)
        authorizationsSeen.append(authorization)
        if let delay { try await Task.sleep(for: delay) }
        if let error { throw error }
        return PersonalAIRemoteResponse(text: reply)
    }

    var lastRequest: PersonalAIRemoteRequest? { requests.last }
}

/// A scripted credential source for tests — a fake token string only,
/// never a real secret. `token: nil` simulates "no credential configured".
struct FakePersonalAIRemoteAuth: PersonalAIRemoteAuthorizing {
    let token: String?
    init(token: String? = "fake-test-token-do-not-use") { self.token = token }
    func currentToken() async -> String? { token }
}
