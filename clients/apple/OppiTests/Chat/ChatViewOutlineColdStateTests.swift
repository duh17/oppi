import Foundation
import Testing
import UIKit
@testable import Oppi

/// Mounted `ChatViewController` proof that content-only streaming stays on
/// the timeline's own clock: the chat pushes no chrome while tokens stream.
///
/// Do not reintroduce a synthetic `SessionOutlineViewController`
/// present/onSelect path here. Drive the real bar, presented Session Outline,
/// and row navigation with `OppiUITests/ChatOutlineColdStateUITests` (DEBUG
/// chat harness, no model).
@Suite("Chat outline cold state", .serialized)
@MainActor
struct ChatViewOutlineColdStateTests {
    @Test func contentOnlyStreamingDoesNotIncrementHostUpdateUIView() async {
        let fixture = makeMountedChat()
        defer { fixture.tearDown() }

        let settled = await settleMountedChat(fixture)
        #expect(settled, "Expected ChatViewController timeline to settle before streaming")

        let marker = "cold-hello-\(UUID().uuidString.prefix(8))"
        injectAssistantDelta(fixture, text: marker)

        let mounted = await waitForTimelineCondition(timeoutMs: 1_000) {
            await MainActor.run {
                fixture.host.view.layoutIfNeeded()
                return timelineHasAssistantText(fixture, containing: marker)
            }
        }
        #expect(mounted, "Expected first tokens to paint in the mounted ChatViewController timeline")

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
            "Content-only streaming must not rebuild ChatViewController/updateUIView; hostUpdateUIViewCount=\(snapshot.hostUpdateUIViewCount)"
        )
        #expect(snapshot.controllerOwnedApplyCount >= 1)
    }

    /// Telemetry, crash context, and system classes write `UserDefaults` at
    /// any moment; none of that is chat state.
    @Test func unrelatedDefaultsWriteDoesNotRebuildTimelineHost() async {
        let fixture = makeMountedChat()
        defer { fixture.tearDown() }

        let settled = await settleMountedChat(fixture)
        #expect(settled, "Expected ChatViewController timeline to settle before the write")
        fixture.host.view.layoutIfNeeded()

        let key = "oppi.tests.unrelated-defaults-write"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        ChatTimelinePerf.reset()
        UserDefaults.standard.set(UUID().uuidString, forKey: key)

        // A rebuild lands on the next render pass; give it a few.
        let rebuilt = await waitForTimelineCondition(timeoutMs: 300) {
            await MainActor.run {
                fixture.host.view.setNeedsLayout()
                fixture.host.view.layoutIfNeeded()
                return ChatTimelinePerf.snapshot().hostUpdateUIViewCount > 0
            }
        }
        #expect(!rebuilt, "A UserDefaults write must not rebuild ChatViewController or call updateUIView")
    }

    @Test func sessionRebindIsolatesOldReducerFromHostUpdates() async throws {
        let sessionA = "cold-a-\(UUID().uuidString)"
        let sessionB = "cold-b-\(UUID().uuidString)"
        let fixture = makeMountedChat(sessionId: sessionA)
        defer { fixture.tearDown() }

        let settledA = await settleMountedChat(fixture)
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
        injectAssistantDelta(fixture, text: " current-b-proof")
        let currentBApplied = await waitForTimelineCondition(timeoutMs: 1_000) {
            await MainActor.run {
                fixture.host.view.layoutIfNeeded()
                return timelineHasAssistantText(
                    fixture,
                    containing: "\(markerB) live current-b-proof"
                )
            }
        }
        #expect(currentBApplied)

        #expect(timelineHasAssistantText(fixture, containing: "\(markerB) live current-b-proof"))
        #expect(!timelineHasAssistantText(fixture, containing: "stale-a"))
        #expect(fixture.outlineIsAvailable)
        #expect(ChatTimelinePerf.snapshot().hostUpdateUIViewCount == hostUpdatesAfterB)
    }
}

@MainActor
private final class MountedChatFixture {
    let connection: ServerConnection
    let appNavigation: AppNavigation
    let host: UINavigationController
    let window: UIWindow
    private(set) var sessionId: String

    init(
        connection: ServerConnection,
        appNavigation: AppNavigation,
        host: UINavigationController,
        window: UIWindow,
        sessionId: String
    ) {
        self.connection = connection
        self.appNavigation = appNavigation
        self.host = host
        self.window = window
        self.sessionId = sessionId
    }

    var timelineController: ChatTimelineController? {
        guard let collectionView = timelineFirstView(
            ofType: UICollectionView.self,
            in: host.view
        ) else {
            return nil
        }
        return collectionView.delegate as? ChatTimelineController
    }

    var reducer: TimelineReducer? {
        timelineController?.ownedClock.lastConfiguration?.reducer
    }

    var outlineIsAvailable: Bool {
        timelineController?.ownedClock.lastConfiguration?.outlineAvailability?.isAvailable ?? false
    }

    /// Same contract as every production host: a new session is a new chat
    /// controller, never an in-place session swap.
    func rebind(sessionId: String) {
        connection.sessionStore.upsert(makeTestSession(id: sessionId, status: .stopped))
        self.sessionId = sessionId
        host.setViewControllers([makeChat(sessionId: sessionId)], animated: false)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
    }

    func makeChat(sessionId: String) -> ChatViewController {
        ChatViewController(sessionId: sessionId, connection: connection, navigation: appNavigation)
    }

    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
    }
}

@MainActor
private func makeMountedChat(
    sessionId: String = "cold-\(UUID().uuidString)"
) -> MountedChatFixture {
    let (connection, _) = makeTestConnection(sessionId: sessionId)
    connection.setAPIClientForTesting(nil)
    connection.sessionStore.upsert(makeTestSession(id: sessionId, status: .stopped))

    let appNavigation = AppNavigation()
    let chat = ChatViewController(sessionId: sessionId, connection: connection, navigation: appNavigation)
    let host = UINavigationController(rootViewController: chat)

    let window = makeSceneWindow()
    // The timeline hosts its empty state with the app root above it.
    window.traitOverrides.appRootEnvironment = makeTestAppRoot()
    window.rootViewController = host
    window.makeKeyAndVisible()
    host.view.setNeedsLayout()
    host.view.layoutIfNeeded()

    return MountedChatFixture(
        connection: connection,
        appNavigation: appNavigation,
        host: host,
        window: window,
        sessionId: sessionId
    )
}

@MainActor
private func settleMountedChat(_ fixture: MountedChatFixture) async -> Bool {
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
private func injectAssistantDelta(_ fixture: MountedChatFixture, text: String) {
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
    _ fixture: MountedChatFixture,
    containing needle: String
) -> Bool {
    fixture.timelineController?.currentItemByID.values.contains { item in
        if case .assistantMessage(_, let text, _) = item {
            return text.contains(needle)
        }
        return false
    } ?? false
}
