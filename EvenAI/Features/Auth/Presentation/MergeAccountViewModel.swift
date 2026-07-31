import Foundation
import Observation

/// Drives `MergeAccountView`. Like `LoginViewModel`/`SignUpViewModel`,
/// holds no `AuthServicing`/`ChatServicing` of its own — every action it
/// takes goes through `AuthState`/`AppState`, passed in per call rather
/// than captured at init, so this view model stays a plain, DI-friendly
/// value with nothing to construct incorrectly by default.
@MainActor
@Observable
final class MergeAccountViewModel {
    private(set) var isMerging = false
    private(set) var errorMessage: String?
    private(set) var didMergeSuccessfully = false

    let fromAccountID: User.ID

    init(fromAccountID: User.ID) {
        self.fromAccountID = fromAccountID
    }

    /// On success, bumps `appState.chatListRefreshToken` so the
    /// conversation list (and any currently-open chat) re-fetches — the
    /// merge changed which chats belong to this account without changing
    /// the account's identity itself, so nothing else would otherwise
    /// notice.
    func merge(using authState: AuthState, appState: AppState) async {
        isMerging = true
        errorMessage = nil
        defer { isMerging = false }

        do {
            _ = try await authState.mergeAccount(fromAccountID: fromAccountID)
            appState.chatListRefreshToken += 1
            didMergeSuccessfully = true
        } catch {
            errorMessage = Self.friendlyMessage(for: error)
        }
    }

    private static func friendlyMessage(for error: Error) -> String {
        (error as? AuthError)?.errorDescription ?? AuthError.unknown.errorDescription ?? "Something went wrong."
    }
}
