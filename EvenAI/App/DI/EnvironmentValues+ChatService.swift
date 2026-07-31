import SwiftUI

/// How `Features/Conversations` gets its `ChatServicing` — through the
/// environment, not a default parameter that reaches into `AppContainer`
/// directly (the Dependency Rule in `ARCHITECTURE.md`: `Features` may
/// depend on `Infrastructure` only via DI, never a concrete
/// `Infrastructure` type, and never `App/DI` itself). `ChatListViewModel`/
/// `ChatViewModel` take `chatService` as a required constructor
/// parameter with no default; `RootView` is the one place that reads
/// this environment value and threads it down explicitly to
/// `ChatListView`/`ChatView`'s own constructors — the same pattern
/// `ChatView` already used for `chatID`.
private struct ChatServiceKey: EnvironmentKey {
    // MockChatService, not AppContainer.live: safe for any preview or
    // test that renders these views without bothering to wire this up —
    // EvenAIApp is the only place that overrides it with the real thing.
    static let defaultValue: ChatServicing = MockChatService()
}

extension EnvironmentValues {
    var chatService: ChatServicing {
        get { self[ChatServiceKey.self] }
        set { self[ChatServiceKey.self] = newValue }
    }
}
