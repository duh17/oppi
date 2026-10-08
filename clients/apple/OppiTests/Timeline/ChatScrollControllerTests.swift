import Testing
import Foundation
@testable import Oppi

@Suite("ChatScrollController", .serialized)
@MainActor
struct ChatScrollControllerTests {

    @Test func initialState() {
        let controller = makeTestScrollController()
        #expect(controller.scrollTargetID == nil)
        #expect(!controller.needsInitialScroll)
        #expect(controller.isCurrentlyNearBottom)
    }

    @Test func cancelIsSafe() {
        let controller = makeTestScrollController()
        controller.cancel()
        controller.cancel() // idempotent
    }

    @Test func scrollTargetIDReset() {
        let controller = makeTestScrollController()
        controller.scrollTargetID = "item-42"
        #expect(controller.scrollTargetID == "item-42")
        controller.scrollTargetID = nil
        #expect(controller.scrollTargetID == nil)
    }

    @Test func needsInitialScrollToggle() {
        let controller = makeTestScrollController()
        #expect(!controller.needsInitialScroll)
        controller.needsInitialScroll = true
        #expect(controller.needsInitialScroll)
    }

    // MARK: - Near-Bottom State

    @Test func updateNearBottomTracksState() {
        let controller = makeTestScrollController()
        #expect(controller.isCurrentlyNearBottom)

        controller.updateNearBottom(false)
        #expect(!controller.isCurrentlyNearBottom)

        controller.updateNearBottom(true)
        #expect(controller.isCurrentlyNearBottom)
    }

    @Test func topVisibleItemIdTracksState() {
        let controller = makeTestScrollController()
        #expect(controller.currentTopVisibleItemId == nil)

        controller.updateTopVisibleItemId("item-7")
        #expect(controller.currentTopVisibleItemId == "item-7")

        controller.updateTopVisibleItemId(nil)
        #expect(controller.currentTopVisibleItemId == nil)
    }

    // MARK: - Hint Visibility

    @Test func detachedStreamingHintVisibility() {
        let controller = makeTestScrollController()
        #expect(!controller.isDetachedStreamingHintVisible)

        controller.setDetachedStreamingHintVisible(true)
        #expect(controller.isDetachedStreamingHintVisible)

        controller.setDetachedStreamingHintVisible(false)
        #expect(!controller.isDetachedStreamingHintVisible)
    }

    @Test func jumpToBottomHintVisibility() {
        let controller = makeTestScrollController()
        #expect(!controller.isJumpToBottomHintVisible)

        controller.setJumpToBottomHintVisible(true)
        #expect(controller.isJumpToBottomHintVisible)

        controller.setJumpToBottomHintVisible(false)
        #expect(!controller.isJumpToBottomHintVisible)
    }

    // MARK: - Initial Scroll & Scroll Target

