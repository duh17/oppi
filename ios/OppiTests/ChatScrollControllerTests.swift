import Testing
import Foundation
import UIKit
@testable import Oppi

@Suite("ChatScrollController")
struct ChatScrollControllerTests {

    @MainActor
    @Test func initialState() {
        let controller = ChatScrollController()
        #expect(controller.scrollTargetID == nil)
        #expect(!controller.needsInitialScroll)
        #expect(controller.isCurrentlyNearBottom)
    }

    @MainActor
    @Test func cancelIsSafe() {
        let controller = ChatScrollController()
        controller.cancel()
        controller.cancel() // idempotent
    }

    @MainActor
    @Test func scrollTargetIDReset() {
        let controller = ChatScrollController()
        controller.scrollTargetID = "item-42"
        #expect(controller.scrollTargetID == "item-42")
        controller.scrollTargetID = nil
        #expect(controller.scrollTargetID == nil)
    }

    @MainActor
    @Test func needsInitialScrollToggle() {
        let controller = ChatScrollController()
        #expect(!controller.needsInitialScroll)
        controller.needsInitialScroll = true
        #expect(controller.needsInitialScroll)
    }

    // MARK: - Near-Bottom State

    @MainActor
    @Test func updateNearBottomTracksState() {
        let controller = ChatScrollController()
        #expect(controller.isCurrentlyNearBottom)

        controller.updateNearBottom(false)
        #expect(!controller.isCurrentlyNearBottom)

        controller.updateNearBottom(true)
        #expect(controller.isCurrentlyNearBottom)
    }

    @MainActor
    @Test func topVisibleItemIdTracksState() {
        let controller = ChatScrollController()
        #expect(controller.currentTopVisibleItemId == nil)

        controller.updateTopVisibleItemId("item-7")
        #expect(controller.currentTopVisibleItemId == "item-7")

        controller.updateTopVisibleItemId(nil)
        #expect(controller.currentTopVisibleItemId == nil)
    }

    // MARK: - Hint Visibility

    @MainActor
    @Test func detachedStreamingHintVisibility() {
        let controller = ChatScrollController()
        #expect(!controller.isDetachedStreamingHintVisible)

        controller.setDetachedStreamingHintVisible(true)
        #expect(controller.isDetachedStreamingHintVisible)

        controller.setDetachedStreamingHintVisible(false)
        #expect(!controller.isDetachedStreamingHintVisible)
    }

    @MainActor
    @Test func jumpToBottomHintVisibility() {
        let controller = ChatScrollController()
        #expect(!controller.isJumpToBottomHintVisible)

        controller.setJumpToBottomHintVisible(true)
        #expect(controller.isJumpToBottomHintVisible)

        controller.setJumpToBottomHintVisible(false)
        #expect(!controller.isJumpToBottomHintVisible)
    }

    // MARK: - handleContentChange

    @MainActor
    @Test func handleContentChangeScrollsToStreamingTarget() async {
        let controller = ChatScrollController()
        controller.updateNearBottom(true)

        var targets: [String] = []
        controller.handleContentChange(
            isBusy: true,
            streamingAssistantID: "stream-1",
            bottomItemID: "bottom-1"
        ) { targets.append($0) }

        try? await Task.sleep(for: .milliseconds(120))
        #expect(targets == ["stream-1"])
    }

    @MainActor
    @Test func handleContentChangeScrollsToBottomWhenNoStreaming() async {
        let controller = ChatScrollController()
        controller.updateNearBottom(true)

        var targets: [String] = []
        controller.handleContentChange(
            isBusy: true,
            streamingAssistantID: nil,
            bottomItemID: "bottom-1"
        ) { targets.append($0) }

        try? await Task.sleep(for: .milliseconds(120))
        #expect(targets == ["bottom-1"])
    }

    @MainActor
    @Test func handleContentChangeSkipsWhenNotNearBottom() async {
        let controller = ChatScrollController()
        controller.updateNearBottom(false)

        var callCount = 0
        controller.handleContentChange(
            isBusy: true,
            streamingAssistantID: "stream-1",
            bottomItemID: "bottom-1"
        ) { _ in callCount += 1 }

        try? await Task.sleep(for: .milliseconds(120))
        #expect(callCount == 0)
    }

    @MainActor
    @Test func handleContentChangeHeavyTimelineFollowsWhenBusy() async {
        let controller = ChatScrollController()
        controller.updateNearBottom(true)
        controller.itemCount = 240

        var targets: [String] = []
        controller.handleContentChange(
            isBusy: true,
            streamingAssistantID: "stream-1",
            bottomItemID: "bottom-1"
        ) { targets.append($0) }

        try? await Task.sleep(for: .milliseconds(200))
        #expect(targets == ["stream-1"])
    }

    @MainActor
    @Test func handleContentChangeHeavyTimelineSkipsWhenIdle() async {
        let controller = ChatScrollController()
        controller.updateNearBottom(true)
        controller.itemCount = 240

        var callCount = 0
        controller.handleContentChange(
            isBusy: false,
            streamingAssistantID: nil,
            bottomItemID: "bottom-1"
        ) { _ in callCount += 1 }

        try? await Task.sleep(for: .milliseconds(200))
        #expect(callCount == 0)
    }

