import Foundation
import Testing
@testable import Oppi

@Suite("Scroll invariant property tests")
struct ScrollInvariantPropertyTests {
    @MainActor
    @Test(arguments: [
        UInt64(0),
        UInt64(42),
        UInt64(1337),
        UInt64(9999),
        UInt64(12345),
    ])
    func allInvariantsHoldAcrossRandomSequence(seed: UInt64) {
        var generator = TimelineEventGenerator(seed: seed)
        var harness = ScrollPropertyTestHarness(sessionId: "scroll-prop-\(seed)")

        let events = generator.generateSequence(
            count: 100,
            initialItemCount: harness.currentItems.count
        )

        for event in events {
            harness.applyEvent(event)
        }

        harness.assertNoScrollCommandStorms()
    }

    @MainActor
    @Test(arguments: [UInt64(100), UInt64(200)])
    func heavyTimelinePreservesInvariants(seed: UInt64) {
        var generator = TimelineEventGenerator(seed: seed)
        var harness = ScrollPropertyTestHarness(sessionId: "scroll-heavy-\(seed)")

        let initialItems = ScrollPropertyFixtures.assistantItems(count: 150, prefix: "heavy")
        harness.applyEvent(.fullReload(newItems: initialItems))

        let events = generator.generateSequence(
            count: 80,
            initialItemCount: initialItems.count
        )

        for event in events {
            harness.applyEvent(event)
        }

        harness.assertNoScrollCommandStorms()
    }
}
