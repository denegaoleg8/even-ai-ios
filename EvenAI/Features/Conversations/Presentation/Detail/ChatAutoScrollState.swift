import Foundation

/// Pure decision logic for `ChatView`'s auto-scroll behavior — extracted
/// so the actual RULE ("follow new content only while already near the
/// bottom; otherwise flag it and let the user decide") is unit-testable
/// without a real `ScrollView`/`UIScrollView`, mirroring this codebase's
/// established pattern for UI-adjacent state machines
/// (`GlassesPaginationState`/`GlassesReadinessGate`).
///
/// `ChatView` owns exactly one instance, updated from two places: scroll
/// position changes (`scrollPositionChanged(isNearBottom:)`, driven by
/// `.onScrollGeometryChange`) and new content arriving
/// (`newContentArrived()`, driven by `.onChange(of: viewModel.messages)`).
struct ChatAutoScrollState: Equatable {
    private(set) var isNearBottom = true
    private(set) var hasNewMessagesBelow = false

    /// Call whenever the scroll view reports whether its visible bottom
    /// edge is within the "near bottom" threshold. Scrolling back near
    /// the bottom on your own is itself what clears the "new messages"
    /// indicator — the user caught up.
    mutating func scrollPositionChanged(isNearBottom: Bool) {
        self.isNearBottom = isNearBottom
        if isNearBottom {
            hasNewMessagesBelow = false
        }
    }

    /// Call when the message list changes (a new message, or the last
    /// one's content growing while streaming). Returns whether the
    /// caller should actually scroll to the bottom now — `true` only
    /// while already near it; otherwise this records that something new
    /// arrived (surfacing the "↓ New messages" control) without ever
    /// forcing the view to move.
    @discardableResult
    mutating func newContentArrived() -> Bool {
        guard isNearBottom else {
            hasNewMessagesBelow = true
            return false
        }
        return true
    }

    /// Call once the user taps the "↓ New messages" control (which
    /// itself triggers the actual scroll) — clears the indicator.
    mutating func acknowledgedNewMessages() {
        hasNewMessagesBelow = false
    }
}
