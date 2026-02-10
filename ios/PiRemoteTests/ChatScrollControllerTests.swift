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
}
