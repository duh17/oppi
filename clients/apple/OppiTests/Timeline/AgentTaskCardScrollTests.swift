import Foundation
import Testing
import UIKit
@testable import Oppi

/// A subagent's chat opens on its tail with the long task brief folded at the top. Opening the
/// brief or jumping to the top is reading it: new rows below must not pull the viewport away.
@Suite("Task card holds the reader while the session works")
@MainActor
struct AgentTaskCardScrollTests {
    private static let cardID = "task-card"

    private static func taskBrief() -> String {
        (1...30).map { step in
            "\(step). Step \(step) of the brief: verify the finding before acting, keep the data rules, "
                + "never read the real database, and report what ran with the exact command and its result."
        }.joined(separator: "\n\n")
    }

    private static func makeHarness(sessionId: String) -> (TimelineScrollConformanceHarness, [ChatItem]) {
        let harness = TimelineScrollConformanceHarness(sessionId: sessionId, itemCount: 0)
        var items: [ChatItem] = [
            .agentMessage(
                id: cardID,
                text: taskBrief(),
                origin: MessageOrigin(kind: "session", sessionId: "parent", name: "Parent", intent: "task"),
                timestamp: Date()
            ),
        ]
        for index in 0..<2 {
            let id = "tool-\(index)"
            harness.windowed.toolArgsStore.set(["command": .string("echo \(index)")], for: id)
            harness.windowed.toolOutputStore.append("output \(index)", to: id)
            items.append(.toolCall(
                id: id, tool: "bash", argsSummary: "echo \(index)", outputPreview: "output \(index)",
                outputByteCount: 16, isError: false, isDone: true
            ))
        }
        harness.replaceTimelineItems(items)
        return (harness, items)
    }

    /// New tool calls arrive while the reader sits on the card, as a working child appends them.
    private static func appendToolCalls(
        _ harness: TimelineScrollConformanceHarness,
        to items: inout [ChatItem],
        rounds: Int
    ) async throws {
        for round in 0..<rounds {
            let id = "late-tool-\(round)"
            harness.windowed.toolArgsStore.set(["command": .string("echo late \(round)")], for: id)
            items.append(.toolCall(
                id: id, tool: "bash", argsSummary: "echo late \(round)", outputPreview: "",
                outputByteCount: 0, isError: false, isDone: false
            ))
            harness.replaceTimelineItems(items)
            harness.apply(isBusy: true)
            try await settleDeferredLayout()
        }
    }

    /// The timeline finishes a tap's deferred hops on later main-queue turns; a suspension lets them run.
    private static func settleDeferredLayout() async throws {
        try await Task.sleep(for: .milliseconds(60))
    }

    @Test func openingTheBriefAtTheTailHoldsItsTopWhileToolCallsArrive() async throws {
        let (harness, startItems) = Self.makeHarness(sessionId: "task-card-open-at-tail")
        var items = startItems
        harness.startAttachedAtBottom(isBusy: true)
        // The chat lands on its tail: follow is locked until the reader moves.
        harness.scrollController.requestScrollToBottom()
        #expect(harness.scrollController.isCurrentlyNearBottom)

        harness.tapTool(id: Self.cardID)
        try await Self.settleDeferredLayout()
        let cardTop = harness.screenY(of: Self.cardID, edge: .top)

        try await Self.appendToolCalls(harness, to: &items, rounds: 3)

        harness.assertAnchorStable(itemID: Self.cardID, edge: .top, before: cardTop, maxDrift: 2)
        #expect(!harness.scrollController.isCurrentlyNearBottom, "the opened brief left the live tail")
        #expect(harness.scrollController.isJumpToBottomHintVisible)
    }

    @Test func statusBarJumpToTheBriefHoldsItWhileToolCallsArrive() async throws {
        let (harness, startItems) = Self.makeHarness(sessionId: "task-card-status-bar")
        var items = startItems
        harness.reducer.expandedItemIDs.insert(Self.cardID)
        harness.startAttachedAtBottom(isBusy: true)

        // A status-bar tap animates to the top: UIKit reports no drag, then calls back once there.
        let collectionView = harness.collectionView
        let start = collectionView.contentOffset.y
        let top = -collectionView.adjustedContentInset.top
        for step in 1...10 {
            collectionView.contentOffset.y = start + (top - start) * CGFloat(step) / 10
            harness.coordinator.scrollViewDidScroll(collectionView)
        }
        harness.coordinator.scrollViewDidScrollToTop(collectionView)
        try await Self.settleDeferredLayout()
        let cardTop = harness.screenY(of: Self.cardID, edge: .top)

        try await Self.appendToolCalls(harness, to: &items, rounds: 3)

        harness.assertAnchorStable(itemID: Self.cardID, edge: .top, before: cardTop, maxDrift: 2)
        #expect(!harness.scrollController.isCurrentlyNearBottom)
    }
}
