import Foundation
import Observation
import SwiftUI
import Testing
import UIKit
@testable import Oppi

@Suite("Chat timeline UIKit-owned clock")
@MainActor
struct ChatTimelineOwnedClockTests {
    @Test func terminalPaintReconfiguresRowWhenPreviewIsUnchanged() async throws {
        let fixture = makeHostedOwnedTimeline(isBusy: true)
        defer { fixture.tearDown() }
        fixture.reducer.expandedItemIDs.insert("terminal")
        fixture.reducer.processBatch([
            .agentStart(sessionId: fixture.sessionId),
            .textDelta(sessionId: fixture.sessionId, delta: "Hello"),
            .toolStart(sessionId: fixture.sessionId, toolEventId: "terminal", tool: "bash", args: ["command": .string("emit")],
                outputPresentation: .init(kind: "terminal")),
            .toolOutput(.init(sessionId: fixture.sessionId, toolEventId: "terminal", output: "ready\n", isError: false,
                outputStream: .init(epoch: 1, offset: 0, bytes: 6)))
        ])
        let owner = try #require(fixture.reducer.terminalOutputStreams.owner(for: "terminal"))
        #expect(await waitForTimelineCondition(timeoutMs: 1_000) {
            await MainActor.run {
                fixture.host.view.layoutIfNeeded()
                func ready(in view: UIView) -> Bool {
                    if let text = view as? UITextView, text.textStorage.string.contains("ready") { return true }
                    return view.subviews.contains { ready(in: $0) }
                }
                return ready(in: fixture.host.view)
            }
        })
        let before = fixture.reducer.items
        owner.markReconnecting()
        // The canonical ChatItem need not change when only recovery state changes.
        #expect(fixture.reducer.items == before)
        #expect(await waitForTimelineCondition(timeoutMs: 1_000) {
            await MainActor.run {
                fixture.host.view.layoutIfNeeded()
                func notice(in view: UIView) -> Bool {
                    if let label = view as? UILabel, !label.isHidden, label.text == "Resyncing terminal output…" { return true }
                    return view.subviews.contains { notice(in: $0) }
                }
                return notice(in: fixture.host.view)
            }
        })
        let prefix = String(repeating: "x extra long\n", count: 1200)
        fixture.reducer.process(.toolOutput(.init(sessionId: fixture.sessionId, toolEventId: "terminal", output: prefix,
            isError: false, outputStream: .init(epoch: 1, offset: 6, bytes: prefix.utf8.count))))
        #expect(await waitForTimelineCondition(timeoutMs: 1_000) {
            await MainActor.run { Self.containsTerminalText("x extra long\nx extra long", in: fixture.host.view) }
        })
        let tail = "last line\n"
        fixture.reducer.process(.toolOutput(.init(sessionId: fixture.sessionId, toolEventId: "terminal", output: tail,
            isError: false, outputStream: .init(epoch: 1, offset: 6 + prefix.utf8.count, bytes: tail.utf8.count))))
        #expect(await waitForTimelineCondition(timeoutMs: 1_000) {
            await MainActor.run {
                fixture.host.view.layoutIfNeeded()
                guard let row = Self.terminalRow(in: fixture.host.view) else { return false }
                return Self.containsTerminalText(tail, in: row)
                    && ToolTimelineRowUIHelpers.isNearBottom(row.bashToolRowView.outputScrollView)
                    && row.bashToolRowView.outputScrollView.contentOffset.y > 0
            }
        })
        let row = try #require(Self.terminalRow(in: fixture.host.view))
        let scroll = row.bashToolRowView.outputScrollView
        scroll.draggingOverrideForTesting = true
        scroll.delegate?.scrollViewWillBeginDragging?(scroll)
        // The first incremental movement is still inside the near-tail threshold.
        let draggedY = scroll.contentOffset.y - 8
        scroll.setContentOffset(CGPoint(x: 0, y: draggedY), animated: false)
        row.bashToolRowView.scrollViewDidScroll(scroll)
        #expect(ToolTimelineRowUIHelpers.isNearBottom(scroll))
        #expect(!row.bashToolRowView.outputShouldAutoFollow)
        let revisionBeforeDetachedPaint = owner.presentationRevision
        fixture.reducer.process(.toolOutput(.init(sessionId: fixture.sessionId, toolEventId: "terminal", output: "detached tail\n",
            isError: false, outputStream: .init(epoch: 1, offset: owner.cursor, bytes: 14))))
        #expect(await waitForTimelineCondition(timeoutMs: 1_000) {
            await MainActor.run { owner.presentationRevision != revisionBeforeDetachedPaint && owner.formatted.contains("detached tail") }
        })
        fixture.host.view.layoutIfNeeded()
        // A detached reader's text stays still: the paint is withheld, not laid out.
        #expect(!Self.containsTerminalText("detached tail", in: row))
        #expect(abs(scroll.contentOffset.y - draggedY) < 1,
            "A streamed paint during an incremental tail drag must keep the viewport")
        scroll.draggingOverrideForTesting = false
        scroll.deceleratingOverrideForTesting = true
        scroll.delegate?.scrollViewDidEndDragging?(scroll, willDecelerate: true)
        scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height - 4), animated: false)
        row.bashToolRowView.scrollViewDidScroll(scroll)
        #expect(!row.bashToolRowView.outputShouldAutoFollow)
        scroll.deceleratingOverrideForTesting = false
        scroll.delegate?.scrollViewDidEndDecelerating?(scroll)
        #expect(row.bashToolRowView.outputShouldAutoFollow)
        // Settling at the tail paints the withheld snapshot without waiting for more bytes.
        #expect(await waitForTimelineCondition(timeoutMs: 1_000) {
            await MainActor.run {
                fixture.host.view.layoutIfNeeded()
                return Self.containsTerminalText("detached tail", in: row)
            }
        })
    }

    private static func terminalRow(in view: UIView) -> ToolTimelineRowContentView? {
        if let row = view as? ToolTimelineRowContentView { return row }
        return view.subviews.compactMap { terminalRow(in: $0) }.first
    }

    private static func containsTerminalText(_ text: String, in view: UIView) -> Bool {
        if let output = view as? UITextView, output.textStorage.string.contains(text) { return true }
        return view.subviews.contains { containsTerminalText(text, in: $0) }
    }

    @Test func ownedClockIgnoresSwiftUIRowSnapshot() async {
        let windowed = makeWindowedTimelineHarness(sessionId: "owned-ignore-snapshot")
        windowed.reducer.processBatch([
            .agentStart(sessionId: "owned-ignore-snapshot"),
            .textDelta(sessionId: "owned-ignore-snapshot", delta: "From reducer"),
        ])

        let stale = ChatItem.userMessage(
            id: "stale-swiftui-row",
            text: "SwiftUI snapshot must not apply",
            timestamp: Date()
        )
        let config = makeTimelineConfiguration(
            items: [stale],
            isBusy: true,
            streamingAssistantID: nil,
            sessionId: windowed.sessionId,
            reducer: windowed.reducer,
            toolOutputStore: windowed.toolOutputStore,
            toolArgsStore: windowed.toolArgsStore,
            toolSegmentStore: windowed.toolSegmentStore,
            connection: windowed.connection,
            scrollController: windowed.scrollController,
            audioPlayer: windowed.audioPlayer,
            ownsTimelineProjection: true
        )
        windowed.coordinator.updateHostChrome(configuration: config, to: windowed.collectionView)

        let applied = await waitForTimelineCondition(timeoutMs: 1_000) {
            await MainActor.run {
                windowed.coordinator.currentItemByID.values.contains { item in
                    if case .assistantMessage(_, let text, _) = item {
                        return text.contains("From reducer")
                    }
                    return false
                }
            }
        }

        #expect(applied)
        #expect(!windowed.coordinator.currentIDs.contains("stale-swiftui-row"))
        #expect(windowed.coordinator.isObservingOwnedTimelineForTesting)
    }

    @Test func streamingApplyDoesNotIncrementHostUpdateUIView() async {
        let fixture = makeHostedOwnedTimeline(isBusy: true)
        defer { fixture.tearDown() }

        fixture.reducer.processBatch([
            .agentStart(sessionId: fixture.sessionId),
            .textDelta(sessionId: fixture.sessionId, delta: "Hello"),
        ])
        let mounted = await waitForTimelineCondition(timeoutMs: 1_000) {
            await MainActor.run {
                fixture.host.view.layoutIfNeeded()
                return fixture.hostedController?.currentItemByID.values.contains { item in
                    if case .assistantMessage(_, let text, _) = item {
                        return text.contains("Hello")
                    }
                    return false
                } ?? false
            }
        }
        #expect(mounted)

        ChatTimelinePerf.reset()
        fixture.reducer.processBatch([
            .textDelta(sessionId: fixture.sessionId, delta: " stream"),
        ])

        let streamed = await waitForTimelineCondition(timeoutMs: 1_000) {
            await MainActor.run {
                fixture.host.view.layoutIfNeeded()
                let hasStreamText = fixture.hostedController?.currentItemByID.values.contains { item in
                    if case .assistantMessage(_, let text, _) = item {
                        return text.contains("Hello stream")
                    }
                    return false
                } ?? false
                return hasStreamText && ChatTimelinePerf.snapshot().controllerOwnedApplyCount >= 1
            }
        }

        let snapshot = ChatTimelinePerf.snapshot()
        #expect(streamed)
        #expect(snapshot.hostUpdateUIViewCount == 0)
        #expect(snapshot.controllerOwnedApplyCount >= 1)
    }

    @Test func outlineAvailabilityPublishesOnlyOnEmptyTransitionsAndBind() async {
        let windowed = makeWindowedTimelineHarness(sessionId: "owned-outline")
        let availability = ChatTimelineOutlineAvailability()
        var config = makeTimelineConfiguration(
            items: [],
            isBusy: true,
            sessionId: windowed.sessionId,
            reducer: windowed.reducer,
            toolOutputStore: windowed.toolOutputStore,
            toolArgsStore: windowed.toolArgsStore,
            toolSegmentStore: windowed.toolSegmentStore,
            connection: windowed.connection,
            scrollController: windowed.scrollController,
            audioPlayer: windowed.audioPlayer,
            ownsTimelineProjection: true
        )
        config.outlineAvailability = availability
        windowed.coordinator.resetOutlineAvailabilityPublishDiagnosticForTesting()
        windowed.coordinator.updateHostChrome(configuration: config, to: windowed.collectionView)
        #expect(!windowed.coordinator.outlineAvailabilityPublishedDuringHostUpdateForTesting)
        #expect(!availability.isAvailable)

        windowed.reducer.processBatch([
            .agentStart(sessionId: windowed.sessionId),
            .textDelta(sessionId: windowed.sessionId, delta: "Hello"),
        ])
        let becameAvailable = await waitForTimelineCondition(timeoutMs: 1_000) {
            await MainActor.run { availability.isAvailable }
        }
        #expect(becameAvailable)

        windowed.reducer.processBatch([
            .textDelta(sessionId: windowed.sessionId, delta: " stream"),
        ])
        let keptAvailable = await waitForTimelineCondition(timeoutMs: 1_000) {
            await MainActor.run {
                windowed.coordinator.currentItemByID.values.contains { item in
                    if case .assistantMessage(_, let text, _) = item {
                        return text.contains("Hello stream")
                    }
                    return false
                } && availability.isAvailable
            }
        }
        #expect(keptAvailable)

        windowed.reducer.reset()
        let becameEmpty = await waitForTimelineCondition(timeoutMs: 1_000) {
            await MainActor.run { !availability.isAvailable }
        }
        #expect(becameEmpty)

        let rebound = TimelineReducer()
        rebound.processBatch([
            .agentStart(sessionId: "owned-outline-b"),
            .textDelta(sessionId: "owned-outline-b", delta: "Other session"),
        ])
        var reboundConfig = makeTimelineConfiguration(
            items: [],
            isBusy: true,
            sessionId: "owned-outline-b",
            reducer: rebound,
            toolOutputStore: rebound.toolOutputStore,
            toolArgsStore: rebound.toolArgsStore,
            toolSegmentStore: rebound.toolSegmentStore,
            connection: windowed.connection,
            scrollController: windowed.scrollController,
            audioPlayer: windowed.audioPlayer,
            ownsTimelineProjection: true
        )
        reboundConfig.outlineAvailability = availability
        windowed.coordinator.resetOutlineAvailabilityPublishDiagnosticForTesting()
        let reboundPublication = windowed.coordinator.outlinePublicationCompletionGenerationForTesting
        windowed.coordinator.updateHostChrome(
            configuration: reboundConfig,
            to: windowed.collectionView
        )
        #expect(!windowed.coordinator.outlineAvailabilityPublishedDuringHostUpdateForTesting)
        #expect(await waitForOutlinePublication(on: windowed.coordinator, after: reboundPublication))
        #expect(availability.isAvailable)

        let emptyRebound = TimelineReducer()
        var emptyConfig = makeTimelineConfiguration(
            items: [],
            isBusy: true,
            sessionId: "owned-outline-empty",
            reducer: emptyRebound,
            toolOutputStore: emptyRebound.toolOutputStore,
            toolArgsStore: emptyRebound.toolArgsStore,
            toolSegmentStore: emptyRebound.toolSegmentStore,
            connection: windowed.connection,
            scrollController: windowed.scrollController,
            audioPlayer: windowed.audioPlayer,
            ownsTimelineProjection: true
        )
        emptyConfig.outlineAvailability = availability
        windowed.coordinator.resetOutlineAvailabilityPublishDiagnosticForTesting()
        let emptyPublication = windowed.coordinator.outlinePublicationCompletionGenerationForTesting
        windowed.coordinator.updateHostChrome(
            configuration: emptyConfig,
            to: windowed.collectionView
        )
        #expect(!windowed.coordinator.outlineAvailabilityPublishedDuringHostUpdateForTesting)
        #expect(await waitForOutlinePublication(on: windowed.coordinator, after: emptyPublication))
        #expect(!availability.isAvailable, "Empty rebind must hide availability before the new reducer receives tokens")

        emptyRebound.processBatch([
            .agentStart(sessionId: "owned-outline-empty"),
            .textDelta(sessionId: "owned-outline-empty", delta: "Empty then tokens"),
        ])
        let emptyThenTokens = await waitForTimelineCondition(timeoutMs: 1_000) {
            await MainActor.run { availability.isAvailable }
        }
        #expect(emptyThenTokens)

        let staleSourceChanges = windowed.coordinator.ownedSourceChangeCompletionGenerationForTesting
        windowed.reducer.processBatch([
            .textDelta(sessionId: windowed.sessionId, delta: " stale"),
        ])
        rebound.processBatch([
            .textDelta(sessionId: "owned-outline-b", delta: " stale-b"),
        ])
        #expect(await waitForOwnedSourceChanges(
            on: windowed.coordinator,
            after: staleSourceChanges,
            count: 2
        ))
        #expect(availability.isAvailable)
        #expect(windowed.coordinator.currentItemByID.values.contains { item in
            if case .assistantMessage(_, let text, _) = item {
                return text.contains("Empty then tokens")
                    && !text.contains("stale")
            }
            return false
        })
    }

    @Test func deferredOutlineAvailabilityUsesCurrentReducerEmptiness() async {
        let windowed = makeWindowedTimelineHarness(sessionId: "owned-outline-current")
        windowed.coordinator.ownedClock.didScheduleAttachRetry = true
        let availability = ChatTimelineOutlineAvailability()

        windowed.reducer.processBatch([
            .agentStart(sessionId: windowed.sessionId),
            .textDelta(sessionId: windowed.sessionId, delta: "Queued show"),
        ])
        var showConfig = makeTimelineConfiguration(
            items: [],
            isBusy: true,
            sessionId: windowed.sessionId,
            reducer: windowed.reducer,
            toolOutputStore: windowed.toolOutputStore,
            toolArgsStore: windowed.toolArgsStore,
            toolSegmentStore: windowed.toolSegmentStore,
            connection: windowed.connection,
            scrollController: windowed.scrollController,
            audioPlayer: windowed.audioPlayer,
            ownsTimelineProjection: true
        )
        showConfig.outlineAvailability = availability
        let showPublication = windowed.coordinator.outlinePublicationCompletionGenerationForTesting
        windowed.coordinator.updateHostChrome(
            configuration: showConfig,
            to: windowed.collectionView
        )
        // Apply the newer reducer state synchronously, then prevent its already-armed
        // observer from masking a stale deferred commit with a second correction.
        windowed.coordinator.ownedClock.isObserving = false
        windowed.reducer.reset()
        windowed.coordinator.applyOwnedProjection()
        #expect(await waitForOutlinePublication(on: windowed.coordinator, after: showPublication))
        #expect(!availability.isAvailable, "Queued show must commit the reducer's current empty state")

        availability.isAvailable = true
        let emptyReducer = TimelineReducer()
        var hideConfig = makeTimelineConfiguration(
            items: [],
            isBusy: true,
            sessionId: "owned-outline-current-b",
            reducer: emptyReducer,
            toolOutputStore: emptyReducer.toolOutputStore,
            toolArgsStore: emptyReducer.toolArgsStore,
            toolSegmentStore: emptyReducer.toolSegmentStore,
            connection: windowed.connection,
            scrollController: windowed.scrollController,
            audioPlayer: windowed.audioPlayer,
            ownsTimelineProjection: true
        )
        hideConfig.outlineAvailability = availability
        let hidePublication = windowed.coordinator.outlinePublicationCompletionGenerationForTesting
        windowed.coordinator.updateHostChrome(
            configuration: hideConfig,
            to: windowed.collectionView
        )
        windowed.coordinator.ownedClock.isObserving = false
        emptyReducer.processBatch([
            .agentStart(sessionId: "owned-outline-current-b"),
            .textDelta(sessionId: "owned-outline-current-b", delta: "Refilled"),
        ])
        windowed.coordinator.applyOwnedProjection()
        #expect(await waitForOutlinePublication(on: windowed.coordinator, after: hidePublication))
        #expect(availability.isAvailable, "Queued hide must commit the reducer's current nonempty state")
    }

    @Test func staleObserverDoesNotRetrackOrApplyReboundReducer() async {
        let windowed = makeWindowedTimelineHarness(sessionId: "owned-observer-a")
        windowed.coordinator.ownedClock.isObserving = true
        windowed.coordinator.ownedClock.didScheduleAttachRetry = true
        let configA = makeTimelineConfiguration(
            items: [],
            isBusy: true,
            sessionId: windowed.sessionId,
            reducer: windowed.reducer,
            toolOutputStore: windowed.toolOutputStore,
            toolArgsStore: windowed.toolArgsStore,
            toolSegmentStore: windowed.toolSegmentStore,
            connection: windowed.connection,
            scrollController: windowed.scrollController,
            audioPlayer: windowed.audioPlayer,
            ownsTimelineProjection: true
        )
        windowed.coordinator.updateHostChrome(configuration: configA, to: windowed.collectionView)

        let reducerB = TimelineReducer()
        let configB = makeTimelineConfiguration(
            items: [],
            isBusy: true,
            sessionId: "owned-observer-b",
            reducer: reducerB,
            toolOutputStore: reducerB.toolOutputStore,
            toolArgsStore: reducerB.toolArgsStore,
            toolSegmentStore: reducerB.toolSegmentStore,
            connection: windowed.connection,
            scrollController: windowed.scrollController,
            audioPlayer: windowed.audioPlayer,
            ownsTimelineProjection: true
        )
        windowed.coordinator.updateHostChrome(configuration: configB, to: windowed.collectionView)

        ChatTimelinePerf.reset()
        let staleSourceChange = windowed.coordinator.ownedSourceChangeCompletionGenerationForTesting
        windowed.reducer.processBatch([
            .agentStart(sessionId: windowed.sessionId),
            .textDelta(sessionId: windowed.sessionId, delta: "Stale A"),
        ])
        #expect(await waitForOwnedSourceChanges(on: windowed.coordinator, after: staleSourceChange))
        #expect(ChatTimelinePerf.snapshot().controllerOwnedApplyCount == 0)

        ChatTimelinePerf.reset()
        let currentSourceChange = windowed.coordinator.ownedSourceChangeCompletionGenerationForTesting
        reducerB.processBatch([
            .agentStart(sessionId: "owned-observer-b"),
            .textDelta(sessionId: "owned-observer-b", delta: "Current B"),
        ])
        #expect(await waitForOwnedSourceChanges(on: windowed.coordinator, after: currentSourceChange))
        #expect(ChatTimelinePerf.snapshot().controllerOwnedApplyCount == 1)
    }

    @Test func deferredAvailabilityNotifiesOnceOutsideHostUpdate() async {
        let windowed = makeWindowedTimelineHarness(sessionId: "owned-outline-notification")
        windowed.coordinator.ownedClock.didScheduleAttachRetry = true
        windowed.reducer.processBatch([
            .agentStart(sessionId: windowed.sessionId),
            .textDelta(sessionId: windowed.sessionId, delta: "Available"),
        ])
        let availability = ChatTimelineOutlineAvailability()
        let notifications = AvailabilityNotificationRecorder()
        withObservationTracking {
            _ = availability.isAvailable
        } onChange: {
            notifications.record()
        }
        var config = makeTimelineConfiguration(
            items: [],
            isBusy: true,
            sessionId: windowed.sessionId,
            reducer: windowed.reducer,
            toolOutputStore: windowed.toolOutputStore,
            toolArgsStore: windowed.toolArgsStore,
            toolSegmentStore: windowed.toolSegmentStore,
            connection: windowed.connection,
            scrollController: windowed.scrollController,
            audioPlayer: windowed.audioPlayer,
            ownsTimelineProjection: true
        )
        config.outlineAvailability = availability
        windowed.coordinator.resetOutlineAvailabilityPublishDiagnosticForTesting()
        let publication = windowed.coordinator.outlinePublicationCompletionGenerationForTesting

        windowed.coordinator.updateHostChrome(configuration: config, to: windowed.collectionView)

        #expect(notifications.count == 0, "Host update must return before availability publishes")
        #expect(windowed.coordinator.outlineAvailabilityMutationCountForTesting == 0)
        #expect(await waitForOutlinePublication(on: windowed.coordinator, after: publication))
        #expect(notifications.count == 1)
        #expect(windowed.coordinator.outlineAvailabilityMutationCountForTesting == 1)
        #expect(!windowed.coordinator.outlineAvailabilityPublishedDuringHostUpdateForTesting)
        #expect(availability.isAvailable)
    }

    @Test func quietProjectionAndSettledEndsLiveOnController() async {
        let windowed = makeWindowedTimelineHarness(sessionId: "owned-quiet")
        windowed.reducer.processBatch([
            .agentStart(sessionId: "owned-quiet"),
            .thinkingDelta(sessionId: "owned-quiet", delta: "plan"),
            .toolStart(
                sessionId: "owned-quiet",
                toolEventId: "tool-1",
                tool: "bash",
                args: ["command": "echo hi"]
            ),
            .toolEnd(sessionId: "owned-quiet", toolEventId: "tool-1"),
        ])

        let busy = makeTimelineConfiguration(
            items: [],
            isBusy: true,
            sessionId: windowed.sessionId,
            reducer: windowed.reducer,
            toolOutputStore: windowed.reducer.toolOutputStore,
            toolArgsStore: windowed.reducer.toolArgsStore,
            toolSegmentStore: windowed.reducer.toolSegmentStore,
            connection: windowed.connection,
            scrollController: windowed.scrollController,
            audioPlayer: windowed.audioPlayer,
            ownsTimelineProjection: true,
            quietModeEnabled: true
        )
        windowed.coordinator.updateHostChrome(configuration: busy, to: windowed.collectionView)

        let folded = await waitForTimelineCondition(timeoutMs: 1_000) {
            await MainActor.run {
                windowed.coordinator.currentIDs.contains { $0.hasPrefix("quiet-work-line:") }
            }
        }
        #expect(folded)
        #expect(windowed.coordinator.ownedQuietSettledEndsForTesting.isEmpty)

        let idle = makeTimelineConfiguration(
            items: [],
            isBusy: false,
            sessionId: windowed.sessionId,
            reducer: windowed.reducer,
            toolOutputStore: windowed.reducer.toolOutputStore,
            toolArgsStore: windowed.reducer.toolArgsStore,
            toolSegmentStore: windowed.reducer.toolSegmentStore,
            connection: windowed.connection,
            scrollController: windowed.scrollController,
            audioPlayer: windowed.audioPlayer,
            ownsTimelineProjection: true,
            quietModeEnabled: true
        )
        windowed.coordinator.updateHostChrome(configuration: idle, to: windowed.collectionView)

        #expect(!windowed.coordinator.ownedQuietSettledEndsForTesting.isEmpty)
        #expect(windowed.coordinator.currentIDs.contains { $0.hasPrefix("quiet-work-line:") })
        #expect(!windowed.coordinator.currentIDs.contains("tool-1"))
    }

    @Test func ownedShowEarlierExpandsControllerRenderWindow() async {
        let windowed = makeWindowedTimelineHarness(sessionId: "owned-window")
        let events = (0..<90).map { index in
            TraceEvent(
                id: "row-\(index)",
                type: index.isMultiple(of: 2) ? .user : .assistant,
                timestamp: "2026-09-07T10:00:00Z",
                text: "Message \(index)",
                tool: nil,
                args: nil,
                output: nil,
                toolCallId: nil,
                toolName: nil,
                isError: nil,
                thinking: nil
            )
        }
        windowed.reducer.loadSession(events)

        let config = makeTimelineConfiguration(
            items: [],
            renderWindowStep: TimelineRenderWindowPolicy.renderWindowStep,
            isBusy: false,
            sessionId: windowed.sessionId,
            reducer: windowed.reducer,
            toolOutputStore: windowed.toolOutputStore,
            toolArgsStore: windowed.toolArgsStore,
            connection: windowed.connection,
            scrollController: windowed.scrollController,
            audioPlayer: windowed.audioPlayer,
            ownsTimelineProjection: true
        )
        windowed.coordinator.updateHostChrome(configuration: config, to: windowed.collectionView)
        windowed.collectionView.layoutIfNeeded()

        #expect(windowed.coordinator.ownedTimelineRenderWindowForTesting == TimelineRenderWindowPolicy.standardWindow)
        #expect(windowed.coordinator.currentIDs.first == ChatTimelineCollectionHost.loadMoreID)

        windowed.coordinator.onShowEarlier?()
        windowed.collectionView.layoutIfNeeded()

        #expect(windowed.coordinator.ownedTimelineRenderWindowForTesting == 90)
        #expect(windowed.coordinator.currentIDs.first != ChatTimelineCollectionHost.loadMoreID)
    }

    @Test func ownedShowEarlierPagesThroughOlderPageActionOnlyAfterLocalRowsAreShown() async {
        let windowed = makeWindowedTimelineHarness(sessionId: "owned-older-page")
        windowed.reducer.loadSession(ownedClockTraceEvents(count: 90))
        var pageRequests = 0
        let step = 30
        let config = makeTimelineConfiguration(
            items: [],
            renderWindowStep: step,
            isBusy: false,
            sessionId: windowed.sessionId,
            reducer: windowed.reducer,
            toolOutputStore: windowed.toolOutputStore,
            toolArgsStore: windowed.toolArgsStore,
            connection: windowed.connection,
            scrollController: windowed.scrollController,
            audioPlayer: windowed.audioPlayer,
            ownsTimelineProjection: true,
            hasOlderServerPage: true,
            loadOlderPage: {
                pageRequests += 1
                windowed.reducer.loadSession(ownedClockTraceEvents(count: 200))
                return true
            }
        )
        windowed.coordinator.updateHostChrome(configuration: config, to: windowed.collectionView)
        windowed.collectionView.layoutIfNeeded()
        #expect(windowed.coordinator.ownedTimelineRenderWindowForTesting == TimelineRenderWindowPolicy.standardWindow)

        // Hidden local rows are revealed first; the remote page is not requested yet.
        windowed.coordinator.onShowEarlier?()
        #expect(windowed.coordinator.ownedTimelineRenderWindowForTesting == 90)
        #expect(pageRequests == 0)

        windowed.coordinator.onShowEarlier?()
        let paged = await waitForTimelineCondition(timeoutMs: 1_000) {
            await MainActor.run { windowed.reducer.items.count == 200 }
        }
        #expect(paged)
        // The render window grows by exactly the configured step from where it was.
        #expect(windowed.coordinator.ownedTimelineRenderWindowForTesting == 90 + step)
        #expect(pageRequests == 1)
    }

    @Test func ownedShowEarlierKeepsRenderWindowWhenOlderPageDoesNotLoad() async {
        let windowed = makeWindowedTimelineHarness(sessionId: "owned-older-page-failed")
        windowed.reducer.loadSession(ownedClockTraceEvents(count: 40))
        var pageRequests = 0
        let config = makeTimelineConfiguration(
            items: [],
            renderWindowStep: 30,
            isBusy: false,
            sessionId: windowed.sessionId,
            reducer: windowed.reducer,
            toolOutputStore: windowed.toolOutputStore,
            toolArgsStore: windowed.toolArgsStore,
            connection: windowed.connection,
            scrollController: windowed.scrollController,
            audioPlayer: windowed.audioPlayer,
            ownsTimelineProjection: true,
            hasOlderServerPage: true,
            loadOlderPage: {
                pageRequests += 1
                return false
            }
        )
        windowed.coordinator.updateHostChrome(configuration: config, to: windowed.collectionView)
        windowed.collectionView.layoutIfNeeded()
        #expect(windowed.coordinator.ownedTimelineRenderWindowForTesting == 40)

        windowed.coordinator.onShowEarlier?()
        let requested = await waitForTimelineCondition(timeoutMs: 1_000) {
            await MainActor.run { pageRequests == 1 }
        }
        #expect(requested)
        #expect(windowed.coordinator.ownedTimelineRenderWindowForTesting == 40)
    }

    @Test func dismantleStopsOwnedObservation() async {
        let windowed = makeWindowedTimelineHarness(sessionId: "owned-dismantle")
        let config = makeTimelineConfiguration(
            items: [],
            isBusy: true,
            sessionId: windowed.sessionId,
            reducer: windowed.reducer,
            toolOutputStore: windowed.toolOutputStore,
            toolArgsStore: windowed.toolArgsStore,
            connection: windowed.connection,
            scrollController: windowed.scrollController,
            audioPlayer: windowed.audioPlayer,
            ownsTimelineProjection: true
        )
        windowed.coordinator.updateHostChrome(configuration: config, to: windowed.collectionView)
        #expect(windowed.coordinator.isObservingOwnedTimelineForTesting)

        ChatTimelineCollectionHost.dismantleUIView(
            windowed.collectionView,
            coordinator: windowed.coordinator
        )
        #expect(!windowed.coordinator.isObservingOwnedTimelineForTesting)

        ChatTimelinePerf.reset()
        let sourceChange = windowed.coordinator.ownedSourceChangeCompletionGenerationForTesting
        windowed.reducer.processBatch([
            .agentStart(sessionId: "owned-dismantle"),
            .textDelta(sessionId: "owned-dismantle", delta: "after dismantle"),
        ])
        #expect(await waitForOwnedSourceChanges(on: windowed.coordinator, after: sourceChange))
        #expect(ChatTimelinePerf.snapshot().controllerOwnedApplyCount == 0)
    }
}

