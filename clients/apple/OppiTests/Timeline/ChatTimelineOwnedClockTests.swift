import Foundation
import Observation
import SwiftUI
import Testing
import UIKit
@testable import Oppi

@Suite("Chat timeline UIKit-owned clock")
@MainActor
struct ChatTimelineOwnedClockTests {
    @Test func terminalTextPaintsFromTheStore() async throws {
        let fixture = makeHostedOwnedTimeline(isBusy: true)
        defer { fixture.tearDown() }
        fixture.reducer.expandedItemIDs.insert("terminal")
        fixture.reducer.processBatch([
            .agentStart(sessionId: fixture.sessionId),
            .textDelta(sessionId: fixture.sessionId, delta: "Hello"),
            .toolStart(sessionId: fixture.sessionId, toolEventId: "terminal", tool: "bash", args: ["command": .string("emit")],
                outputPresentation: .init(kind: "terminal")),
            .toolOutput(.init(sessionId: fixture.sessionId, toolEventId: "terminal", output: "ready\n", isError: false))
        ])
        #expect(fixture.reducer.toolOutputStore.fullOutput(for: "terminal") == "ready\n")
        #expect(await waitForTimelineCondition(timeoutMs: 1_000) {
            await MainActor.run {
                fixture.host.view.layoutIfNeeded()
                return Self.containsTerminalText("ready", in: fixture.host.view)
                    && !Self.containsTerminalText("Terminal output resync failed", in: fixture.host.view)
            }
        })
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

        #expect(notifications.count == 0, "Host update must return before availability publishes") // swiftlint:disable:this empty_count - recorder exposes count, not isEmpty
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

    @Test func upwardScrollNearTopRevealsEarlierRowsWithoutMovingTheReader() async throws {
        let windowed = makeWindowedTimelineHarness(sessionId: "owned-auto-earlier")
        windowed.reducer.loadSession(ownedClockTraceEvents(count: 200))
        let revealedWindows = try await dragToTopRevealingEarlierRows(windowed, quietModeEnabled: false)
        // Infinite scroll: one gesture walks every hidden batch, one step at a time.
        #expect(revealedWindows == [TimelineRenderWindowPolicy.standardWindow + TimelineRenderWindowPolicy.renderWindowStep, 200])
    }

    @Test func statusBarScrollToTopRevealsEarlierRowsWithoutMovingTheReader() async throws {
        let windowed = makeWindowedTimelineHarness(sessionId: "owned-auto-earlier-status-bar")
        windowed.reducer.loadSession(ownedClockTraceEvents(count: 200))
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
        let collectionView = windowed.collectionView
        let coordinator = windowed.coordinator

        // The status-bar tap animates without tracking, dragging, or decelerating.
        collectionView.contentOffset.y = -collectionView.adjustedContentInset.top
        collectionView.layoutIfNeeded()
        coordinator.scrollViewDidScroll(collectionView)
        let readerID = try #require(coordinator.currentIDs.dropFirst().first)
        let readerFrame = try #require(collectionView.layoutAttributesForItem(at: IndexPath(item: 1, section: 0))?.frame)
        let readerScreenY = readerFrame.minY - collectionView.contentOffset.y
        #expect(coordinator.ownedTimelineRenderWindowForTesting == TimelineRenderWindowPolicy.standardWindow)

        coordinator.scrollViewDidScrollToTop(collectionView)
        let revealed = await waitForTimelineCondition(timeoutMs: 1_000) {
            await MainActor.run {
                coordinator.ownedTimelineRenderWindowForTesting
                    == TimelineRenderWindowPolicy.standardWindow + TimelineRenderWindowPolicy.renderWindowStep
            }
        }
        #expect(revealed)
        collectionView.layoutIfNeeded()
        let readerIndex = try #require(coordinator.currentIDs.firstIndex(of: readerID))
        let movedFrame = try #require(
            collectionView.layoutAttributesForItem(at: IndexPath(item: readerIndex, section: 0))?.frame
        )
        let drift = movedFrame.minY - collectionView.contentOffset.y - readerScreenY
        #expect(abs(drift) <= 1, "top row \(readerID) moved \(drift)pt when rows landed above it")
    }

    @Test func upwardScrollKeepsRevealingWhileAFoldedWorkPillIsTheTopRow() async throws {
        // One long tool turn folds into a single pill. Growing the window
        // through that turn keeps the pill as the first rendered row, so the
        // same gesture must still walk on to the rows above it.
        let windowed = makeWindowedTimelineHarness(sessionId: "owned-auto-earlier-quiet")
        windowed.reducer.loadSession(longToolTurnTraceEvents(toolCalls: 120, trailingMessages: 40))
        let revealedWindows = try await dragToTopRevealingEarlierRows(windowed, quietModeEnabled: true)
        #expect(revealedWindows.count >= 2)
        #expect(revealedWindows.last == windowed.reducer.items.count)
    }

    /// One continuous finger drag from the tail toward the top, in 150pt
    /// steps. Each reveal must fire within a screen of the top and keep the
    /// row being read in place. Returns the render window after each reveal.
    private func dragToTopRevealingEarlierRows(
        _ windowed: WindowedTimelineHarness,
        quietModeEnabled: Bool
    ) async throws -> [Int] {
        let config = makeTimelineConfiguration(
            items: [],
            renderWindowStep: TimelineRenderWindowPolicy.renderWindowStep,
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
            quietModeEnabled: quietModeEnabled
        )
        windowed.coordinator.updateHostChrome(configuration: config, to: windowed.collectionView)
        windowed.collectionView.layoutIfNeeded()
        let collectionView = try #require(windowed.collectionView as? AnchoredCollectionView)
        let coordinator = windowed.coordinator
        #expect(coordinator.ownedTimelineRenderWindowForTesting == TimelineRenderWindowPolicy.standardWindow)
        #expect(coordinator.currentIDs.first == ChatTimelineCollectionHost.loadMoreID)
        if quietModeEnabled {
            let topRow = try #require(coordinator.currentIDs.dropFirst().first)
            #expect(topRow.hasPrefix("quiet-work-line:"), "fixture must start the window inside a folded turn, got \(topRow)")
        }

        let insets = collectionView.adjustedContentInset
        let viewportHeight = collectionView.bounds.height - insets.top - insets.bottom
        func readerRow() throws -> (id: String, screenY: CGFloat) {
            let readingTop = collectionView.contentOffset.y + insets.top
            let row = try #require(collectionView.indexPathsForVisibleItems
                .compactMap { indexPath -> (String, CGFloat)? in
                    let id = coordinator.currentIDs[indexPath.item]
                    guard id != ChatTimelineCollectionHost.loadMoreID,
                          let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame,
                          frame.minY >= readingTop else { return nil }
                    return (id, frame.minY)
                }
                .min { $0.1 < $1.1 })
            return (row.0, row.1 - collectionView.contentOffset.y)
        }
        func screenY(of id: String) throws -> CGFloat {
            let index = try #require(coordinator.currentIDs.firstIndex(of: id))
            let frame = try #require(
                collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame
            )
            return frame.minY - collectionView.contentOffset.y
        }

        // Rows self-size as they appear, so the distance is measured after
        // each step's layout rather than predicted from estimates.
        collectionView.testIsTracking = true
        collectionView.testIsDragging = true
        coordinator.scrollViewWillBeginDragging(collectionView)
        var revealedWindows: [Int] = []
        for _ in 0..<400 where coordinator.currentIDs.first == ChatTimelineCollectionHost.loadMoreID {
            let windowBefore = coordinator.ownedTimelineRenderWindowForTesting
            collectionView.contentOffset.y -= 150
            collectionView.layoutIfNeeded()
            coordinator.scrollViewDidScroll(collectionView)
            let distanceFromTop = collectionView.contentOffset.y + insets.top
            let reader = try readerRow()

            // The reveal runs on the next main-queue turn, after this callback.
            try await Task.sleep(for: .milliseconds(20))
            collectionView.layoutIfNeeded()
            let windowAfter = coordinator.ownedTimelineRenderWindowForTesting
            guard windowAfter != windowBefore else { continue }

            revealedWindows.append(windowAfter)
            #expect(
                distanceFromTop < viewportHeight,
                "revealed \(distanceFromTop)pt from the top, more than one screen early"
            )
            let drift = try screenY(of: reader.id) - reader.screenY
            #expect(abs(drift) <= 1, "reader row \(reader.id) moved \(drift)pt when rows landed above it")
        }
        collectionView.testIsTracking = false
        collectionView.testIsDragging = false

        #expect(coordinator.currentIDs.first != ChatTimelineCollectionHost.loadMoreID)
        return revealedWindows
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

