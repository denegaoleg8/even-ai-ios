import Foundation

/// Which speech-recognition provider Live Translation's STT stage uses —
/// the local-first architecture pass's core setting. `.onDevice` and
/// `.cloud` are hard commitments: `.onDevice` NEVER silently sends audio to
/// a backend, even if on-device recognition turns out to be unavailable for
/// the resolved locale (it fails loudly instead — see
/// `TranscriptionProviderRouter`); `.cloud` always uses
/// `OpenAIRealtimeTranscriber`, unconditionally requiring Railway/auth,
/// exactly like production did before this pass. `.auto` (the default)
/// prefers on-device and only falls back to cloud if on-device recognition
/// can't even start for the current session (e.g. the resolved locale has
/// no installed/supported on-device model on this device) — never a
/// silent fallback mid-session once a provider has started successfully.
///
/// Persisted the same way `SourceLanguageMode`/`AudioSource`/
/// `ConversationProfile` already are (`UserDefaults`, via
/// `AIConversationEngine`), so the choice survives relaunch.
enum TranscriptionProviderMode: String, CaseIterable, Codable, Sendable {
    case auto
    case onDevice
    case cloud

    var displayLabel: String {
        switch self {
        case .auto: "Auto"
        case .onDevice: "On-device"
        case .cloud: "Cloud"
        }
    }
}

/// Which speech-recognition provider actually ended up transcribing the
/// current/most recent Live Translation session — distinct from
/// `TranscriptionProviderMode` (the user's *setting*, e.g. `.auto`) the
/// same way a DNS record is distinct from the resolved IP: `.auto` always
/// resolves to one of these two before any audio is ever transcribed. Used
/// for the provider-labeling UI (§16 of the local-first architecture pass:
/// "clear provider labeling — on-device vs. cloud") and for tests asserting
/// which provider actually ran.
enum ActiveTranscriptionProvider: String, Sendable, Equatable {
    case onDevice
    case cloud
}
