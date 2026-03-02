import Foundation
import Testing
@testable import Oppi

@Suite("Tool inline expansion state")
struct ToolInlineExpansionStateTests {
    @MainActor
    @Test func toggleCallbackPromotesInlineExpansionLevelToExpanded() throws {
        let harness = makeWindowedTimelineHarness(sessionId: "s-inline-toggle")
        let output = (1...260).map { "line-\($0)" }.joined(separator: "\n")
        let item = makeToolItem(id: "tool-inline-1", output: output)

        harness.toolOutputStore.append(output, to: item.id)
        harness.applyItems([item], isBusy: false)

        let indexPath = IndexPath(item: 0, section: 0)
        harness.coordinator.collectionView(harness.collectionView, didSelectItemAt: indexPath)
        settleTimelineLayout(harness.collectionView)

        let compactConfig = try #require(
            harness.coordinator.toolRowConfiguration(itemID: item.id, item: item)
        )
        #expect(compactConfig.inlineExpansionLevel == .compact)

        let toggle = try #require(compactConfig.onToggleInlineExpansion)
        toggle()
        settleTimelineLayout(harness.collectionView)

        let expandedConfig = try #require(
            harness.coordinator.toolRowConfiguration(itemID: item.id, item: item)
        )
        #expect(expandedConfig.inlineExpansionLevel == .expanded)
    }

    @MainActor
    @Test func collapsingAndReexpandingResetsInlineExpansionLevelToCompact() throws {
        let harness = makeWindowedTimelineHarness(sessionId: "s-inline-reset")
        let output = (1...260).map { "line-\($0)" }.joined(separator: "\n")
        let item = makeToolItem(id: "tool-inline-2", output: output)

        harness.toolOutputStore.append(output, to: item.id)
        harness.applyItems([item], isBusy: false)

        let indexPath = IndexPath(item: 0, section: 0)

        // Expand and promote to expanded inline level.
        harness.coordinator.collectionView(harness.collectionView, didSelectItemAt: indexPath)
        settleTimelineLayout(harness.collectionView)
        let firstConfig = try #require(
            harness.coordinator.toolRowConfiguration(itemID: item.id, item: item)
        )
        let firstToggle = try #require(firstConfig.onToggleInlineExpansion)
        firstToggle()
        settleTimelineLayout(harness.collectionView)

        let promotedConfig = try #require(
            harness.coordinator.toolRowConfiguration(itemID: item.id, item: item)
        )
        #expect(promotedConfig.inlineExpansionLevel == .expanded)

        // Collapse row.
        harness.coordinator.collectionView(harness.collectionView, didSelectItemAt: indexPath)
        settleTimelineLayout(harness.collectionView)
        #expect(!harness.reducer.expandedItemIDs.contains(item.id))

        // Re-expand row: inline level should restart at compact.
        harness.coordinator.collectionView(harness.collectionView, didSelectItemAt: indexPath)
        settleTimelineLayout(harness.collectionView)

        let resetConfig = try #require(
            harness.coordinator.toolRowConfiguration(itemID: item.id, item: item)
        )
        #expect(resetConfig.inlineExpansionLevel == .compact)
    }

    @MainActor
    private func makeToolItem(id: String, output: String) -> ChatItem {
        .toolCall(
            id: id,
            tool: "remember",
            argsSummary: "text: example",
            outputPreview: "line-1",
            outputByteCount: output.utf8.count,
            isError: false,
            isDone: true
        )
    }
}
