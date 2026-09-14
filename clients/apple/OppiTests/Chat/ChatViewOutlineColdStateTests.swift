import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Oppi

/// Mounted `ChatView` proof that content-only streaming stays on the UIKit clock.
///
/// SwiftUI `.toolbar` outline/context controls are not exposed as UIView
/// accessibility identifiers in this `UIHostingController` host. Dumps show
/// `UIKitNavigationBar` without `chat.toolbar.outline`. Do not reintroduce a
/// synthetic `SessionOutlineView` present/onSelect path as a substitute.
/// Drive the real toolbar, presented Session Outline, and row navigation with
/// `OppiUITests/ChatOutlineColdStateUITests` (DEBUG ChatView harness, no model).
@Suite("ChatView outline cold state", .serialized)
@MainActor
struct ChatViewOutlineColdStateTests {
    @Test func contentOnlyStreamingDoesNotIncrementHostUpdateUIView() async {
        let fixture = makeMountedChatView()
        defer { fixture.tearDown() }

        let settled = await settleMountedChatView(fixture)
        #expect(settled, "Expected ChatView timeline to settle before streaming")

        let marker = "cold-hello-\(UUID().uuidString.prefix(8))"
        injectAssistantDelta(fixture, text: marker)

        let mounted = await waitForTimelineCondition(timeoutMs: 1_000) {
            await MainActor.run {
                fixture.host.view.layoutIfNeeded()
                return timelineHasAssistantText(fixture, containing: marker)
            }
        }
        #expect(mounted, "Expected first tokens to paint in the mounted ChatView timeline")

        ChatTimelinePerf.reset()
        injectAssistantDelta(fixture, text: " stream")

        let streamed = await waitForTimelineCondition(timeoutMs: 1_000) {
            await MainActor.run {
                fixture.host.view.layoutIfNeeded()
                let hasStreamText = timelineHasAssistantText(
                    fixture,
                    containing: "\(marker) stream"
                )
                return hasStreamText && ChatTimelinePerf.snapshot().controllerOwnedApplyCount >= 1
            }
        }

        let snapshot = ChatTimelinePerf.snapshot()
        #expect(streamed)
        #expect(
            snapshot.hostUpdateUIViewCount == 0,
            "Content-only streaming must not rebuild ChatView/updateUIView; hostUpdateUIViewCount=\(snapshot.hostUpdateUIViewCount)"
        )
        #expect(snapshot.controllerOwnedApplyCount >= 1)
    }

    @Test func sessionRebindIsolatesOldReducerFromHostUpdates() async throws {
        let sessionA = "cold-a-\(UUID().uuidString)"
        let sessionB = "cold-b-\(UUID().uuidString)"
        let fixture = makeMountedChatView(sessionId: sessionA)
        defer { fixture.tearDown() }

        let settledA = await settleMountedChatView(fixture)
        #expect(settledA)

        let markerA = "session-a-\(UUID().uuidString.prefix(8))"
        injectAssistantDelta(fixture, text: markerA)
        let showedA = await waitForTimelineCondition(timeoutMs: 1_000) {
            await MainActor.run {
                fixture.host.view.layoutIfNeeded()
                return timelineHasAssistantText(fixture, containing: markerA)
            }
        }
        #expect(showedA)
        let reducerA = try #require(fixture.reducer)

        fixture.rebind(sessionId: sessionB)
        let rebound = await waitForTimelineCondition(timeoutMs: 2_000) {
            await MainActor.run {
                fixture.host.view.layoutIfNeeded()
                guard let controller = fixture.timelineController,
                      controller.isObservingOwnedTimelineForTesting,
                      let configuration = controller.ownedClock.lastConfiguration
                else {
                    return false
                }
                return configuration.sessionId == sessionB && configuration.reducer !== reducerA
            }
        }
        #expect(rebound, "Clock must bind the new session reducer")
        if let controller = fixture.timelineController {
            await controller.waitForOwnedMainQueueToDrainForTesting()
        }
        let hiddenEmptyB = await waitForTimelineCondition(timeoutMs: 2_000) {
            await MainActor.run {
                fixture.host.view.layoutIfNeeded()
                guard let controller = fixture.timelineController,
                      controller.isObservingOwnedTimelineForTesting,
                      let configuration = controller.ownedClock.lastConfiguration
                else {
                    return false
                }
                return configuration.sessionId == sessionB
                    && configuration.reducer !== reducerA
                    && !fixture.outlineIsAvailable
            }
        }
        #expect(
            hiddenEmptyB,
            "Empty B must hide outline availability before B receives tokens"
        )

        let markerB = "session-b-\(UUID().uuidString.prefix(8))"
        injectAssistantDelta(fixture, text: markerB)
        let showedB = await waitForTimelineCondition(timeoutMs: 1_000) {
            await MainActor.run {
                fixture.host.view.layoutIfNeeded()
                return timelineHasAssistantText(fixture, containing: markerB)
                    && !timelineHasAssistantText(fixture, containing: markerA)
                    && fixture.outlineIsAvailable
            }
        }
        #expect(showedB, "Rebind must paint the new session, not leftover A rows")

        ChatTimelinePerf.reset()
        injectAssistantDelta(fixture, text: " live")
        let streamedB = await waitForTimelineCondition(timeoutMs: 1_000) {
            await MainActor.run {
                fixture.host.view.layoutIfNeeded()
                return timelineHasAssistantText(fixture, containing: "\(markerB) live")
                    && ChatTimelinePerf.snapshot().controllerOwnedApplyCount >= 1
            }
        }
        #expect(streamedB)
        #expect(ChatTimelinePerf.snapshot().hostUpdateUIViewCount == 0)

        let hostUpdatesAfterB = ChatTimelinePerf.snapshot().hostUpdateUIViewCount
        reducerA.processBatch([
            .textDelta(sessionId: sessionA, delta: " stale-a"),
        ])
        if let controller = fixture.timelineController {
            await controller.waitForOwnedMainQueueToDrainForTesting()
        }
        fixture.host.view.layoutIfNeeded()

        #expect(timelineHasAssistantText(fixture, containing: "\(markerB) live"))
        #expect(!timelineHasAssistantText(fixture, containing: "stale-a"))
        #expect(fixture.outlineIsAvailable)
        #expect(ChatTimelinePerf.snapshot().hostUpdateUIViewCount == hostUpdatesAfterB)
    }
}

