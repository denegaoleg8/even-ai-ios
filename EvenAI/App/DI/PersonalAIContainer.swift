import Foundation

/// Composition root for the Personal AI stack — the one place concrete
/// Personal AI implementations are chosen, mirroring `AppContainer`. Kept
/// separate from `AppContainer` so the proven AI Conversation / Chat / Auth
/// wiring is not even touched by this feature.
///
/// Phase 1 wiring is entirely local:
/// - `LocalPersonalMemoryStore` (JSON file, dev storage — not authoritative),
/// - `OnDevicePersonalAIModelProvider` (Apple FoundationModels → heuristic),
/// - `LocalPersonalAIConversationStore` (JSON file).
///
/// No Railway, no vendor SDK beyond Apple's on-device `FoundationModels`,
/// no cloud.
struct PersonalAIContainer: Sendable {
    let memoryStore: any PersonalMemoryStore
    let conversationStore: any PersonalAIConversationStore
    let contextBuilder: any PersonalAIContextBuilding
    let modelProvider: any PersonalAIModelProviding

    static let live: PersonalAIContainer = {
        let memoryStore = LocalPersonalMemoryStore()
        return PersonalAIContainer(
            memoryStore: memoryStore,
            conversationStore: LocalPersonalAIConversationStore(),
            contextBuilder: DefaultPersonalAIContextBuilder(store: memoryStore),
            modelProvider: OnDevicePersonalAIModelProvider()
        )
    }()

    @MainActor
    func makeService() -> PersonalAIService {
        PersonalAIService(
            store: memoryStore,
            contextBuilder: contextBuilder,
            modelProvider: modelProvider,
            conversationStore: conversationStore
        )
    }
}