/// One prompt, a turn of `toolCalls` tool calls, its answer, then
/// `trailingMessages` alternating plain messages.
private func longToolTurnTraceEvents(toolCalls: Int, trailingMessages: Int) -> [TraceEvent] {
    func event(
        _ id: String,
        _ type: TraceEventType,
        text: String? = nil,
        tool: String? = nil,
        args: [String: JSONValue]? = nil,
        output: String? = nil,
        toolCallId: String? = nil,
        toolName: String? = nil,
        isError: Bool? = nil
    ) -> TraceEvent {
        TraceEvent(
            id: id,
            type: type,
            timestamp: "2026-09-07T10:00:00Z",
            text: text,
            tool: tool,
            args: args,
            output: output,
            toolCallId: toolCallId,
            toolName: toolName,
            isError: isError,
            thinking: nil
        )
    }
    var events = [event("prompt", .user, text: "Run the checks")]
    for index in 0..<toolCalls {
        events.append(event("tc-\(index)", .toolCall, tool: "bash", args: ["command": .string("echo \(index)")]))
        events.append(event(
            "tr-\(index)",
            .toolResult,
            output: "\(index)",
            toolCallId: "tc-\(index)",
            toolName: "bash",
            isError: false
        ))
    }
    events.append(event("answer", .assistant, text: "All checks ran."))
    for index in 0..<trailingMessages {
        events.append(event("tail-\(index)", index.isMultiple(of: 2) ? .user : .assistant, text: "Message \(index)"))
    }
    return events
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
