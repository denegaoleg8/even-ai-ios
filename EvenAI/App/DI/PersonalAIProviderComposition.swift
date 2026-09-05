import Foundation

/// Builds the Personal AI provider router's tiers — the ONE place that
/// decides whether a remote tier exists between Apple Foundation Models
/// and heuristic. Pure and independent of where "is the dev remote tier
/// enabled" and "what credential/transport to use" actually come from:
/// `PersonalAIContainer.make` supplies the real (environment/launch-
/// argument-derived, DEBUG-only) answers via `PersonalAIRemoteDevFlag`;
/// tests supply fakes. This keeps `PersonalAIContainer.make`'s own diff
/// for this feature to a single call-site swap.
///
/// Safe by construction, not by an extra check: `remoteAuth`/`remoteTransport`
/// being `nil` (nothing to construct a remote tier from at all) and
/// `remoteAuth.currentToken()` returning `nil` at call time (a real
/// `RemotePersonalAIModelProvider`/`OpenAIResponsesTransport`, but no
/// credential configured) are both already-safe, already-tested outcomes
/// — the former never adds the tier; the latter makes the tier throw
/// `.unavailable` before ever calling the transport. This function
/// doesn't duplicate either check, it only wires them.
enum PersonalAIProviderComposition {
    static func tiers(
        appleProvider: any PersonalAIModelProviding,
        remoteEnabled: Bool,
        remoteProviderID: String = "openai",
        remoteAuth: (any PersonalAIRemoteAuthorizing)? = nil,
        remoteTransport: (any PersonalAIRemoteTransport)? = nil,
        heuristicProvider: any PersonalAIModelProviding
    ) -> [FallbackPersonalAIModelProvider.Tier] {
        var tiers: [FallbackPersonalAIModelProvider.Tier] = [
            .init(.onDeviceFoundationModel, appleProvider)
        ]
        if remoteEnabled, let remoteAuth, let remoteTransport {
            tiers.append(.init(.remoteCapableProvider, RemotePersonalAIModelProvider(
                providerID: remoteProviderID,
                auth: remoteAuth,
                transport: remoteTransport
            )))
        }
        tiers.append(.init(.heuristic, heuristicProvider))
        return tiers
    }
}
