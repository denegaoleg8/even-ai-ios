import Foundation
import Observation

/// App-wide authentication state — the single source of truth for "who
/// is currently signed in," shared via `.environment()` from
/// `EvenAIApp` exactly like `AppState`. Not a singleton: there is no
/// `static let shared` here, only a normal `@Observable` instance
/// constructed once and injected down the view hierarchy, the same
/// dependency-injection pattern used everywhere else in this app.
///
/// Owns both the state and the actions that mutate it (sign in/up/out,
/// restore) rather than being a passive value a ViewModel updates from
/// outside — a ViewModel calling `authService` directly and forgetting
/// to also update this object is exactly the kind of state-drift bug
/// this design rules out by construction.
@MainActor
@Observable
final class AuthState {
    private(set) var currentUser: User?
    private(set) var isRestoringSession = true
    /// True only when `restoreSession()`/`retrySession()` genuinely
    /// failed — BOTH the refresh and anonymous-device recovery tiers
    /// were exhausted, not merely "hasn't resolved yet" (that's what
    /// `isRestoringSession` already covers). Section J's self-heal
    /// audit: this is what lets Settings show a real "Retry Session"
    /// affordance instead of leaving the user with no explanation for
    /// why nothing works. Cleared the moment recovery succeeds again,
    /// whether via an explicit `retrySession()` call or a later reactive
    /// recovery elsewhere in the app (see `observeSessionChanges()`).
    private(set) var sessionRecoveryFailed = false
    /// Set by `signIn` when the device already had its own local
    /// (anonymous) account with chats — see `AuthResult.mergeAvailableFrom`.
    /// Deliberately *not* cleared just because the merge screen was
    /// skipped: "Skip for now" (Phase 3.7) means exactly that, so Settings
    /// can still offer it later. It's cleared when a merge actually
    /// succeeds, or when signing out makes it stale (see `signOut`).
    private(set) var mergeAvailableFrom: User.ID?
    /// Paired with `mergeAvailableFrom`, same lifecycle — see
    /// `AuthResult.mergeToken`.
    private(set) var mergeToken: String?

    private let authService: AuthServicing
    private var sessionChangeTask: Task<Void, Never>?
    /// Phase 3.9: called at every point a signed-in identity's chats may
    /// no longer match what `CachingChatService` has cached — logout,
    /// switching to a different account, a merge changing which chats
    /// this account owns, or a silent session-recovery fallback. Kept as
    /// an injected closure, not a direct `CachingChatService` reference,
    /// so `AuthState` stays exactly as decoupled from chat concerns as it
    /// was before this cache existed — it knows "something needs
    /// invalidating," never what that something is or how.
    private let invalidateChatCache: @Sendable () async -> Void

    init(
        authService: AuthServicing = AppContainer.live.authService,
        invalidateChatCache: @escaping @Sendable () async -> Void = { AppContainer.live.chatCache.invalidate() }
    ) {
        self.authService = authService
        self.invalidateChatCache = invalidateChatCache
        observeSessionChanges()
    }

    /// Called once, at launch. Never throws to its caller: a failure
    /// here (e.g. first launch, fully offline) just leaves `currentUser`
    /// nil — the rest of the app already has its own graceful
    /// network-failure handling (see `ChatListViewModel`/`ChatViewModel`'s
    /// `loadFailed`), so an unauthenticated launch state doesn't need to
    /// be a special case here too.
    func restoreSession() async {
        isRestoringSession = true
        defer { isRestoringSession = false }
        do {
            currentUser = try await authService.restoreSession()
            sessionRecoveryFailed = false
        } catch {
            // Both recovery tiers were exhausted — a genuine failure,
            // not merely "hasn't resolved yet." `currentUser` stays
            // whatever it already was (`nil` on a first launch) — the
            // app must remain usable; this only surfaces the failure so
            // Settings can offer a real "Retry Session" affordance
            // instead of the previous silent `try?` leaving no trace
            // anywhere that recovery ever actually failed.
            sessionRecoveryFailed = true
        }
    }

    /// Explicit, user-initiated retry (Settings' "Retry Session"
    /// button) — see `AuthServicing.retrySession()`'s own doc comment
    /// for why this bypasses the cooldown a recently-failed automatic
    /// recovery leaves in place elsewhere in the app.
    func retrySession() async {
        do {
            currentUser = try await authService.retrySession()
            sessionRecoveryFailed = false
        } catch {
            sessionRecoveryFailed = true
        }
    }

    func signUp(email: String, password: String, displayName: String?) async throws {
        currentUser = try await authService.signUp(email: email, password: password, displayName: displayName)
    }

    @discardableResult
    func signIn(email: String, password: String) async throws -> AuthResult {
        let result = try await authService.signIn(email: email, password: password)
        let isAccountSwitch = currentUser?.id != result.user.id
        currentUser = result.user
        mergeAvailableFrom = result.mergeAvailableFrom
        mergeToken = result.mergeToken
        // Signing into the *same* account this device already had
        // (claiming it via signup counts as "same," not a switch) leaves
        // its cached chats still correct — nothing to invalidate. A
        // genuine switch to a different account means the cache is now
        // showing the wrong account's data entirely.
        if isAccountSwitch {
            await invalidateChatCache()
        }
        return result
    }

    func signOut() async {
        try? await authService.signOut()
        currentUser = nil
        // A pending merge offer belonged to whatever account was just
        // signed out of — carrying it forward would let a later merge
        // call (scoped server-side to "whoever is signed in *now*") move
        // this device's old chats into a completely different account.
        mergeAvailableFrom = nil
        mergeToken = nil
        await invalidateChatCache()
    }

    func signOutEverywhere() async {
        try? await authService.signOutEverywhere()
        currentUser = nil
        mergeAvailableFrom = nil
        mergeToken = nil
        await invalidateChatCache()
    }

    func mergeAccount(fromAccountID: User.ID) async throws -> Int {
        let mergedCount = try await authService.mergeAccount(fromAccountID: fromAccountID, mergeToken: mergeToken)
        mergeAvailableFrom = nil
        mergeToken = nil
        // The merge just changed which chats this account owns — cached
        // data reflects a snapshot from before that happened.
        await invalidateChatCache()
        return mergedCount
    }

    /// Subscribes for the lifetime of this instance (the whole app, in
    /// practice — `AuthState` is constructed once in `EvenAIApp`) to
    /// identity changes the underlying client resolves on its own, not
    /// just the ones this object's own methods triggered. See
    /// `AuthServicing.sessionChanges()` for why this exists.
    private func observeSessionChanges() {
        let authService = self.authService
        let invalidateChatCache = self.invalidateChatCache
        sessionChangeTask = Task { [weak self] in
            let stream = await authService.sessionChanges()
            for await user in stream {
                guard !Task.isCancelled, let self else { return }
                // A routine token refresh re-resolves the *same*
                // identity and fires this stream too — invalidating the
                // cache every time that happens would defeat the point
                // of having one. Only a genuinely different identity
                // (the silent anonymous-fallback case this stream exists
                // for) means the cache no longer matches who's signed in.
                let identityChanged = self.currentUser?.id != user.id
                self.currentUser = user
                // A session that just resolved via this stream is, by
                // definition, no longer failed — this is what makes a
                // LATER, reactive recovery (e.g. Chat's own 401 path
                // succeeding after a transient blip) clear a stale
                // "Retry Session" affordance in Settings without the
                // user needing to tap it themselves.
                self.sessionRecoveryFailed = false
                if identityChanged {
                    await invalidateChatCache()
                }
            }
        }
    }
}
