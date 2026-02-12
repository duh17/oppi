import Testing
import Foundation
import UIKit
@testable import PiRemote

@Suite("ChatScrollController")
struct ChatScrollControllerTests {

    @MainActor
    @Test func initialState() {
        let controller = ChatScrollController()
        #expect(controller.scrollTargetID == nil)
        #expect(!controller.needsInitialScroll)
    }

    @MainActor
    @Test func sentinelCallbacksUpdateAnchor() {
        // Sentinel callbacks are fire-and-forget — just verify no crash
        let controller = ChatScrollController()
        controller.onSentinelAppear()
        controller.onSentinelDisappear()
        controller.onSentinelAppear()
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

        // In real use, handleScrollTarget resets it — test the property directly
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

    // MARK: - Scroll Position Tracking

    @MainActor
    @Test func scrollPositionBindingTracksTopVisibleItem() {
        let controller = ChatScrollController()
        #expect(controller.currentTopVisibleItemId == nil)

        // Simulate scrollPosition(id:) setter firing as user scrolls
        controller.scrollPositionBinding.wrappedValue = "item-42"
        #expect(controller.currentTopVisibleItemId == "item-42")

        controller.scrollPositionBinding.wrappedValue = "item-99"
        #expect(controller.currentTopVisibleItemId == "item-99")

        // nil when scrolled past all identified items
        controller.scrollPositionBinding.wrappedValue = nil
        #expect(controller.currentTopVisibleItemId == nil)
    }

    @MainActor
    @Test func isCurrentlyNearBottomReflectsSentinel() {
        let controller = ChatScrollController()

        // Default: near bottom (sentinel visible by default assumption)
        #expect(controller.isCurrentlyNearBottom)

        controller.onSentinelDisappear()
        #expect(!controller.isCurrentlyNearBottom)

        controller.onSentinelAppear()
        #expect(controller.isCurrentlyNearBottom)
    }

    @MainActor
    @Test func scrollPositionBindingGetReturnsCurrentValue() {
        let controller = ChatScrollController()

        // Write through set, read through get — verify round-trip
        controller.scrollPositionBinding.wrappedValue = "msg-123"
        let readBack = controller.scrollPositionBinding.wrappedValue
        #expect(readBack == "msg-123")
    }

    // MARK: - Collection-backed callbacks

    @MainActor
    @Test func collectionBackendUpdatesAnchorState() {
        let controller = ChatScrollController()

        controller.updateNearBottom(false)
        #expect(!controller.isCurrentlyNearBottom)

        controller.updateTopVisibleItemId("item-7")
        #expect(controller.currentTopVisibleItemId == "item-7")
    }

    @MainActor
    @Test func detachedStreamingHintVisibilityIsMutable() {
        let controller = ChatScrollController()
        #expect(!controller.isDetachedStreamingHintVisible)

        controller.setDetachedStreamingHintVisible(true)
        #expect(controller.isDetachedStreamingHintVisible)

        controller.setDetachedStreamingHintVisible(false)
        #expect(!controller.isDetachedStreamingHintVisible)
    }

    @MainActor
    @Test func jumpToBottomHintVisibilityIsMutable() {
        let controller = ChatScrollController()
        #expect(!controller.isJumpToBottomHintVisible)

        controller.setJumpToBottomHintVisible(true)
        #expect(controller.isJumpToBottomHintVisible)

        controller.setJumpToBottomHintVisible(false)
        #expect(!controller.isJumpToBottomHintVisible)
    }

    @MainActor
    @Test func handleRenderVersionChangeUsesStreamingTarget() async {
        let controller = ChatScrollController()
        controller.updateNearBottom(true)

        var targets: [String] = []
        controller.handleRenderVersionChange(
            streamingID: "stream-1",
            bottomItemID: "bottom-1"
        ) { targetID in
            targets.append(targetID)
        }

        try? await Task.sleep(for: .milliseconds(120))
        #expect(targets == ["stream-1"])
    }

    @MainActor
    @Test func handleRenderVersionChangeUsesBottomTarget() async {
        let controller = ChatScrollController()
        controller.updateNearBottom(true)

        var targets: [String] = []
        controller.handleRenderVersionChange(
            streamingID: nil,
            bottomItemID: "bottom-1"
        ) { targetID in
            targets.append(targetID)
        }

        try? await Task.sleep(for: .milliseconds(120))
        #expect(targets == ["bottom-1"])
    }

    @MainActor
    @Test func handleRenderVersionChangeSkipsWhenNotNearBottom() async {
        let controller = ChatScrollController()
        controller.updateNearBottom(false)

        var callCount = 0
        controller.handleRenderVersionChange(
            streamingID: "stream-1",
            bottomItemID: "bottom-1"
        ) { _ in
            callCount += 1
        }

        try? await Task.sleep(for: .milliseconds(120))
        #expect(callCount == 0)
    }

    @MainActor
    @Test func handleRenderVersionChangeHeavyTimelineKeepsStreamingFollow() async {
        let controller = ChatScrollController()
        controller.updateNearBottom(true)
        controller._diagnosticItemCount = 240

        var targets: [String] = []
        controller.handleRenderVersionChange(
            streamingID: "stream-1",
            bottomItemID: "bottom-1"
        ) { targetID in
            targets.append(targetID)
        }

        try? await Task.sleep(for: .milliseconds(200))
        #expect(targets == ["stream-1"])
    }

    @MainActor
    @Test func handleRenderVersionChangeHeavyTimelineSkipsNonStreamingScroll() async {
        let controller = ChatScrollController()
        controller.updateNearBottom(true)
        controller._diagnosticItemCount = 240

        var callCount = 0
        controller.handleRenderVersionChange(
            streamingID: nil,
            bottomItemID: "bottom-1"
        ) { _ in
            callCount += 1
        }

        try? await Task.sleep(for: .milliseconds(200))
        #expect(callCount == 0)
    }

    @MainActor
    @Test func handleRenderVersionChangeSkipsDuringKeyboardTransition() async {
        let controller = ChatScrollController()
        controller.updateNearBottom(true)

        NotificationCenter.default.post(name: UIResponder.keyboardWillShowNotification, object: nil)
        await Task.yield()

        var callCount = 0
        controller.handleRenderVersionChange(
            streamingID: "stream-1",
            bottomItemID: "bottom-1"
        ) { _ in
            callCount += 1
        }

        try? await Task.sleep(for: .milliseconds(140))
        #expect(callCount == 0)

        try? await Task.sleep(for: .milliseconds(520))
        controller.handleRenderVersionChange(
            streamingID: "stream-1",
            bottomItemID: "bottom-1"
        ) { _ in
            callCount += 1
        }

        try? await Task.sleep(for: .milliseconds(140))
        #expect(callCount == 1)
    }

    @MainActor
    @Test func handleRenderVersionChangeRechecksKeyboardBeforeDelayedScroll() async {
        let controller = ChatScrollController()
        controller.updateNearBottom(true)

        var callCount = 0
        controller.handleRenderVersionChange(
            streamingID: "stream-1",
            bottomItemID: "bottom-1"
        ) { _ in
            callCount += 1
        }

        try? await Task.sleep(for: .milliseconds(10))
        NotificationCenter.default.post(name: UIResponder.keyboardWillShowNotification, object: nil)
        await Task.yield()

        try? await Task.sleep(for: .milliseconds(140))
        #expect(callCount == 0)
    }

    @MainActor
    @Test func handleRenderVersionChangeSkipsDuringUserInteraction() async {
        let controller = ChatScrollController()
        controller.updateNearBottom(true)
        controller.setUserInteracting(true)

        var callCount = 0
        controller.handleRenderVersionChange(
            streamingID: "stream-1",
            bottomItemID: "bottom-1"
        ) { _ in
            callCount += 1
        }

        try? await Task.sleep(for: .milliseconds(120))
        #expect(callCount == 0)
    }

    @MainActor
    @Test func handleRenderVersionChangeCancelsPendingScrollWhenUserStartsInteracting() async {
        let controller = ChatScrollController()
        controller.updateNearBottom(true)

        var callCount = 0
        controller.handleRenderVersionChange(
            streamingID: "stream-1",
            bottomItemID: "bottom-1"
        ) { _ in
            callCount += 1
        }

        try? await Task.sleep(for: .milliseconds(10))
        controller.setUserInteracting(true)

        try? await Task.sleep(for: .milliseconds(120))
        #expect(callCount == 0)

        controller.setUserInteracting(false)
        controller.handleRenderVersionChange(
            streamingID: "stream-1",
            bottomItemID: "bottom-1"
        ) { _ in
            callCount += 1
        }

        try? await Task.sleep(for: .milliseconds(120))
        #expect(callCount == 1)
    }

    @MainActor
    @Test func detachFromBottomForUserScrollRequiresReentry() async {
        let controller = ChatScrollController()
        controller.updateNearBottom(true)
        controller.detachFromBottomForUserScroll()

        var callCount = 0
        controller.handleRenderVersionChange(
            streamingID: "stream-1",
            bottomItemID: "bottom-1"
        ) { _ in
            callCount += 1
        }

        try? await Task.sleep(for: .milliseconds(120))
        #expect(callCount == 0)

        controller.updateNearBottom(true)
        controller.handleRenderVersionChange(
            streamingID: "stream-1",
            bottomItemID: "bottom-1"
        ) { _ in
            callCount += 1
        }

        try? await Task.sleep(for: .milliseconds(120))
        #expect(callCount == 1)
    }

    @MainActor
    @Test func handleInitialScrollInvokesCallback() async {
        let controller = ChatScrollController()
        controller.needsInitialScroll = true

        var targets: [String] = []
        controller.handleInitialScroll(bottomItemID: "bottom-1") { targetID in
            targets.append(targetID)
        }

        try? await Task.sleep(for: .milliseconds(180))
        #expect(targets == ["bottom-1"])
        #expect(!controller.needsInitialScroll)
    }

    @MainActor
    @Test func handleScrollTargetInvokesCallbackAndResetsTarget() async {
        let controller = ChatScrollController()
        controller.scrollTargetID = "target-1"

        var targets: [String] = []
        controller.handleScrollTarget { targetID in
            targets.append(targetID)
        }

        try? await Task.sleep(for: .milliseconds(220))
        #expect(targets == ["target-1"])
        #expect(controller.scrollTargetID == nil)
    }
}
