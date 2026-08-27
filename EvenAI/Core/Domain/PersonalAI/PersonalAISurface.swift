import Foundation

/// Which product surface is asking the Personal AI for context. The whole
/// point of Phase 1 is that this is the *only* thing that differs between
/// Personal AI Chat and future G2 personalization — they share one memory
/// model, one retrieval pipeline, and one `PersonalAIContextBuilding`
/// contract, parameterised by this.
enum PersonalAISurface: String, Codable, CaseIterable, Hashable, Sendable {
    /// The user typing directly to their Personal AI.
    case personalChat

    /// G2 suggested-reply personalization. Not wired into the live G2
    /// pipeline in Phase 1 — the seam exists and is contract-tested only.
    case g2Replies

    /// Reserved for the future voice assistant. Declared now so the
    /// retrieval/priors tables don't need a breaking change later.
    case voiceAssistant

    var displayName: String {
        switch self {
        case .personalChat: return "Personal AI Chat"
        case .g2Replies: return "G2 Replies"
        case .voiceAssistant: return "Voice Assistant"
        }
    }
}
