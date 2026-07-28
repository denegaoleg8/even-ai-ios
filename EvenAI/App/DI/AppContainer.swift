import Foundation

/// Composition root: the single place that constructs concrete service
/// implementations and hands them out. `MockChatService` remains available
/// for tests/previews (see `EvenAITests`), but the running app talks to the
/// real backend — nothing above this layer needed to change to make that
/// swap.
struct AppContainer: Sendable {
    let chatService: ChatServicing

    static let live = AppContainer(chatService: NetworkChatService())
}