@MainActor
private struct MountedChatViewFixture {
    let connection: ServerConnection
    let appNavigation: AppNavigation
    let quickCommentTemplateStore: QuickCommentTemplateStore
    let host: UIHostingController<MountedChatViewRoot>
    let window: UIWindow

    var timelineController: ChatTimelineCollectionHost.Controller? {
        guard let collectionView = timelineFirstView(
            ofType: UICollectionView.self,
            in: host.view
        ) else {
            return nil
        }
        return collectionView.delegate as? ChatTimelineCollectionHost.Controller
    }

    var reducer: TimelineReducer? {
        timelineController?.ownedClock.lastConfiguration?.reducer
    }

    var outlineIsAvailable: Bool {
        timelineController?.ownedClock.lastConfiguration?.outlineAvailability?.isAvailable ?? false
    }

    var sessionId: String {
        host.rootView.sessionId
    }

    func rebind(sessionId: String) {
        connection.sessionStore.upsert(makeTestSession(id: sessionId, status: .stopped))
        var root = host.rootView
        root.sessionId = sessionId
        host.rootView = root
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
    }

    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
    }
}

@MainActor
private struct MountedChatViewRoot: View {
    var sessionId: String
    let connection: ServerConnection
    let appNavigation: AppNavigation
    let quickCommentTemplateStore: QuickCommentTemplateStore

    var body: some View {
        NavigationStack {
            ChatView(sessionId: sessionId)
                .environment(connection)
                .environment(connection.chatState)
                .environment(connection.sessionStore)
                .environment(connection.audioPlayer)
                .environment(connection.gitStatusStore)
                .environment(connection.fileIndexStore)
                .environment(connection.messageQueueStore)
                .environment(connection.askRequestStore)
                .environment(appNavigation)
                .environment(quickCommentTemplateStore)
        }
    }
}

@MainActor
private func makeMountedChatView(
    sessionId: String = "cold-\(UUID().uuidString)"
) -> MountedChatViewFixture {
    let (connection, _) = makeTestConnection(sessionId: sessionId)
    connection.setAPIClientForTesting(nil)
    connection.sessionStore.upsert(makeTestSession(id: sessionId, status: .stopped))

    let appNavigation = AppNavigation()
    let quickCommentTemplateStore = QuickCommentTemplateStore(templates: [])
    let root = MountedChatViewRoot(
        sessionId: sessionId,
        connection: connection,
        appNavigation: appNavigation,
        quickCommentTemplateStore: quickCommentTemplateStore
    )
    let host = UIHostingController(rootView: root)
    host.loadViewIfNeeded()
    host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)

    let window = UIWindow(frame: host.view.frame)
    window.rootViewController = host
    window.makeKeyAndVisible()
    host.view.setNeedsLayout()
    host.view.layoutIfNeeded()

    return MountedChatViewFixture(
        connection: connection,
        appNavigation: appNavigation,
        quickCommentTemplateStore: quickCommentTemplateStore,
        host: host,
        window: window
    )
}

@MainActor
private func settleMountedChatView(_ fixture: MountedChatViewFixture) async -> Bool {
    await waitForTimelineCondition(timeoutMs: 2_000) {
        await MainActor.run {
            fixture.host.view.layoutIfNeeded()
            guard let controller = fixture.timelineController,
                  controller.isObservingOwnedTimelineForTesting,
                  let manager = controller.ownedClock.lastConfiguration?.sessionManager
            else {
                return false
            }
            switch manager.entryState {
            case .stopped(let historyLoaded):
                return historyLoaded
            case .disconnected:
                return true
            default:
                return false
            }
        }
    }
}

@MainActor
private func injectAssistantDelta(_ fixture: MountedChatViewFixture, text: String) {
    guard let reducer = fixture.reducer else { return }
    let sessionId = fixture.sessionId
    if reducer.items.isEmpty {
        reducer.processBatch([
            .agentStart(sessionId: sessionId),
            .textDelta(sessionId: sessionId, delta: text),
        ])
    } else {
        reducer.processBatch([
            .textDelta(sessionId: sessionId, delta: text),
        ])
    }
}

@MainActor
private func timelineHasAssistantText(
    _ fixture: MountedChatViewFixture,
    containing needle: String
) -> Bool {
    fixture.timelineController?.currentItemByID.values.contains { item in
        if case .assistantMessage(_, let text, _) = item {
            return text.contains(needle)
        }
        return false
    } ?? false
}
