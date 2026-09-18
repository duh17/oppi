import Foundation
import Testing
import UIKit
@testable import Oppi

@Suite("Tool output fetch")
@MainActor
struct ToolOutputFetchTests {
    @Test func expandFetchPolicySkipsNetworkForHeldShellPreviewOnly() {
        #expect(
            ExpandedToolOutputFetch.shouldSkipExpandFetch(
                tool: "bash",
                hasCompleteOutput: false,
                storedPreview: "tail preview"
            )
        )
        #expect(
            ExpandedToolOutputFetch.shouldSkipExpandFetch(
                tool: "grep",
                hasCompleteOutput: false,
                storedPreview: "hit"
            )
        )
        #expect(
            !ExpandedToolOutputFetch.shouldSkipExpandFetch(
                tool: "read",
                hasCompleteOutput: false,
                storedPreview: "file body"
            )
        )
        #expect(
            !ExpandedToolOutputFetch.shouldSkipExpandFetch(
                tool: "bash",
                hasCompleteOutput: false,
                storedPreview: ""
            )
        )
        #expect(
            ExpandedToolOutputFetch.shouldSkipExpandFetch(
                tool: "read",
                hasCompleteOutput: true,
                storedPreview: "file body"
            )
        )
    }

    @Test func sidecarWindowCompletenessDrivesPreviewOnlyStorage() {
        let text = String(repeating: "a", count: 4096)
        let incomplete = ToolOutputSidecarWindow(
            text: text,
            endByteOffset: text.utf8.count,
            totalBytes: text.utf8.count + 64 * 1024
        )
        #expect(!incomplete.isComplete)
        let preview = ExpandedToolOutputFetch.Result(incomplete)
        #expect(preview.text == text)
        #expect(preview.previewOnly)
        #expect(preview.totalBytes == incomplete.totalBytes)

        let complete = ToolOutputSidecarWindow(
            text: text,
            endByteOffset: text.utf8.count,
            totalBytes: text.utf8.count
        )
        #expect(complete.isComplete)
        let stored = ExpandedToolOutputFetch.Result(complete)
        #expect(!stored.previewOnly)
        #expect(stored.totalBytes == nil)
    }

    @Test func sessionSwitchCancelsInFlightToolOutputLoad() async {
        let harness = makeTimelineHarness(sessionId: "session-a")
        let probe = TimelineFetchProbe()

        harness.coordinator._fetchToolOutputForTesting = { _, _ in
            await probe.markStarted()
            do {
                try await suspendUntilCancelledForTesting()
                return "late output"
            } catch is CancellationError {
                await probe.markCanceled()
                throw CancellationError()
            }
        }

        harness.coordinator._triggerLoadFullToolOutputForTesting(
            itemID: "tool-1",
            tool: "bash",
            outputByteCount: 128,
            in: harness.collectionView
        )

        #expect(await waitForTimelineCondition(timeoutMs: 600) {
            await MainActor.run {
                harness.coordinator._toolOutputLoadTaskCountForTesting == 1
            }
        })

        let sessionB = makeTimelineConfiguration(
            sessionId: "session-b",
            reducer: harness.reducer,
            toolOutputStore: harness.toolOutputStore,
            toolArgsStore: harness.toolArgsStore,
            connection: harness.connection,
            scrollController: harness.scrollController,
            audioPlayer: harness.audioPlayer
        )
        harness.coordinator.apply(configuration: sessionB, to: harness.collectionView)

        #expect(await waitForTimelineCondition(timeoutMs: 800) {
            let counts = await probe.snapshot()
            let taskCount = await MainActor.run {
                harness.coordinator._toolOutputLoadTaskCountForTesting
            }
            return counts.canceled == 1 && taskCount == 0
        })

        #expect(harness.coordinator._loadingToolOutputIDsForTesting.isEmpty)
        #expect(harness.toolOutputStore.fullOutput(for: "tool-1").isEmpty)
        #expect(harness.coordinator._toolOutputCanceledCountForTesting >= 1)
    }

    @Test func removedItemCancelsInFlightToolOutputLoad() async {
        let harness = makeTimelineHarness(sessionId: "session-a")
        let probe = TimelineFetchProbe()

        harness.coordinator._fetchToolOutputForTesting = { _, _ in
            await probe.markStarted()
            do {
                try await suspendUntilCancelledForTesting()
                return "late output"
            } catch is CancellationError {
                await probe.markCanceled()
                throw CancellationError()
            }
        }

        harness.coordinator._triggerLoadFullToolOutputForTesting(
            itemID: "tool-1",
            tool: "bash",
            outputByteCount: 128,
            in: harness.collectionView
        )

        #expect(await waitForTimelineCondition(timeoutMs: 600) {
            await MainActor.run {
                harness.coordinator._toolOutputLoadTaskCountForTesting == 1
            }
        })

        let removed = makeTimelineConfiguration(
            items: [],
            sessionId: "session-a",
            reducer: harness.reducer,
            toolOutputStore: harness.toolOutputStore,
            toolArgsStore: harness.toolArgsStore,
            connection: harness.connection,
            scrollController: harness.scrollController,
            audioPlayer: harness.audioPlayer
        )
        harness.coordinator.apply(configuration: removed, to: harness.collectionView)

        #expect(await waitForTimelineCondition(timeoutMs: 800) {
            let counts = await probe.snapshot()
            let taskCount = await MainActor.run {
                harness.coordinator._toolOutputLoadTaskCountForTesting
            }
            return counts.canceled == 1 && taskCount == 0
        })

        #expect(harness.coordinator._loadingToolOutputIDsForTesting.isEmpty)
        #expect(harness.toolOutputStore.fullOutput(for: "tool-1").isEmpty)
        #expect(harness.coordinator._toolOutputCanceledCountForTesting >= 1)
    }

    @Test func successfulToolOutputFetchAppendsAndClearsTaskState() async {
        let harness = makeTimelineHarness(sessionId: "session-a")

        harness.coordinator._fetchToolOutputForTesting = { _, _ in
            try await Task.sleep(for: .milliseconds(20))
            return "full output body"
        }

        harness.coordinator._triggerLoadFullToolOutputForTesting(
            itemID: "tool-1",
            tool: "bash",
            outputByteCount: 128,
            in: harness.collectionView
        )

        #expect(await waitForTimelineCondition(timeoutMs: 800) {
            await MainActor.run {
                harness.toolOutputStore.fullOutput(for: "tool-1") == "full output body"
            }
        })

        #expect(harness.coordinator._toolOutputAppliedCountForTesting == 1)
        #expect(harness.coordinator._toolOutputStaleDiscardCountForTesting == 0)
        #expect(harness.coordinator._toolOutputLoadTaskCountForTesting == 0)
        #expect(harness.coordinator._loadingToolOutputIDsForTesting.isEmpty)
    }

    @Test func previewOnlyShellOutputSkipsNetworkOnExpand() async {
        let harness = makeTimelineHarness(sessionId: "session-a")
        let toolID = "tool-shell-preview"
        let preview = "line79\nline80\n"

        harness.toolOutputStore.replace(preview, for: toolID, previewOnly: true, totalBytes: 50_000)

        let shellConfig = makeTimelineConfiguration(
            items: [
                .toolCall(
                    id: toolID,
                    tool: "bash",
                    argsSummary: "command: find /",
                    outputPreview: preview,
                    outputByteCount: 50_000,
                    isError: false,
                    isDone: true
                ),
            ],
            sessionId: "session-a",
            reducer: harness.reducer,
            toolOutputStore: harness.toolOutputStore,
            toolArgsStore: harness.toolArgsStore,
            connection: harness.connection,
            scrollController: harness.scrollController,
            audioPlayer: harness.audioPlayer
        )
        harness.coordinator.apply(configuration: shellConfig, to: harness.collectionView)

        harness.coordinator._fetchToolOutputForTesting = { _, _ in
            "SHOULD-NOT-FETCH-FULL-SIDECAR"
        }

        harness.coordinator.collectionView(
            harness.collectionView,
            didSelectItemAt: IndexPath(item: 0, section: 0)
        )

        #expect(harness.reducer.expandedItemIDs.contains(toolID))
        #expect(harness.coordinator._toolOutputLoadTaskCountForTesting == 0)
        #expect(harness.coordinator._toolOutputAppliedCountForTesting == 0)
        #expect(harness.toolOutputStore.fullOutput(for: toolID) == preview)
        #expect(harness.toolOutputStore.hasPreviewOnlyOutput(for: toolID))
        #expect(!harness.toolOutputStore.hasCompleteOutput(for: toolID))
    }

    @Test func largeBashExpandStoresFirstWindowAsPreviewOnly() async {
        let harness = makeTimelineHarness(sessionId: "session-a")
        let toolID = "tool-shell-first-window"
        let firstWindow = String(repeating: "a", count: 4096)
        let reportedBytes = ToolOutputSidecarHTTP.firstWindowBytes + 64 * 1024

        let shellConfig = makeTimelineConfiguration(
            items: [
                .toolCall(
                    id: toolID,
                    tool: "bash",
                    argsSummary: "command: python long.py",
                    outputPreview: "COMPLETE-TAIL\n",
                    outputByteCount: firstWindow.utf8.count,
                    isError: false,
                    isDone: true
                ),
            ],
            sessionId: "session-a",
            reducer: harness.reducer,
            toolOutputStore: harness.toolOutputStore,
            toolArgsStore: harness.toolArgsStore,
            connection: harness.connection,
            scrollController: harness.scrollController,
            audioPlayer: harness.audioPlayer
        )
        harness.coordinator.apply(configuration: shellConfig, to: harness.collectionView)

        harness.coordinator._fetchToolOutputForTesting = { _, _ in
            ExpandedToolOutputFetch.Result(
                text: firstWindow,
                previewOnly: true,
                totalBytes: reportedBytes
            )
        }

        harness.coordinator.collectionView(
            harness.collectionView,
            didSelectItemAt: IndexPath(item: 0, section: 0)
        )

        #expect(harness.reducer.expandedItemIDs.contains(toolID))
        #expect(await waitForTimelineCondition(timeoutMs: 800) {
            await MainActor.run {
                harness.toolOutputStore.fullOutput(for: toolID) == firstWindow
            }
        })
        #expect(harness.toolOutputStore.fullOutput(for: toolID) == firstWindow)
        #expect(harness.toolOutputStore.hasPreviewOnlyOutput(for: toolID))
        #expect(!harness.toolOutputStore.hasCompleteOutput(for: toolID))
        #expect(harness.toolOutputStore.outputByteCount(for: toolID) == reportedBytes)
    }

    @Test func readToolWithUnknownByteCountStillFetchesFullOutputOnExpand() async {
        let harness = makeTimelineHarness(sessionId: "session-a")
        let toolID = "tool-read-unknown-bytes"

        let readConfig = makeTimelineConfiguration(
            items: [
                .toolCall(
                    id: toolID,
                    tool: "read",
                    argsSummary: "path: src/main.swift",
                    outputPreview: "",
                    outputByteCount: 0,
                    isError: false,
                    isDone: true
                ),
            ],
            sessionId: "session-a",
            reducer: harness.reducer,
            toolOutputStore: harness.toolOutputStore,
            toolArgsStore: harness.toolArgsStore,
            connection: harness.connection,
            scrollController: harness.scrollController,
            audioPlayer: harness.audioPlayer
        )
        harness.coordinator.apply(configuration: readConfig, to: harness.collectionView)

        harness.coordinator._fetchToolOutputForTesting = { _, _ in
            "full read output"
        }

        harness.coordinator.collectionView(
            harness.collectionView,
            didSelectItemAt: IndexPath(item: 0, section: 0)
        )

        #expect(harness.reducer.expandedItemIDs.contains(toolID))
        #expect(await waitForTimelineCondition(timeoutMs: 600) {
            await MainActor.run {
                harness.toolOutputStore.fullOutput(for: toolID) == "full read output"
            }
        })
    }

    @Test func readToolRetriesFetchWhenStreamingInitiallyReturnsEmptyOutput() async {
        actor Attempts {
            var value = 0
            func next() -> Int {
                value += 1
                return value
            }

            func current() -> Int { value }
        }

        let harness = makeTimelineHarness(sessionId: "session-a")
        harness.coordinator._toolOutputRetryDelayForTesting = 0.001
        let toolID = "tool-read-stream-retry"
        let attempts = Attempts()

        let readConfig = makeTimelineConfiguration(
            items: [
                .toolCall(
                    id: toolID,
                    tool: "read",
                    argsSummary: "path: src/main.swift",
                    outputPreview: "",
                    outputByteCount: 0,
                    isError: false,
                    isDone: true
                ),
            ],
            isBusy: true,
            streamingAssistantID: "assistant-streaming",
            sessionId: "session-a",
            reducer: harness.reducer,
            toolOutputStore: harness.toolOutputStore,
            toolArgsStore: harness.toolArgsStore,
            connection: harness.connection,
            scrollController: harness.scrollController,
            audioPlayer: harness.audioPlayer
        )
        harness.coordinator.apply(configuration: readConfig, to: harness.collectionView)

        harness.coordinator._fetchToolOutputForTesting = { _, _ in
            let attempt = await attempts.next()
            return attempt == 1 ? "" : "full read output (retry)"
        }

        harness.coordinator.collectionView(
            harness.collectionView,
            didSelectItemAt: IndexPath(item: 0, section: 0)
        )

        #expect(harness.reducer.expandedItemIDs.contains(toolID))
        #expect(await waitForTimelineCondition(timeoutMs: 500) {
            await MainActor.run {
                harness.toolOutputStore.fullOutput(for: toolID) == "full read output (retry)"
            }
        })
        #expect(await attempts.current() >= 2)
    }

}