@MainActor
private func waitForOutlinePublication(
    on controller: ChatTimelineCollectionHost.Controller,
    after generation: UInt64
) async -> Bool {
    await waitForTimelineCondition(timeoutMs: 1_000) {
        await MainActor.run {
            controller.outlinePublicationCompletionGenerationForTesting > generation
        }
    }
}

@MainActor
private func waitForOwnedSourceChanges(
    on controller: ChatTimelineCollectionHost.Controller,
    after generation: UInt64,
    count: UInt64 = 1
) async -> Bool {
    await waitForTimelineCondition(timeoutMs: 1_000) {
        await MainActor.run {
            controller.ownedSourceChangeCompletionGenerationForTesting >= generation + count
        }
    }
}

private final class AvailabilityNotificationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCount = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedCount
    }

    func record() {
        lock.lock()
        recordedCount += 1
        lock.unlock()
    }
}

@MainActor
private struct HostedOwnedTimelineFixture {
    let window: UIWindow
    let host: UIHostingController<AnyView>
    let reducer: TimelineReducer
    let sessionId: String

    var hostedController: ChatTimelineCollectionHost.Controller? {
        guard let collectionView = timelineFirstView(ofType: UICollectionView.self, in: host.view) else {
            return nil
        }
        return collectionView.delegate as? ChatTimelineCollectionHost.Controller
    }

    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
    }
}

