import Foundation
import FoundationModels

/// The production `PersonalAIModelProviding`. Tries, in order:
///
/// 1. Apple `FoundationModels` on-device (`LanguageModelSession`), if truly
///    available right now (iOS 26+, device eligible, Apple Intelligence on,
///    model ready).
/// 2. `HeuristicPersonalAIModelProvider` — always works, offline, no Apple
///    Intelligence needed.
///
/// **No cloud tier.** A future cloud provider is an explicit, opt-in
/// `PersonalAIModelProviding` wired elsewhere — this stack never silently
/// reaches for a network. Same shape as `LocalSuggestedReplyGenerator`,
/// including the testability override.
struct OnDevicePersonalAIModelProvider: PersonalAIModelProviding {

    private let fallback: HeuristicPersonalAIModelProvider
    /// Test seam only — production is `nil` and uses the real
    /// `#available`-gated FoundationModels path.
    private let onDeviceOverride: (any PersonalAIModelProviding)?

    init(
        fallback: HeuristicPersonalAIModelProvider = HeuristicPersonalAIModelProvider(),
        onDeviceOverride: (any PersonalAIModelProviding)? = nil
    ) {
        self.fallback = fallback
        self.onDeviceOverride = onDeviceOverride
    }

    func generate(_ request: PersonalAIGenerationRequest) async throws -> PersonalAIGenerationResult {
        if let onDeviceOverride {
            do { return try await onDeviceOverride.generate(request) }
            catch { return try await fallback.generate(request) }
        }
        if #available(iOS 26.0, *) {
            do {
                return try await FoundationModelsPersonalAIProvider().generate(request)
            } catch {
                DiagnosticTrace.log("PERSONAL_AI_MODEL_FALLBACK", "reason=\(type(of: error))")
                return try await fallback.generate(request)
            }
        }
        DiagnosticTrace.log("PERSONAL_AI_MODEL_FALLBACK", "reason=osVersionTooOld")
        return try await fallback.generate(request)
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
