import Foundation
import Testing
@testable import Oppi

@Suite("Scroll stress scenarios")
struct ScrollStressTests {
    @MainActor
    @Test
    func rapidStreamingWhileScrolledUp() {
        var harness = ScrollPropertyTestHarness(sessionId: "scroll-stress-stream")

        harness.applyEvent(.fullReload(newItems: ScrollPropertyFixtures.baselineItems(count: 36)))
        harness.applyEvent(.scrollUp(distance: 420))
        #expect(!harness.scrollController.isCurrentlyNearBottom)

        harness.applyEvent(.startStreaming(assistantID: "stream-rapid"))

        for index in 0..<30 {
            harness.applyEvent(
                .appendItems([
                    .assistantMessage(
                        id: "delta-\(index)",
                        text: "token \(index)",
                        timestamp: Date(timeIntervalSince1970: TimeInterval(index))
                    ),
                ])
            )
        }

        #expect(!harness.scrollController.isCurrentlyNearBottom)
        harness.assertNoScrollCommandStorms()
    }

    @MainActor
    @Test
    func expandToolAtVisibleBoundaryDuringStreaming() {
        var harness = ScrollPropertyTestHarness(sessionId: "scroll-stress-expand")

        let toolItems = ScrollPropertyFixtures.toolItems(count: 20, prefix: "tool")
        harness.applyEvent(.fullReload(newItems: toolItems))
        harness.applyEvent(.scrollUp(distance: 600))
        #expect(!harness.scrollController.isCurrentlyNearBottom)

        harness.applyEvent(.startStreaming(assistantID: "stream-expand"))
        harness.applyEvent(.expandTool(itemID: "tool-10"))

        for index in 0..<10 {
            harness.applyEvent(
                .appendItems([
                    .assistantMessage(
                        id: "stream-\(index)",
                        text: "tok \(index)",
                        timestamp: Date(timeIntervalSince1970: TimeInterval(index + 100))
                    ),
                ])
            )
        }

        harness.assertNoScrollCommandStorms()
    }

    @MainActor
    @Test
    func fullReloadWhileDetachedAtSpecificItem() {
        var harness = ScrollPropertyTestHarness(sessionId: "scroll-stress-reload")

        let initialItems = ScrollPropertyFixtures.assistantItems(count: 30, prefix: "msg")
        harness.applyEvent(.fullReload(newItems: initialItems))
        harness.applyEvent(.scrollUp(distance: 500))
        #expect(!harness.scrollController.isCurrentlyNearBottom)

        let updatedItems = ScrollPropertyFixtures.assistantItems(count: 40, prefix: "updated")
        harness.applyEvent(.fullReload(newItems: updatedItems))

        #expect(!harness.scrollController.isCurrentlyNearBottom)
        harness.assertNoScrollCommandStorms()
    }

    @MainActor
    @Test
    func backgroundForegroundCycleDuringDetachedStreaming() {
        var harness = ScrollPropertyTestHarness(sessionId: "scroll-stress-lifecycle")

        harness.applyEvent(.fullReload(newItems: ScrollPropertyFixtures.baselineItems(count: 24)))
        harness.applyEvent(.scrollUp(distance: 360))
        harness.applyEvent(.startStreaming(assistantID: "stream-bg"))
        #expect(!harness.scrollController.isCurrentlyNearBottom)

        var accumulatedItems = harness.currentItems
        for index in 0..<20 {
            accumulatedItems.append(
                .assistantMessage(
                    id: "bg-\(index)",
                    text: "background token \(index)",
                    timestamp: Date(timeIntervalSince1970: TimeInterval(index + 1_000))
                )
            )
        }

        harness.applyEvent(.fullReload(newItems: accumulatedItems))

        #expect(!harness.scrollController.isCurrentlyNearBottom)
        harness.assertNoScrollCommandStorms()
    }
}
