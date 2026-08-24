import Testing
@testable import EvenAI

/// Pure tests for `ChatAutoScrollState` — the actual auto-scroll RULE
/// `ChatView` uses ("follow new content only while already near the
/// bottom; otherwise flag it, never force the user back down"), tested
/// entirely without a real `ScrollView`.
@Suite("ChatAutoScrollState")
struct ChatAutoScrollStateTests {
    @Test("starts near the bottom, with no pending new-messages indicator")
    func startsNearBottom() {
        let state = ChatAutoScrollState()
        #expect(state.isNearBottom)
        #expect(!state.hasNewMessagesBelow)
    }

    @Test("while near the bottom, new content should be auto-followed — no 'new messages' indicator appears")
    func newContentAutoFollowsWhenNearBottom() {
        var state = ChatAutoScrollState()
        let shouldScroll = state.newContentArrived()
        #expect(shouldScroll)
        #expect(!state.hasNewMessagesBelow)
    }

    @Test("once the user scrolls away from the bottom, new content is never auto-followed — it only raises the indicator")
    func newContentNeverForcesScrollWhenReadingOlderMessages() {
        var state = ChatAutoScrollState()
        state.scrollPositionChanged(isNearBottom: false)

        let shouldScroll = state.newContentArrived()

        #expect(!shouldScroll)
        #expect(state.hasNewMessagesBelow)
    }

    @Test("the 'new messages' indicator appears only after new content arrives while scrolled away — not merely from scrolling away")
    func indicatorOnlyAppearsAfterNewContentWhileAway() {
        var state = ChatAutoScrollState()
        state.scrollPositionChanged(isNearBottom: false)
        #expect(!state.hasNewMessagesBelow) // scrolling away alone doesn't raise it

        state.newContentArrived()
        #expect(state.hasNewMessagesBelow)
    }

    @Test("scrolling back near the bottom on your own clears the 'new messages' indicator")
    func scrollingBackNearBottomClearsIndicator() {
        var state = ChatAutoScrollState()
        state.scrollPositionChanged(isNearBottom: false)
        state.newContentArrived()
        #expect(state.hasNewMessagesBelow)

        state.scrollPositionChanged(isNearBottom: true)
        #expect(!state.hasNewMessagesBelow)
    }

    @Test("acknowledging (tapping the indicator) clears it without requiring a scroll-position change")
    func acknowledgingClearsIndicator() {
        var state = ChatAutoScrollState()
        state.scrollPositionChanged(isNearBottom: false)
        state.newContentArrived()
        #expect(state.hasNewMessagesBelow)

        state.acknowledgedNewMessages()
        #expect(!state.hasNewMessagesBelow)
    }

    @Test("multiple new-content arrivals while scrolled away keep the indicator up, without erroring or toggling it off")
    func repeatedNewContentWhileAwayStaysFlagged() {
        var state = ChatAutoScrollState()
        state.scrollPositionChanged(isNearBottom: false)

        _ = state.newContentArrived()
        _ = state.newContentArrived()
        _ = state.newContentArrived()

        #expect(state.hasNewMessagesBelow)
    }
}