@MainActor
private func makeHostedOwnedTimeline(isBusy: Bool) -> HostedOwnedTimelineFixture {
    let sessionId = "owned-hosted-\(UUID().uuidString)"
    let reducer = TimelineReducer()
    let connection = ServerConnection()
    let audioPlayer = AudioPlayerService()
    let scrollController = ChatScrollController()
    let sessionManager = ChatSessionManager(sessionId: sessionId)

    let root = AnyView(
        ChatTimelineView(
            sessionId: sessionId,
            serverId: "server-test",
            workspaceId: "ws-test",
            isBusy: isBusy,
            extensionWorkingState: nil,
            extensionHiddenThinkingLabel: nil,
            currentModel: nil,
            sessionContent: connection.sessionContent,
            iconAssetCache: nil,
            openDestination: nil,
            loadOlderPage: nil,
            scrollController: scrollController,
            sessionManager: sessionManager,
            audioLifecycleCoordinator: nil,
            onFork: { _ in },
            onOpenCurrentFile: { _ in },
            onBackSwipe: {},
            reviewCommentSelectionRouter: nil,
            topOverlap: 0,
            bottomOverlap: 0
        )
        .environment(reducer)
        .environment(audioPlayer)
    )

    let host = UIHostingController(rootView: root)
    host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
    let window = UIWindow(frame: host.view.frame)
    window.rootViewController = host
    window.makeKeyAndVisible()
    host.view.layoutIfNeeded()

    return HostedOwnedTimelineFixture(
        window: window,
        host: host,
        reducer: reducer,
        sessionId: sessionId
    )
}

private func ownedClockTraceEvents(count: Int) -> [TraceEvent] {
    (0..<count).map { index in
        TraceEvent(
            id: "row-\(index)",
            type: index.isMultiple(of: 2) ? .user : .assistant,
            timestamp: "2026-09-07T10:00:00Z",
            text: "Message \(index)",
            tool: nil,
            args: nil,
            output: nil,
            toolCallId: nil,
            toolName: nil,
            isError: nil,
            thinking: nil
        )
    }
}
