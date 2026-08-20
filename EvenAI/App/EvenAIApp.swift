import SwiftUI
import SwiftData

@main
struct EvenAIApp: App {
    @State private var appState = AppState()
    @State private var authState = AuthState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .environment(authState)
                .environment(\.chatService, AppContainer.live.chatService)
                .environment(\.glassesTransport, AppContainer.live.glassesTransport)
        }
        .modelContainer(PersistenceController.shared)
    }
}
