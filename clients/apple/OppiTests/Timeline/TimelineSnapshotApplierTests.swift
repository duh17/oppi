import Foundation
import Testing
@testable import Oppi

@Suite("TimelineSnapshotApplier")
struct TimelineSnapshotApplierTests {

    private let timestamp = Date(timeIntervalSince1970: 0)

    @MainActor
    @Test func largeTimelineReconfigureIDsAreStableAndVisibleOnly() {
        let timelineIDs = (0..<620).map { "item-\($0)" }
        let nextIDs = [ChatTimelineCollectionHost.loadMoreID] + timelineIDs

        var nextItemByID: [String: ChatItem] = [:]
        var previousItemByID: [String: ChatItem] = [:]

        for id in timelineIDs {
            let stable = ChatItem.assistantMessage(
                id: id,
                text: "stable-\(id)",
                timestamp: timestamp
            )
            nextItemByID[id] = stable
            previousItemByID[id] = stable
        }

        let changedIDs = ["item-4", "item-250", "item-519"]
        for id in changedIDs {
            nextItemByID[id] = .assistantMessage(
                id: id,
                text: "updated-\(id)",
                timestamp: timestamp
            )
        }

        nextItemByID["orphan-next-only"] = .assistantMessage(
            id: "orphan-next-only",
            text: "orphan",
            timestamp: timestamp
        )
        previousItemByID["stale-removed"] = .assistantMessage(
            id: "stale-removed",
            text: "old",
            timestamp: timestamp
        )

        // item-250 is both changed AND streamingAssistantID — should appear
        // exactly once via the streaming assistant gate (changedItemIDs skips it
        // to avoid double-add; the streaming gate appends it after detecting the change).
        let reconfigureIDs = TimelineSnapshotApplier.reconfigureItemIDs(
            nextIDs: nextIDs,
            nextIDSet: Set(nextIDs),
            nextItemByID: nextItemByID,
            previousItemByID: previousItemByID,
            hiddenCount: 3,
            previousHiddenCount: 0,
            streamingAssistantID: "item-250",
            previousStreamingAssistantID: "stale-removed",
            themeChanged: false
        )

        // isStreamingMutableItem skips finalized .assistantMessage items during
        // streaming, so item-4 and item-519 are NOT detected by changedItemIDs.
        // item-250 is reconfigured via the streaming assistant gate (content changed).
        // loadMore is reconfigured because hiddenCount changed.
        let expected: Set<String> = ["item-250", ChatTimelineCollectionHost.loadMoreID]
        #expect(Set(reconfigureIDs) == expected)
        #expect(Set(reconfigureIDs).count == reconfigureIDs.count)
    }

    // MARK: - Streaming assistant gating

    @MainActor
    @Test func streamingAssistantSkippedWhenContentUnchanged() {
        let ids = ["tool-1", "assistant-1"]
        let item = ChatItem.assistantMessage(id: "assistant-1", text: "hello", timestamp: timestamp)

        let result = TimelineSnapshotApplier.reconfigureItemIDs(
            nextIDs: ids,
            nextIDSet: Set(ids),
            nextItemByID: ["tool-1": .toolCall(id: "tool-1", tool: "bash", argsSummary: "", outputPreview: "", outputByteCount: 0, isError: false, isDone: true),
                           "assistant-1": item],
            previousItemByID: ["tool-1": .toolCall(id: "tool-1", tool: "bash", argsSummary: "", outputPreview: "", outputByteCount: 0, isError: false, isDone: true),
                               "assistant-1": item],
            hiddenCount: 0,
            previousHiddenCount: 0,
            streamingAssistantID: "assistant-1",
            previousStreamingAssistantID: nil,
            themeChanged: false
        )

        // Assistant content is identical — should NOT be reconfigured.
        #expect(!result.contains("assistant-1"))
        #expect(result.isEmpty)
    }

    @MainActor
    @Test func streamingAssistantReconfiguredWhenContentChanged() {
        let ids = ["assistant-1"]
        let prev = ChatItem.assistantMessage(id: "assistant-1", text: "hel", timestamp: timestamp)
        let next = ChatItem.assistantMessage(id: "assistant-1", text: "hello world", timestamp: timestamp)

        let result = TimelineSnapshotApplier.reconfigureItemIDs(
            nextIDs: ids,
            nextIDSet: Set(ids),
            nextItemByID: ["assistant-1": next],
            previousItemByID: ["assistant-1": prev],
            hiddenCount: 0,
            previousHiddenCount: 0,
            streamingAssistantID: "assistant-1",
            previousStreamingAssistantID: nil,
            themeChanged: false
        )

        #expect(result == ["assistant-1"])
    }

