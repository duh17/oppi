@testable import OppiMac
import XCTest

@MainActor
final class OppiMacStoreTests: XCTestCase {
    func testToggleKindNeverClearsAllKinds() {
        let store = makeStore()

        // Remove all but one kind.
        for kind in ReviewTimelineKind.allCases where kind != .assistant {
            store.toggleKind(kind)
        }

        XCTAssertEqual(store.selectedKinds, [.assistant])

        // Toggling the last selected kind should no-op.
        store.toggleKind(.assistant)
        XCTAssertEqual(store.selectedKinds, [.assistant])
    }

    func testFilteredTimelineItemsRespectsKindAndSearch() {
        let store = makeStore()

        store.timelineItems = [
            ReviewTimelineItem(
                id: "a",
                kind: .assistant,
                timestamp: Date(timeIntervalSince1970: 1),
                title: "Assistant",
                preview: "Investigating ws reconnect",
                detail: "full detail",
                metadata: [:]
            ),
            ReviewTimelineItem(
                id: "b",
                kind: .toolCall,
                timestamp: Date(timeIntervalSince1970: 2),
                title: "Tool call: bash",
                preview: "npm test",
                detail: "npm test --filter reconnect",
                metadata: ["tool": "bash"]
            ),
        ]

        store.selectedKinds = [.assistant, .toolCall]
        store.timelineSearchQuery = "reconnect"

        let filtered = store.filteredTimelineItems
        XCTAssertEqual(filtered.map(\.id), ["a", "b"])

        store.selectedKinds = [.assistant]
        XCTAssertEqual(store.filteredTimelineItems.map(\.id), ["a"])

        store.timelineSearchQuery = "missing"
        XCTAssertEqual(store.filteredTimelineItems.count, 0)
    }

    func testTimelineTextScaleClampsAndPersists() {
        let suiteName = "OppiMacStoreTestsTextScale"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let store = OppiMacStore(userDefaults: defaults)
        XCTAssertEqual(store.timelineTextScale, 1.15, accuracy: 0.0001)

        store.setTimelineTextScale(2.0)
        XCTAssertEqual(store.timelineTextScale, 1.55, accuracy: 0.0001)

        store.decreaseTimelineTextScale()
        XCTAssertEqual(store.timelineTextScale, 1.50, accuracy: 0.0001)

        let reloaded = OppiMacStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.timelineTextScale, 1.50, accuracy: 0.0001)

        reloaded.setTimelineTextScale(0.2)
        XCTAssertEqual(reloaded.timelineTextScale, 0.95, accuracy: 0.0001)

        reloaded.resetTimelineTextScale()
        XCTAssertEqual(reloaded.timelineTextScale, 1.15, accuracy: 0.0001)
    }

    func testRenderedTimelineItemsUseWindowUntilExpanded() {
        let store = makeStore()

        store.timelineItems = (0..<420).map { index in
            ReviewTimelineItem(
                id: "evt-\(index)",
                kind: .assistant,
                timestamp: Date(timeIntervalSince1970: Double(index)),
                title: "Assistant",
                preview: "message \(index)",
                detail: "message detail \(index)",
                metadata: [:]
            )
        }

        let initialRenderedCount = store.renderedTimelineItems.count
        XCTAssertLessThan(initialRenderedCount, store.filteredTimelineItems.count)
        XCTAssertEqual(
            store.hiddenTimelineItemCount,
            store.filteredTimelineItems.count - initialRenderedCount
        )

        store.showEarlierTimelineItems()
        XCTAssertGreaterThan(store.renderedTimelineItems.count, initialRenderedCount)

        store.timelineSearchQuery = "message 1"
        XCTAssertEqual(store.hiddenTimelineItemCount, 0)
        XCTAssertEqual(store.renderedTimelineItems.count, store.filteredTimelineItems.count)
    }

    func testRenderedTimelineItemsIncludeSelectedOlderItem() {
        let store = makeStore()

        store.timelineItems = (0..<500).map { index in
            ReviewTimelineItem(
                id: "evt-\(index)",
                kind: .assistant,
                timestamp: Date(timeIntervalSince1970: Double(index)),
                title: "Assistant",
                preview: "message \(index)",
                detail: "message detail \(index)",
                metadata: [:]
            )
        }
        store.selectedTimelineItemID = "evt-200"

        let rendered = store.renderedTimelineItems

        XCTAssertTrue(rendered.contains(where: { $0.id == "evt-200" }))
        XCTAssertEqual(rendered.last?.id, "evt-200")
        XCTAssertLessThan(rendered.count, store.filteredTimelineItems.count)
    }

    private func makeStore() -> OppiMacStore {
        let suiteName = "OppiMacStoreTests"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return OppiMacStore(userDefaults: defaults)
    }
}
