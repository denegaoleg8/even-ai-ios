import Foundation

/// The shared session's own, presentation-independent notion of whether
/// a live G2 conversation is currently active. Deliberately NOT the same
/// type as `LiveTranslationService.State` — that type is `@MainActor`/
/// SwiftUI-observable app state; this one must stay importable from a
/// plain domain-model test target with no Speech/SwiftUI dependency at
/// all. Milestone 1 only defines this type — nothing yet updates it from
/// `LiveTranslationService`; that wiring is explicitly out of scope this
/// milestone ("do not change current Live Translation behavior").
enum LiveConversationState: Codable, Equatable, Sendable {
    case inactive
    case listening
    case paused
}