    @MainActor
    @Test func streamingAssistantNewRowAlwaysReconfigured() {
        // First appearance of the assistant row — no previous entry.
        let ids = ["assistant-1"]
        let next = ChatItem.assistantMessage(id: "assistant-1", text: "hi", timestamp: timestamp)

        let result = TimelineSnapshotApplier.reconfigureItemIDs(
            nextIDs: ids,
            nextIDSet: Set(ids),
            nextItemByID: ["assistant-1": next],
            previousItemByID: [:],
            hiddenCount: 0,
            previousHiddenCount: 0,
            streamingAssistantID: "assistant-1",
            previousStreamingAssistantID: nil,
            themeChanged: false
        )

        // next != nil, prev == nil → different → reconfigure.
        #expect(result == ["assistant-1"])
    }

    @MainActor
    @Test func previousStreamingAssistantStillReconfiguredOnTransition() {
        let ids = ["assistant-1", "assistant-2"]
        let a1 = ChatItem.assistantMessage(id: "assistant-1", text: "done", timestamp: timestamp)
        let a2 = ChatItem.assistantMessage(id: "assistant-2", text: "new", timestamp: timestamp)

        let result = TimelineSnapshotApplier.reconfigureItemIDs(
            nextIDs: ids,
            nextIDSet: Set(ids),
            nextItemByID: ["assistant-1": a1, "assistant-2": a2],
            previousItemByID: ["assistant-1": a1],
            hiddenCount: 0,
            previousHiddenCount: 0,
            streamingAssistantID: "assistant-2",
            previousStreamingAssistantID: "assistant-1",
            themeChanged: false
        )

        // assistant-1 gets reconfigured because previousStreamingAssistantID changed.
        // assistant-2 gets reconfigured because it's new (not in previous).
        #expect(result.contains("assistant-1"))
        #expect(result.contains("assistant-2"))
    }

    @MainActor
    @Test func toolChangeDetectedWhileStreamingAssistantUnchanged() {
        let ids = ["tool-1", "assistant-1"]
        let assistant = ChatItem.assistantMessage(id: "assistant-1", text: "thinking...", timestamp: timestamp)
        let toolPrev = ChatItem.toolCall(id: "tool-1", tool: "bash", argsSummary: "ls", outputPreview: "", outputByteCount: 0, isError: false, isDone: false)
        let toolNext = ChatItem.toolCall(id: "tool-1", tool: "bash", argsSummary: "ls", outputPreview: "file.txt", outputByteCount: 8, isError: false, isDone: true)

        let result = TimelineSnapshotApplier.reconfigureItemIDs(
            nextIDs: ids,
            nextIDSet: Set(ids),
            nextItemByID: ["tool-1": toolNext, "assistant-1": assistant],
            previousItemByID: ["tool-1": toolPrev, "assistant-1": assistant],
            hiddenCount: 0,
            previousHiddenCount: 0,
            streamingAssistantID: "assistant-1",
            previousStreamingAssistantID: nil,
            themeChanged: false
        )

        // Tool changed, assistant did not — only tool should reconfigure.
        #expect(result == ["tool-1"])
    }

    @MainActor
    @Test func permissionChangeDetectedWhileStreamingAssistantUnchanged() {
        let ids = ["permission-1", "assistant-1"]
        let assistant = ChatItem.assistantMessage(id: "assistant-1", text: "thinking...", timestamp: timestamp)
        let request = PermissionRequest(
            id: "permission-1",
            sessionId: "s1",
            tool: "bash",
            input: [:],
            displaySummary: "rm -rf /tmp/nope",
            reason: "danger",
            timeoutAt: timestamp
        )

        let result = TimelineSnapshotApplier.reconfigureItemIDs(
            nextIDs: ids,
            nextIDSet: Set(ids),
            nextItemByID: [
                "permission-1": .permissionResolved(id: "permission-1", outcome: .allowed, tool: "bash", summary: request.displaySummary),
                "assistant-1": assistant,
            ],
            previousItemByID: [
                "permission-1": .permission(request),
                "assistant-1": assistant,
            ],
            hiddenCount: 0,
            previousHiddenCount: 0,
            streamingAssistantID: "assistant-1",
            previousStreamingAssistantID: nil,
            themeChanged: false
        )

        #expect(result == ["permission-1"])
    }

    // MARK: - Animated reconfigure filtering

    @MainActor
    @Test func loadMoreFilteredFromReconfigureWhenAnimating() {
        let changedIDs = ["item-1", ChatTimelineCollectionHost.loadMoreID, "item-2"]

        let filtered = TimelineSnapshotApplier.reconfigureIDsForAnimatedApply(
            changedIDs,
            shouldAnimate: true
        )

        #expect(filtered == ["item-1", "item-2"])
    }

    @MainActor
    @Test func loadMoreKeptInReconfigureWhenNotAnimating() {
        let changedIDs = ["item-1", ChatTimelineCollectionHost.loadMoreID, "item-2"]

        let filtered = TimelineSnapshotApplier.reconfigureIDsForAnimatedApply(
            changedIDs,
            shouldAnimate: false
        )

        #expect(filtered == ["item-1", ChatTimelineCollectionHost.loadMoreID, "item-2"])
    }
}
