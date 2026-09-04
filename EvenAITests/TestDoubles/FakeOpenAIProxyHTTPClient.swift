import Foundation
@testable import EvenAI

/// Records every request it receives and returns a scripted (status, body)
/// pair — or throws — computed from the request itself, so a test can
/// prove genuine request→response flow-through rather than a hardcoded
/// fixture. Never touches the real network.
actor FakeOpenAIProxyHTTPClient: OpenAIProxyHTTPClient {
    private(set) var requests: [URLRequest] = []
    private let error: Error?
    private let handler: @Sendable (URLRequest) throws -> (Int, Data)

    /// Fixed-response convenience init.
    init(status: Int = 200, body: Data = Data(), error: Error? = nil) {
        self.error = error
        self.handler = { _ in (status, body) }
    }

    /// Request-driven convenience init — for tests that need to prove the
    /// response genuinely depends on what was sent.
    init(error: Error? = nil, handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)) {
        self.error = error
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if let error { throw error }
        let (status, body) = try handler(request)
        let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (body, http)
    }

    var lastRequest: URLRequest? { requests.last }
}
