import Foundation

/// Live Translation's source-language selector. `.auto` runs on-device
/// language detection (see `LiveTranslationService`'s Auto-lock/hysteresis
/// behavior); `.en`/`.de`/`.pl` are explicit — the user has told the app
/// what language they're speaking, so no detection runs at all for every
/// utterance while that mode is selected. Stable, backend-matching codes
/// (`en`/`de`/`pl` — the same `SUPPORTED_LANGUAGES` even-ai-assistant-asr's
/// `openaiClient.js` already transcribes), not display strings, so this
/// type is what's actually persisted (`rawValue`, via `UserDefaults`).
enum SourceLanguageMode: String, CaseIterable, Codable, Sendable {
    case auto
    case en
    case de
    case pl

    /// Short, glasses-usable label for the selector UI — see
    /// `LiveTranslationView`'s "Auto | EN | DE | PL" control.
    var displayLabel: String {
        switch self {
        case .auto: "Auto"
        case .en: "EN"
        case .de: "DE"
        case .pl: "PL"
        }
    }

    /// The BCP-47-style source language code to hand `LanguageTranslating`
    /// directly, bypassing detection — `nil` for `.auto`, which has no
    /// fixed code of its own (it resolves one per utterance/session).
    var explicitLanguageCode: String? {
        switch self {
        case .auto: nil
        case .en: "en"
        case .de: "de"
        case .pl: "pl"
        }
    }
}
