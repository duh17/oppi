import Testing
import Foundation
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
}