    @MainActor
    @Test func handleContentChangeSkipsDuringKeyboardTransition() async {
        let controller = ChatScrollController()
        controller.updateNearBottom(true)

        NotificationCenter.default.post(name: UIResponder.keyboardWillShowNotification, object: nil)
        await Task.yield()

        var callCount = 0
        controller.handleContentChange(
            isBusy: true,
            streamingAssistantID: "stream-1",
            bottomItemID: "bottom-1"
        ) { _ in callCount += 1 }

        try? await Task.sleep(for: .milliseconds(140))
        #expect(callCount == 0)

        // After keyboard settles
        try? await Task.sleep(for: .milliseconds(520))
        controller.handleContentChange(
            isBusy: true,
            streamingAssistantID: "stream-1",
            bottomItemID: "bottom-1"
        ) { _ in callCount += 1 }

        try? await Task.sleep(for: .milliseconds(140))
        #expect(callCount == 1)
    }

    @MainActor
    @Test func handleContentChangeRechecksKeyboardBeforeDelayedScroll() async {
        let controller = ChatScrollController()
        controller.updateNearBottom(true)

        var callCount = 0
        controller.handleContentChange(
            isBusy: true,
            streamingAssistantID: "stream-1",
            bottomItemID: "bottom-1"
        ) { _ in callCount += 1 }

        // Fire keyboard mid-delay
        try? await Task.sleep(for: .milliseconds(10))
        NotificationCenter.default.post(name: UIResponder.keyboardWillShowNotification, object: nil)
        await Task.yield()

        try? await Task.sleep(for: .milliseconds(140))
        #expect(callCount == 0)
    }

    @MainActor
    @Test func handleContentChangeSkipsDuringUserInteraction() async {
        let controller = ChatScrollController()
        controller.updateNearBottom(true)
        controller.setUserInteracting(true)

        var callCount = 0
        controller.handleContentChange(
            isBusy: true,
            streamingAssistantID: "stream-1",
            bottomItemID: "bottom-1"
        ) { _ in callCount += 1 }

        try? await Task.sleep(for: .milliseconds(120))
        #expect(callCount == 0)
    }

    @MainActor
    @Test func handleContentChangeCancelsPendingScrollWhenUserStartsInteracting() async {
        let controller = ChatScrollController()
        controller.updateNearBottom(true)

        var callCount = 0
        controller.handleContentChange(
            isBusy: true,
            streamingAssistantID: "stream-1",
            bottomItemID: "bottom-1"
        ) { _ in callCount += 1 }

        try? await Task.sleep(for: .milliseconds(10))
        controller.setUserInteracting(true)

        try? await Task.sleep(for: .milliseconds(120))
        #expect(callCount == 0)

        controller.setUserInteracting(false)
        controller.handleContentChange(
            isBusy: true,
            streamingAssistantID: "stream-1",
            bottomItemID: "bottom-1"
        ) { _ in callCount += 1 }

        try? await Task.sleep(for: .milliseconds(120))
        #expect(callCount == 1)
    }

    @MainActor
    @Test func detachFromBottomForUserScrollRequiresReentry() async {
        let controller = ChatScrollController()
        controller.updateNearBottom(true)
        controller.detachFromBottomForUserScroll()

        var callCount = 0
        controller.handleContentChange(
            isBusy: true,
            streamingAssistantID: "stream-1",
            bottomItemID: "bottom-1"
        ) { _ in callCount += 1 }

        try? await Task.sleep(for: .milliseconds(120))
        #expect(callCount == 0)

        controller.updateNearBottom(true)
        controller.handleContentChange(
            isBusy: true,
            streamingAssistantID: "stream-1",
            bottomItemID: "bottom-1"
        ) { _ in callCount += 1 }

        try? await Task.sleep(for: .milliseconds(120))
        #expect(callCount == 1)
    }

    // MARK: - Initial Scroll & Scroll Target

    @MainActor
    @Test func handleInitialScrollInvokesCallback() async {
        let controller = ChatScrollController()
        controller.needsInitialScroll = true

        var targets: [String] = []
        controller.handleInitialScroll(bottomItemID: "bottom-1") { targets.append($0) }

        try? await Task.sleep(for: .milliseconds(180))
        #expect(targets == ["bottom-1"])
        #expect(!controller.needsInitialScroll)
    }

    @MainActor
    @Test func handleScrollTargetInvokesCallbackAndResetsTarget() async {
        let controller = ChatScrollController()
        controller.scrollTargetID = "target-1"

        var targets: [String] = []
        controller.handleScrollTarget { targets.append($0) }

        try? await Task.sleep(for: .milliseconds(220))
        #expect(targets == ["target-1"])
        #expect(controller.scrollTargetID == nil)
    }

    // MARK: - requestScrollToBottom

    @MainActor
    @Test func requestScrollToBottomReattachesAndClearsHints() {
        let controller = ChatScrollController()
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

    @MainActor
    @Test func requestScrollToBottomLocksFollowUntilUserScrollsUp() {
        let controller = ChatScrollController()

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
}
