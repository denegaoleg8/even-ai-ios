import Foundation
import Observation

/// App-wide navigation state shared between the sidebar and detail column
/// of the root `NavigationSplitView`.
@MainActor
@Observable
final class AppState {
    var selectedChatID: Chat.ID?
    var isSettingsPresented: Bool = false
    /// Bumped whenever something changed conversation data out from under
    /// the currently-displayed list/chat without changing `selectedChatID`
    /// or the signed-in identity — today, that's exactly one thing: a
    /// successful account merge. `ChatListView`/`ChatView` key a `.task`
    /// to this so they re-fetch instead of showing stale data.
    var chatListRefreshToken: Int = 0
}
