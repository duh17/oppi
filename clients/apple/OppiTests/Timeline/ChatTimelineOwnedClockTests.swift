import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Oppi

@Suite("Chat timeline UIKit-owned clock")
@MainActor
struct ChatTimelineOwnedClockTests {
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
        windowed.reducer.processBatch([
            .agentStart(sessionId: "owned-dismantle"),
            .textDelta(sessionId: "owned-dismantle", delta: "after dismantle"),
        ])
        for _ in 0..<8 {
            await Task.yield()
        }
        #expect(ChatTimelinePerf.snapshot().controllerOwnedApplyCount == 0)
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
            connection: connection,
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
