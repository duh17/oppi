import Testing
import Foundation
import UIKit
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

    // MARK: - handleContentChange

    @Test func handleContentChangeScrollsToStreamingTarget() async {
        let controller = makeTestScrollController()
        controller.updateNearBottom(true)

        var targets: [String] = []
        controller.handleContentChange(
            isBusy: true,
            streamingAssistantID: "stream-1",
            bottomItemID: "bottom-1"
        ) { targets.append($0) }

        #expect(await waitForMainActorCondition(timeout: .milliseconds(100)) {
            targets == ["stream-1"]
        })
    }

    @Test func handleContentChangeScrollsToBottomWhenNoStreaming() async {
        let controller = makeTestScrollController()
        controller.updateNearBottom(true)

        var targets: [String] = []
        controller.handleContentChange(
            isBusy: true,
            streamingAssistantID: nil,
            bottomItemID: "bottom-1"
        ) { targets.append($0) }

        #expect(await waitForMainActorCondition(timeout: .milliseconds(100)) {
            targets == ["bottom-1"]
        })
    }

    @Test func handleContentChangeSkipsWhenNotNearBottom() async {
        let controller = makeTestScrollController()
        controller.updateNearBottom(false)

        var callCount = 0
        controller.handleContentChange(
            isBusy: true,
            streamingAssistantID: "stream-1",
            bottomItemID: "bottom-1"
        ) { _ in callCount += 1 }

        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(20)) {
            callCount == 0
        })
    }

    @Test func handleContentChangeHeavyTimelineFollowsWhenBusy() async {
        let controller = makeTestScrollController()
        controller.updateNearBottom(true)
        controller.itemCount = 240

        var targets: [String] = []
        controller.handleContentChange(
            isBusy: true,
            streamingAssistantID: "stream-1",
            bottomItemID: "bottom-1"
        ) { targets.append($0) }

        #expect(await waitForMainActorCondition(timeout: .milliseconds(100)) {
            targets == ["stream-1"]
        })
    }

    @Test func handleContentChangeHeavyTimelineSkipsWhenIdle() async {
        let controller = makeTestScrollController()
        controller.updateNearBottom(true)
        controller.itemCount = 240

        var callCount = 0
        controller.handleContentChange(
            isBusy: false,
            streamingAssistantID: nil,
            bottomItemID: "bottom-1"
        ) { _ in callCount += 1 }

        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(20)) {
            callCount == 0
        })
    }

    @Test func handleContentChangeSkipsDuringKeyboardTransition() async {
        let controller = makeTestScrollController()
        controller.updateNearBottom(true)

        NotificationCenter.default.post(name: UIResponder.keyboardWillShowNotification, object: nil)
        await Task.yield()

        var callCount = 0
        controller.handleContentChange(
            isBusy: true,
            streamingAssistantID: "stream-1",
            bottomItemID: "bottom-1"
        ) { _ in callCount += 1 }

        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(20)) {
            callCount == 0
        })

        // After keyboard settles
        controller.expireKeyboardTransitionForTesting()
        controller.handleContentChange(
            isBusy: true,
            streamingAssistantID: "stream-1",
            bottomItemID: "bottom-1"
        ) { _ in callCount += 1 }

        #expect(await waitForMainActorCondition(timeout: .milliseconds(100)) {
            callCount == 1
        })
    }

    @Test func handleContentChangeRechecksKeyboardBeforeDelayedScroll() async {
        let controller = ChatScrollController()
        controller.updateNearBottom(true)

        var callCount = 0
        controller.handleContentChange(
            isBusy: true,
            streamingAssistantID: "stream-1",
            bottomItemID: "bottom-1"
        ) { _ in callCount += 1 }

        // Fire keyboard mid-delay.
        try? await Task.sleep(for: .milliseconds(10))
        NotificationCenter.default.post(name: UIResponder.keyboardWillShowNotification, object: nil)
        await Task.yield()

        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(140)) {
            callCount == 0
        })
    }

    @Test func handleContentChangeSkipsDuringUserInteraction() async {
        let controller = makeTestScrollController()
        controller.updateNearBottom(true)
        controller.setUserInteracting(true)

        var callCount = 0
        controller.handleContentChange(
            isBusy: true,
            streamingAssistantID: "stream-1",
            bottomItemID: "bottom-1"
        ) { _ in callCount += 1 }

        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(20)) {
            callCount == 0
        })
    }

    @Test func handleContentChangeCancelsPendingScrollWhenUserStartsInteracting() async {
        let controller = makeTestScrollController()
        controller.updateNearBottom(true)

        var callCount = 0
        controller.handleContentChange(
            isBusy: true,
            streamingAssistantID: "stream-1",
            bottomItemID: "bottom-1"
        ) { _ in callCount += 1 }

        controller.setUserInteracting(true)

        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(20)) {
            callCount == 0
        })

        controller.setUserInteracting(false)
        controller.handleContentChange(
            isBusy: true,
            streamingAssistantID: "stream-1",
            bottomItemID: "bottom-1"
        ) { _ in callCount += 1 }

        #expect(await waitForMainActorCondition(timeout: .milliseconds(100)) {
            callCount == 1
        })
    }

    @Test func detachFromBottomForUserScrollRequiresReentry() async {
        let controller = makeTestScrollController()
        controller.updateNearBottom(true)
        controller.detachFromBottomForUserScroll()

        var callCount = 0
        controller.handleContentChange(
            isBusy: true,
            streamingAssistantID: "stream-1",
            bottomItemID: "bottom-1"
        ) { _ in callCount += 1 }

        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(20)) {
            callCount == 0
        })

        controller.updateNearBottom(true)
        controller.handleContentChange(
            isBusy: true,
            streamingAssistantID: "stream-1",
            bottomItemID: "bottom-1"
        ) { _ in callCount += 1 }

        #expect(await waitForMainActorCondition(timeout: .milliseconds(100)) {
            callCount == 1
        })
    }

    // MARK: - Initial Scroll & Scroll Target

    @Test func handleInitialScrollInvokesCallback() async {
        let controller = makeTestScrollController()
        controller.needsInitialScroll = true

        var targets: [String] = []
        controller.handleInitialScroll(bottomItemID: "bottom-1") { targets.append($0) }

        #expect(await waitForMainActorCondition(timeout: .milliseconds(100)) {
            targets == ["bottom-1"]
        })
        #expect(!controller.needsInitialScroll)
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

    private func makeTestScrollController() -> ChatScrollController {
        let controller = ChatScrollController()
        controller.useFastTimingForTesting()
        return controller
    }
}
