import Foundation

/// The remote-capable tier of the Personal AI provider router. Talks to
/// `transport` (a `PersonalAIRemoteTransport`) using a credential from
/// `auth` (`PersonalAIRemoteAuthorizing`) — never a vendor SDK, never a
/// hardcoded secret. No conformer of either protocol in this codebase is
/// "live" yet: wiring a real vendor is a separate, later, explicitly
/// approved change to `PersonalAIContainer.live` only.
///
/// Like `OnDevicePersonalAIModelProvider`, this type does not fall back to
/// anything itself — it either answers or throws, and the router
/// (`FallbackPersonalAIModelProvider`) decides what happens next.
struct RemotePersonalAIModelProvider: PersonalAIModelProviding {
    /// Neutral label for *which* remote vendor this is — a plain string
    /// (e.g. a future "openai"), never a Domain-level per-vendor type.
    /// Used only for diagnostics.
    let providerID: String
    let auth: any PersonalAIRemoteAuthorizing
    let transport: any PersonalAIRemoteTransport
    /// How long a single remote call is allowed before it's treated as a
    /// transient failure and the router moves on to the next tier.
    let timeout: Duration

    init(
        providerID: String,
        auth: any PersonalAIRemoteAuthorizing,
        transport: any PersonalAIRemoteTransport,
        timeout: Duration = .seconds(20)
    ) {
        self.providerID = providerID
        self.auth = auth
        self.transport = transport
        self.timeout = timeout
    }

    func generate(_ request: PersonalAIGenerationRequest) async throws -> PersonalAIGenerationResult {
        guard let token = await auth.currentToken() else {
            Self.log(providerID: providerID, outcome: "failed category=unavailable")
            throw PersonalAIProviderOutcome.unavailable(reason: "no remote credential configured")
        }

        let remoteRequest = Self.remoteRequest(from: request)

        do {
            let response = try await Self.withTimeout(timeout) {
                try await transport.generate(remoteRequest, authorization: token)
            }
            Self.log(providerID: providerID, outcome: "success")
            return PersonalAIGenerationResult(
                text: response.text,
                provider: .cloud,
                usedPersonalization: request.personalContext.hasPersonalization
            )
        } catch is CancellationError {
            Self.log(providerID: providerID, outcome: "cancelled")
            throw CancellationError()
        } catch let outcome as PersonalAIProviderOutcome {
            Self.log(providerID: providerID, outcome: "failed category=\(Self.category(outcome))")
            throw outcome
        } catch {
            Self.log(providerID: providerID, outcome: "failed category=transientFailure underlyingErrorType=\(type(of: error))")
            throw PersonalAIProviderOutcome.transientFailure(reason: "remote transport failed")
        }
    }

    /// Maps the Domain generation request down to the narrow, provider-
    /// neutral wire shape — the one place that decides what a remote tier
    /// is allowed to see. `contextText` is exactly
    /// `personalContext.systemPromptText` (already-rendered, already-
    /// budgeted by `PersonalAIContextBuilder`) — never
    /// `personalContext.relevantMemories`/`relevantProjects`/
    /// `relevantPeople`/`historicalExcerpts` (the raw, structured records),
    /// which this function never reads. Recent conversation is bounded to
    /// the same last-8-turns window `FoundationModelsPersonalAIProvider`
    /// already uses, so the remote tier never receives more history than
    /// the on-device tier does.
    static func remoteRequest(from request: PersonalAIGenerationRequest) -> PersonalAIRemoteRequest {
        let recent = request.messages.suffix(8).map {
            PersonalAIRemoteMessage(role: $0.role == .user ? .user : .assistant, text: $0.text)
        }
        return PersonalAIRemoteRequest(
            contextText: request.personalContext.systemPromptText,
            recentMessages: Array(recent),
            userMessage: request.userMessage,
            maxOutputTokens: request.maxOutputTokens
        )
    }

    private static func category(_ outcome: PersonalAIProviderOutcome) -> String {
        switch outcome {
        case .unavailable: return "unavailable"
        case .transientFailure: return "transientFailure"
        case .hardFailure: return "hardFailure"
        case .unsupported: return "unsupported"
        }
    }

    /// Content-free: `providerID` is a neutral label chosen by whoever
    /// composed this provider, never request/response content, and never
    /// the authorization token.
    private static func log(providerID: String, outcome: String) {
        DiagnosticTrace.log("PERSONAL_AI_REMOTE_PROVIDER", "providerID=\(providerID) \(outcome)")
    }

    /// Races the real call against a timeout, cancelling whichever loses.
    /// A timeout is reported as `.transientFailure` — nothing proves a
    /// slow vendor won't answer quickly next time.
    private static func withTimeout<T: Sendable>(
        _ duration: Duration,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw PersonalAIProviderOutcome.transientFailure(reason: "remote call timed out")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}
