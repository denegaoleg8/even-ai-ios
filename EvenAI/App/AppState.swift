import Foundation
import Observation

/// App-wide navigation state shared between the sidebar and detail column
/// of the root `NavigationSplitView`.
@MainActor
@Observable
final class AppState {
    var selectedChatID: Chat.ID?
    var isSettingsPresented: Bool = false
}
