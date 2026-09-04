import Foundation
import FoundationModels

/// The Foundation Models tier of the Personal AI provider router — Apple
/// on-device `LanguageModelSession`, and **only** that. Unlike its previous
/// shape, this type no longer falls back to `HeuristicPersonalAIModelProvider`
/// itself: on any failure it logs a content-free, Foundation-Models-specific
/// diagnostic and **rethrows**, so a `FallbackPersonalAIModelProvider`
/// composing this alongside other tiers (see that type) decides what happens
/// next — the same failure here can fall through to a future remote/local
/// tier before ever reaching heuristic, not just straight to it.
///
/// Same shape as `LocalSuggestedReplyGenerator`, including the testability
/// override.
struct OnDevicePersonalAIModelProvider: PersonalAIModelProviding {

    /// Test seam only — production is `nil` and uses the real
    /// `#available`-gated FoundationModels path.
    private let onDeviceOverride: (any PersonalAIModelProviding)?

    init(onDeviceOverride: (any PersonalAIModelProviding)? = nil) {
        self.onDeviceOverride = onDeviceOverride
    }

    func generate(_ request: PersonalAIGenerationRequest) async throws -> PersonalAIGenerationResult {
        if let onDeviceOverride {
            return try await onDeviceOverride.generate(request)
        }
        if #available(iOS 26.0, *) {
            do {
                return try await FoundationModelsPersonalAIProvider().generate(request)
            } catch {
                Self.logFailure(error)
                throw error
            }
        }
        DiagnosticTrace.log(
            "PERSONAL_AI_FM_PROVIDER",
            "provider=onDeviceFoundationModel failureStage=osVersionCheck availability=n/a underlyingErrorType=n/a mappedError=osVersionTooOld"
        )
        throw PersonalAIError.modelUnavailable(reason: "this iOS version doesn't support Apple Intelligence")
    }

    /// Content-free diagnosis of *why* the real Foundation Models tier
    /// didn't answer — structural facts only, never the prompt, memory, or
    /// reply text. Kept inside this type deliberately: Foundation
    /// Models-specific detail (`SystemLanguageModel.default.availability`)
    /// belongs to the Foundation Models provider's own diagnostic boundary,
    /// not the provider-neutral router's (see `FallbackPersonalAIModelProvider`,
    /// which logs generic tier/outcome/category only).
    ///
    /// `FoundationModelsPersonalAIProvider.generate` has exactly two places
    /// that can throw: the availability switch at its top (always surfaces
    /// as `PersonalAIError.modelUnavailable`, built from four fixed,
    /// app-authored `reason:` strings hardcoded right there — safe to print
    /// in full) and `session.respond` (anything else). There is no
    /// throwing session-creation or prompt-construction step in this SDK
    /// usage, so this binary split is exhaustive for the current code, not
    /// a guess.
    ///
    /// For a non-`PersonalAIError` (i.e. `session.respond`) failure, only
    /// the Swift *type name* is logged — a FoundationModels SDK error's
    /// full description is not proven free of prompt content, but a type
    /// name is compiler-derived and cannot carry any of it.
    @available(iOS 26.0, *)
    private static func logFailure(_ error: Error) {
        let availability = "\(SystemLanguageModel.default.availability)"
        if let mapped = error as? PersonalAIError {
            DiagnosticTrace.log(
                "PERSONAL_AI_FM_PROVIDER",
                "provider=onDeviceFoundationModel failureStage=availabilityCheck availability=\(availability) underlyingErrorType=\(type(of: error)) mappedError=\(mapped)"
            )
        } else {
            DiagnosticTrace.log(
                "PERSONAL_AI_FM_PROVIDER",
                "provider=onDeviceFoundationModel failureStage=sessionRespond availability=\(availability) underlyingErrorType=\(type(of: error)) mappedError=none"
            )
        }
    }
}

/// Real on-device implementation. A fresh `LanguageModelSession` per call —
/// each Personal AI turn is an independent request (the conversation history
/// is passed explicitly), matching `FoundationModelsReplyGenerator`'s design.
@available(iOS 26.0, *)
struct FoundationModelsPersonalAIProvider: PersonalAIModelProviding {

    func generate(_ request: PersonalAIGenerationRequest) async throws -> PersonalAIGenerationResult {
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(.deviceNotEligible):
            throw PersonalAIError.modelUnavailable(reason: "this device isn't eligible for Apple Intelligence")
        case .unavailable(.appleIntelligenceNotEnabled):
            throw PersonalAIError.modelUnavailable(reason: "Apple Intelligence is off")
        case .unavailable(.modelNotReady):
            throw PersonalAIError.modelUnavailable(reason: "the on-device model is still downloading")
        case .unavailable:
            throw PersonalAIError.modelUnavailable(reason: "the on-device model isn't available")
        }

        let instructions = """
            You are the user's persistent Personal AI. You have long-term memory of who they \
            are and what they're working on. Use it naturally: connect their message to \
            relevant context, draw useful implications, and ask a genuinely useful follow-up \
            when it helps. Do not narrate that you are using memory. Never reply with an empty \
            acknowledgement ("thanks for sharing", "that's interesting", "I'm here if you \
            need anything") when you have something substantive to say. Follow every standing \
            instruction and the stated response style. \
            When the user asks a direct question about themselves — their name, where they \
            live, what they do — and the context lists it as a known fact, answer plainly and \
            directly from that fact; do not deflect, greet, or ask for information you already \
            have.
            """
        let session = LanguageModelSession(instructions: instructions)

        var prompt = ""
        if !request.personalContext.systemPromptText.isEmpty {
            prompt += request.personalContext.systemPromptText + "\n\n"
        }
        let recent = request.messages.suffix(8)
        if !recent.isEmpty {
            prompt += "Conversation so far:\n"
            for m in recent {
                prompt += "\(m.role == .user ? "User" : "You"): \(m.text)\n"
            }
            prompt += "\n"
        }
        prompt += "User: \(request.userMessage)\nYou:"

        let response = try await session.respond(to: prompt)
        let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return PersonalAIGenerationResult(
            text: text,
            provider: .onDeviceFoundationModel,
            usedPersonalization: request.personalContext.hasPersonalization
        )
    }
}
