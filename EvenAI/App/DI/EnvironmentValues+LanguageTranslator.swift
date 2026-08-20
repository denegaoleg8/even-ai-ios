import SwiftUI

/// How `RootView` gets the concrete `AppleLanguageTranslator` it needs to
/// host `.translationTask(_:action:)` — `LiveTranslationService` only
/// depends on the abstract `LanguageTranslating` protocol (see its doc
/// comment), but the SwiftUI-session-vending half of translation is
/// specific to this one concrete implementation, so it's threaded through
/// separately here rather than leaking `Translation`/SwiftUI concerns into
/// `LanguageTranslating` itself. Plain `EnvironmentKey`, not
/// `@Environment(Type.self)`: `AppleLanguageTranslator` doesn't need
/// SwiftUI observation (nothing about it drives view updates) — the same
/// reasoning `\.chatService`/`\.glassesTransport` follow for their own
/// non-observable service dependencies.
private struct LanguageTranslatorKey: EnvironmentKey {
    static let defaultValue = AppleLanguageTranslator()
}

extension EnvironmentValues {
    var languageTranslator: AppleLanguageTranslator {
        get { self[LanguageTranslatorKey.self] }
        set { self[LanguageTranslatorKey.self] = newValue }
    }
}