    @Test func detachedNavigationReentryResolvesStableAnchorAndRelativePosition() {
        let controller = makeTestScrollController()
        controller.updateTimelineItemOrder(["before", "assistant-anchor", "after"])
        controller.detachFromBottomForUserScroll()
        controller.updateViewportAnchor(itemID: "assistant-anchor", relativeY: -37)
        controller.suspendForNavigation()

        let placement = controller.initialPlacement(
            availableFullTimelineItemIDs: ["new-before", "before", "assistant-anchor", "after", "new-after"],
            bottomItemID: "new-after"
        )

        #expect(placement == .viewport(TimelineViewportRestoration(
            itemID: "assistant-anchor",
            relativeY: -37
        )))
        #expect(!controller.isCurrentlyNearBottom)
    }

    @Test func navigationSnapshotSurvivesCleanupGeometryReset() {
        let controller = makeTestScrollController()
        controller.updateTimelineItemOrder(["before", "assistant-anchor", "after"])
        controller.detachFromBottomForUserScroll()
        controller.updateViewportAnchor(itemID: "assistant-anchor", relativeY: -37)
        controller.suspendForNavigation()

        // Session cleanup can temporarily empty the collection and report tail
        // geometry after the chat has disappeared. The frozen intent must win.
        controller.updateTimelineItemOrder([])
        controller.updateViewportAnchor(itemID: nil, relativeY: nil)
        controller.updateNearBottom(true)
        controller.suspendForNavigation()

        let placement = controller.initialPlacement(
            availableFullTimelineItemIDs: ["before", "assistant-anchor", "after", "new-tail"],
            bottomItemID: "new-tail"
        )

        #expect(placement == .viewport(TimelineViewportRestoration(
            itemID: "assistant-anchor",
            relativeY: -37
        )))
        #expect(!controller.isCurrentlyNearBottom)
    }

    @Test func missingAnchorFallsForwardToNearestSurvivingContext() {
        let snapshot = TimelineViewportSnapshot(
            anchorItemID: "anchor",
            anchorRelativeY: 24,
            fullTimelineItemIDs: ["older-2", "older-1", "anchor", "newer-1", "newer-2"]
        )

        let restoration = TimelineViewportRestorationResolver.resolve(
            snapshot,
            availableFullTimelineItemIDs: ["older-1", "newer-1"]
        )

        #expect(restoration == TimelineViewportRestoration(itemID: "newer-1", relativeY: 24))
    }

    @Test func missingAnchorFallsBackwardWhenNoFollowingContextSurvives() {
        let snapshot = TimelineViewportSnapshot(
            anchorItemID: "anchor",
            anchorRelativeY: -12,
            fullTimelineItemIDs: ["older-2", "older-1", "anchor", "newer-1"]
        )

        let restoration = TimelineViewportRestorationResolver.resolve(
            snapshot,
            availableFullTimelineItemIDs: ["older-2", "older-1"]
        )

        #expect(restoration == TimelineViewportRestoration(itemID: "older-1", relativeY: -12))
    }

    @Test func missingAnchorScansAllFollowingItemsBeforeAnyPrecedingItem() {
        let snapshot = TimelineViewportSnapshot(
            anchorItemID: "anchor",
            anchorRelativeY: 11,
            fullTimelineItemIDs: ["older-far", "older-near", "anchor", "newer-gone", "newer-far"]
        )

        let restoration = TimelineViewportRestorationResolver.resolve(
            snapshot,
            availableFullTimelineItemIDs: ["older-near", "newer-far"]
        )

        #expect(restoration == TimelineViewportRestoration(itemID: "newer-far", relativeY: 11))
    }

    @Test func missingContextUsesClampedOldOrdinalWithoutChoosingTailByDefault() {
        let snapshot = TimelineViewportSnapshot(
            anchorItemID: "old-anchor",
            anchorRelativeY: 18,
            fullTimelineItemIDs: ["gone-0", "gone-1", "old-anchor", "gone-3", "gone-4"]
        )

        let restoration = TimelineViewportRestorationResolver.resolve(
            snapshot,
            availableFullTimelineItemIDs: ["replacement-0", "replacement-1", "replacement-2", "replacement-tail"]
        )

        #expect(restoration == TimelineViewportRestoration(itemID: "replacement-2", relativeY: 18))
    }

    @Test func missingContextUsesAbsoluteOrdinalAcrossLongRenderedWindow() {
        let fullTimelineItemIDs = (0..<240).map { "item-\($0)" }
        let renderedWindowItemIDs = Array(fullTimelineItemIDs.suffix(80))
        #expect(renderedWindowItemIDs.first == "item-160")

        let snapshot = TimelineViewportSnapshot(
            anchorItemID: "item-180",
            anchorRelativeY: 18,
            fullTimelineItemIDs: fullTimelineItemIDs
        )
        let availableFullTimelineItemIDs = (0..<240).map { "replacement-\($0)" }

        let restoration = TimelineViewportRestorationResolver.resolve(
            snapshot,
            availableFullTimelineItemIDs: availableFullTimelineItemIDs
        )

        #expect(restoration == TimelineViewportRestoration(itemID: "replacement-180", relativeY: 18))
    }

    @Test func renderedWindowRestoreMapsCollapsedSourceToSyntheticWorkLine() {
        let restoration = TimelineViewportRestoration(
            itemID: "tool-1",
            relativeY: 31
        )

        let resolved = TimelineViewportRestorationResolver.resolveRenderedWindow(
            restoration,
            availableFullTimelineItemIDs: ["u1", "tool-1", "assistant-1"],
            renderedTimelineItemIDs: ["u1", "quiet-work-line:u1", "assistant-1"],
            renderedIDForFullTimelineItemID: { id in
                id == "tool-1" ? "quiet-work-line:u1" : id
            }
        )

        #expect(resolved == TimelineViewportRestoration(
            itemID: "quiet-work-line:u1",
            relativeY: 31
        ))
    }

    @Test func tailAttachedNavigationReentryReturnsToCurrentBottom() {
        let controller = makeTestScrollController()
        controller.updateNearBottom(true)
        controller.suspendForNavigation()

        let placement = controller.initialPlacement(
            availableFullTimelineItemIDs: ["old", "new-tail"],
            bottomItemID: "working-indicator"
        )

        #expect(placement == .bottom(itemID: "working-indicator"))
        #expect(controller.isCurrentlyNearBottom)
    }

    @Test func imagePreviewFreezesDetachedIntentAcrossPassiveGeometryUpdates() {
        let controller = makeTestScrollController()
        controller.updateTimelineItemOrder(["before", "anchor", "after"])
        controller.detachFromBottomForUserScroll()
        controller.updateViewportAnchor(itemID: "anchor", relativeY: -24)

        let preservation = controller.beginImagePreviewViewportPreservation(wasAttachedToTail: false)
        controller.updateNearBottom(true)

        #expect(preservation.snapshot?.anchorItemID == "anchor")
        #expect(!controller.isCurrentlyNearBottom)

        controller.endImagePreviewViewportPreservation(preservation.token)
        controller.updateNearBottom(true)
        #expect(controller.isCurrentlyNearBottom)
    }

    @Test func realTouchCancelsImagePreviewIntentFreeze() {
        let controller = makeTestScrollController()
        controller.updateNearBottom(true)
        let preservation = controller.beginImagePreviewViewportPreservation(wasAttachedToTail: true)
        #expect(controller.ownsImagePreviewViewportPreservation(preservation.token))

        controller.setUserInteracting(true)
        controller.setUserInteracting(false)
        controller.updateNearBottom(false)

        #expect(!controller.ownsImagePreviewViewportPreservation(preservation.token))
        #expect(!controller.isCurrentlyNearBottom)
    }

    @Test func handleScrollTargetInvokesCallbackAndResetsTarget() async {
        let controller = makeTestScrollController()
        controller.scrollTargetID = "target-1"

        var targets: [String] = []
        controller.handleScrollTarget { targets.append($0) }

        #expect(await waitForMainActorCondition(timeout: .milliseconds(100)) {
            targets == ["target-1"]
        })
        #expect(controller.scrollTargetID == nil)
        #expect(controller.pendingNavigationHighlightItemID == "target-1")

        let token = controller.consumeNavigationHighlightIfNeeded(for: "target-1")
        #expect(token != nil)
        #expect(controller.pendingNavigationHighlightItemID == nil)
        #expect(controller.consumeNavigationHighlightIfNeeded(for: "target-1") == nil)
    }

    // MARK: - requestScrollToBottom

    @Test func requestScrollToBottomReattachesAndClearsHints() {
        let controller = makeTestScrollController()
        controller.updateNearBottom(false)
        controller.setDetachedStreamingHintVisible(true)
        controller.setJumpToBottomHintVisible(true)

        let nonceBefore = controller.scrollToBottomNonce
        controller.requestScrollToBottom()

        #expect(controller.isCurrentlyNearBottom)
        #expect(!controller.isDetachedStreamingHintVisible)
        #expect(!controller.isJumpToBottomHintVisible)
        #expect(controller.scrollToBottomNonce == nonceBefore &+ 1)
    }

    @Test func requestScrollToBottomLocksFollowUntilUserScrollsUp() {
        let controller = makeTestScrollController()

        controller.requestScrollToBottom()
        controller.updateNearBottom(false)
        #expect(controller.isCurrentlyNearBottom,
                "passive near-bottom updates should not detach after explicit follow request")

        controller.detachFromBottomForUserScroll()
        #expect(!controller.isCurrentlyNearBottom)

        controller.updateNearBottom(true)
        controller.updateNearBottom(false)
        #expect(!controller.isCurrentlyNearBottom,
                "after explicit user detach, passive updates may keep controller detached")
    }

    // MARK: - Shell Swap Handoff

    @Test func shellSwapAfterOutgoingChatLeftRestoresItsReadingPosition() {
        let handoff = ChatScrollShellSwapHandoff()
        let stackChat = makeDetachedChat(anchor: "anchor", relativeY: -37)
        handoff.chatDidAppear(sessionId: "s1", controller: stackChat, presentation: .stack)

        stackChat.suspendForNavigation()
        handoff.chatDidDisappear(
            sessionId: "s1",
            controller: stackChat,
            mountedPresentation: .stack,
            currentPresentation: .split
        )
        let splitChat = makeTestScrollController()
        handoff.chatDidAppear(sessionId: "s1", controller: splitChat, presentation: .split)

        #expect(firstPlacement(of: splitChat) == .viewport(TimelineViewportRestoration(
            itemID: "anchor",
            relativeY: -37
        )))
    }

    @Test func shellSwapWhileOutgoingChatIsStillMountedRestoresItsLivePosition() {
        let handoff = ChatScrollShellSwapHandoff()
        let splitChat = makeDetachedChat(anchor: "anchor", relativeY: 12)
        handoff.chatDidAppear(sessionId: "s1", controller: splitChat, presentation: .split)

        let stackChat = makeTestScrollController()
        handoff.chatDidAppear(sessionId: "s1", controller: stackChat, presentation: .stack)
        // The outgoing chat leaves after the new one mounted; that must not
        // replace the new mount, or a quick swap back would read a dead chat.
        splitChat.suspendForNavigation()
        handoff.chatDidDisappear(
            sessionId: "s1",
            controller: splitChat,
            mountedPresentation: .split,
            currentPresentation: .stack
        )
        #expect(firstPlacement(of: stackChat) == .viewport(TimelineViewportRestoration(
            itemID: "anchor",
            relativeY: 12
        )))

        // Reading on, then swapping straight back, carries the new position.
        stackChat.updateTimelineItemOrder(["before", "anchor", "after"])
        stackChat.detachFromBottomForUserScroll()
        stackChat.updateViewportAnchor(itemID: "before", relativeY: 5)
        let splitAgain = makeTestScrollController()
        handoff.chatDidAppear(sessionId: "s1", controller: splitAgain, presentation: .split)

        #expect(firstPlacement(of: splitAgain) == .viewport(TimelineViewportRestoration(
            itemID: "before",
            relativeY: 5
        )))
    }

    @Test func shellSwapAtTheTailStaysAtTheTail() {
        let handoff = ChatScrollShellSwapHandoff()
        let stackChat = makeTestScrollController()
        stackChat.updateTimelineItemOrder(["before", "anchor", "after"])
        stackChat.updateViewportAnchor(itemID: "anchor", relativeY: 40)
        stackChat.updateNearBottom(true)
        handoff.chatDidAppear(sessionId: "s1", controller: stackChat, presentation: .stack)

        stackChat.suspendForNavigation()
        handoff.chatDidDisappear(
            sessionId: "s1",
            controller: stackChat,
            mountedPresentation: .stack,
            currentPresentation: .split
        )
        let splitChat = makeTestScrollController()
        handoff.chatDidAppear(sessionId: "s1", controller: splitChat, presentation: .split)

        #expect(firstPlacement(of: splitChat) == .bottom(itemID: "after"))
        #expect(splitChat.isCurrentlyNearBottom)
    }

    @Test func reopeningAChatInTheSameShellStartsAtTheTail() {
        let handoff = ChatScrollShellSwapHandoff()
        let first = makeDetachedChat(anchor: "anchor", relativeY: -37)
        handoff.chatDidAppear(sessionId: "s1", controller: first, presentation: .stack)

        first.suspendForNavigation()
        handoff.chatDidDisappear(
            sessionId: "s1",
            controller: first,
            mountedPresentation: .stack,
            currentPresentation: .stack
        )
        let reopened = makeTestScrollController()
        handoff.chatDidAppear(sessionId: "s1", controller: reopened, presentation: .stack)

        #expect(firstPlacement(of: reopened) == .bottom(itemID: "after"))
    }

    @Test func shellSwapDepartureExpiresBeforeALaterOpen() {
        let handoff = ChatScrollShellSwapHandoff()
        let start = ContinuousClock.now
        let stackChat = makeDetachedChat(anchor: "anchor", relativeY: -37)
        handoff.chatDidAppear(sessionId: "s1", controller: stackChat, presentation: .stack, now: start)

        stackChat.suspendForNavigation()
        handoff.chatDidDisappear(
            sessionId: "s1",
            controller: stackChat,
            mountedPresentation: .stack,
            currentPresentation: .split,
            now: start
        )
        let later = makeTestScrollController()
        handoff.chatDidAppear(
            sessionId: "s1",
            controller: later,
            presentation: .split,
            now: start + ChatScrollShellSwapHandoff.departureWindow + .milliseconds(1)
        )

        #expect(firstPlacement(of: later) == .bottom(itemID: "after"))
    }

    private func makeDetachedChat(anchor: String, relativeY: CGFloat) -> ChatScrollController {
        let controller = makeTestScrollController()
        controller.updateTimelineItemOrder(["before", anchor, "after"])
        controller.detachFromBottomForUserScroll()
        controller.updateViewportAnchor(itemID: anchor, relativeY: relativeY)
        return controller
    }

    /// The placement a freshly mounted timeline makes when history first lands.
    private func firstPlacement(of controller: ChatScrollController) -> TimelineInitialPlacement? {
        controller.needsInitialScroll = true
        return controller.initialPlacement(
            availableFullTimelineItemIDs: ["before", "anchor", "after"],
            bottomItemID: "after"
        )
    }

    private func makeTestScrollController() -> ChatScrollController {
        ChatScrollController()
    }
}
