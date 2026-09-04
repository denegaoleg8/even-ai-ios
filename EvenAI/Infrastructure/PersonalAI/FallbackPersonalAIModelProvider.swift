import Foundation

/// Provider-independent Personal AI router. Tries each configured tier in
/// order; on any non-cancellation failure it logs a content-free diagnostic
/// and falls through to the next tier. Replaces the old, hardcoded "Apple
/// Foundation Models, or else heuristic" chain that used to live inside
/// `OnDevicePersonalAIModelProvider` — that type is now just one
/// interchangeable tier among however many this composes.
///
/// Guarantees:
/// - **Deterministic order** — tiers are tried in exactly the order given.
/// - **Cancellation is never swallowed** — a `CancellationError` from a tier
///   propagates immediately; the router does not try "just one more tier"
///   after the caller has already stopped waiting.
/// - **Exactly one user-visible response** — `generate` returns the first
///   tier's successful result, or throws; it never produces more than one
///   result for one call.
/// - **No memory access** — every tier only ever sees the
///   `PersonalAIGenerationRequest` handed to `generate`, byte-for-byte
///   identical across tiers (the router doesn't rebuild or touch it). The
///   router itself never references `PersonalMemoryStore` or any memory
///   type — memory stays exactly as provider-independent as it already was.
/// - **No unsafe retries** — each tier is tried exactly once; a tier that
///   wants its own internal retry (e.g. a network client) does that inside
///   its own `generate`, same as any standalone provider would.
/// - **Heuristic last** — enforced by composition order at the call site
///   (`PersonalAIContainer`), not hardcoded here, so the router itself stays
///   generic and does not know or care which tier is "the safe one."
struct FallbackPersonalAIModelProvider: PersonalAIModelProviding {

    /// One entry in the router's priority list: a stable diagnostic
    /// identity paired with the provider it labels.
    struct Tier: Sendable {
        let identity: PersonalAIProviderIdentity
        let provider: any PersonalAIModelProviding

        init(_ identity: PersonalAIProviderIdentity, _ provider: any PersonalAIModelProviding) {
            self.identity = identity
            self.provider = provider
        }
    }

    private let tiers: [Tier]

    init(tiers: [Tier]) {
        self.tiers = tiers
    }

    func generate(_ request: PersonalAIGenerationRequest) async throws -> PersonalAIGenerationResult {
        var lastError: Error?
        for (index, tier) in tiers.enumerated() {
            do {
                let result = try await tier.provider.generate(request)
                DiagnosticTrace.log(
                    "PERSONAL_AI_PROVIDER_ROUTER",
                    "tier=\(tier.identity.rawValue) outcome=success selected=\(tier.identity.rawValue)"
                )
                return result
            } catch is CancellationError {
                // The caller already stopped waiting — falling through to
                // another tier would produce a response nobody asked for
                // any more. Never swallow this into a "successful" answer.
                DiagnosticTrace.log(
                    "PERSONAL_AI_PROVIDER_ROUTER",
                    "tier=\(tier.identity.rawValue) outcome=cancelled"
                )
                throw CancellationError()
            } catch {
                let next = (index + 1 < tiers.count) ? tiers[index + 1].identity.rawValue : "none"
                DiagnosticTrace.log(
                    "PERSONAL_AI_PROVIDER_ROUTER",
                    "tier=\(tier.identity.rawValue) outcome=failed category=\(Self.category(of: error)) nextTier=\(next)"
                )
                lastError = error
                continue
            }
        }
        DiagnosticTrace.log("PERSONAL_AI_PROVIDER_ROUTER", "outcome=allTiersFailed")
        throw lastError ?? PersonalAIError.generationFailed("noTiersConfigured")
    }

    /// Content-free classification of a tier's failure, for diagnostics
    /// only — never changes routing behavior (every category falls
    /// through identically today). A tier that throws `PersonalAIProviderOutcome`
    /// directly is classified exactly as it said; anything else is
    /// inferred conservatively.
    private static func category(of error: Error) -> String {
        switch error {
        case let outcome as PersonalAIProviderOutcome:
            switch outcome {
            case .unavailable: return "unavailable"
            case .transientFailure: return "transientFailure"
            case .hardFailure: return "hardFailure"
            case .unsupported: return "unsupported"
            }
        case is PersonalAIError:
            // Every current `PersonalAIError`-throwing tier (the Foundation
            // Models availability switch) throws `.modelUnavailable` — an
            // expected, not-a-bug condition.
            return "unavailable"
        default:
            // An opaque SDK/network error — nothing proves it won't
            // succeed on retry or elsewhere, so it's classified as
            // transient rather than assumed permanent.
            return "transientFailure"
        }
    }
}
