import Foundation
import Testing
import UIKit
@testable import Oppi

@Suite("Tool output fetch")
struct ToolOutputFetchTests {
    @MainActor
    @Test func sessionSwitchCancelsInFlightToolOutputLoad() async {
        let harness = makeTimelineHarness(sessionId: "session-a")
        let probe = TimelineFetchProbe()

        harness.coordinator._fetchToolOutputForTesting = { _, _ in
            await probe.markStarted()
            do {
                try await Task.sleep(for: .seconds(5))
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

    @MainActor
    @Test func removedItemCancelsInFlightToolOutputLoad() async {
        let harness = makeTimelineHarness(sessionId: "session-a")
        let probe = TimelineFetchProbe()

        harness.coordinator._fetchToolOutputForTesting = { _, _ in
            await probe.markStarted()
            do {
                try await Task.sleep(for: .seconds(5))
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

    @MainActor
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

    @MainActor
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

    @MainActor
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
        #expect(await waitForTimelineCondition(timeoutMs: 3_500) {
            await MainActor.run {
                harness.toolOutputStore.fullOutput(for: toolID) == "full read output (retry)"
            }
        })
        #expect(await attempts.current() >= 2)
    }

}
