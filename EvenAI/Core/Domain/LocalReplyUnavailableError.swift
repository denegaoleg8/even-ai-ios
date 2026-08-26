import Foundation

/// Thrown by a local (on-device) `SuggestedReplyGenerating` implementation
/// specifically when the underlying capability itself isn't usable right
/// now — distinct from a generic/transient failure (a single bad
/// generation, cancellation), which `LiveTranslationService
/// .generateSuggestedReplies(for:sequence:turnStartTime:)` already treats
/// identically either way ("skip this turn's replies, translation stays
/// visible"). This ONE error type additionally drives
/// `LiveTranslationService.repliesUnavailableReason`, so the Live
/// Translation UI can truthfully explain WHY replies aren't appearing at
/// all, rather than every turn silently having none for no visible
/// reason. Deliberately lives in `Core/Domain` (not `Infrastructure`,
/// where the real `FoundationModels`-based generator that throws it
/// lives) so `LiveTranslationService` can catch/inspect it without
/// importing anything Apple-Intelligence-specific.
struct LocalReplyUnavailableError: Error, Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        /// This app's deployment target (iOS 18.0) is lower than what
        /// Apple's `FoundationModels` framework requires (iOS 26.0) —
        /// the device itself hasn't been checked yet at this point.
        case osVersionTooOld
        /// The device's hardware doesn't support Apple Intelligence at
        /// all (`SystemLanguageModel.Availability.UnavailableReason
        /// .deviceNotEligible`).
        case deviceNotEligible
        /// The device could support Apple Intelligence, but the user
        /// hasn't turned it on (`.appleIntelligenceNotEnabled`).
        case appleIntelligenceNotEnabled
        /// Apple Intelligence is enabled but the on-device model assets
        /// aren't downloaded/ready yet (`.modelNotReady`) — this is the
        /// one transient case among the four; it may resolve on its own
        /// without any user action.
        case modelNotReady
    }

    let reason: Reason

    /// A short, truthful, non-alarming explanation — never implies a bug
    /// or a network problem, since this has nothing to do with either.
    var userFacingMessage: String {
        switch reason {
        case .osVersionTooOld:
            "Suggested replies need a newer iOS version."
        case .deviceNotEligible:
            "Suggested replies aren't supported on this device."
        case .appleIntelligenceNotEnabled:
            "Suggested replies need Apple Intelligence — enable it in Settings to use them."
        case .modelNotReady:
            "Suggested replies aren't ready yet — the on-device model is still downloading."
        }
    }
}
