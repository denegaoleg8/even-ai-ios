import Foundation
import SwiftData

/// Owns the app's SwiftData stack. `shared` backs the running app;
/// `preview` provisions an in-memory store for SwiftUI previews and tests.
/// Not actor-isolated: `ModelContainer` is `Sendable`, and construction
/// doesn't touch a `ModelContext`, so this is safe to reference from any
/// isolation domain, including the background actor `MockChatService`.
enum PersistenceController {
    static let shared = makeContainer(inMemory: false)
    static let preview = makeContainer(inMemory: true)

    private static func makeContainer(inMemory: Bool) -> ModelContainer {
        let schema = Schema([ChatEntity.self, MessageEntity.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }
}
