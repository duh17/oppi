import SwiftUI
import Testing
import UIKit
@testable import Oppi

@Suite("ChatView Lifecycle")
@MainActor
struct ChatViewLifecycleTests {
    @Test func onAppearPreparesSessionReentryBeforeAsyncConnectLoop() async {
        let parentId = "parent-\(UUID().uuidString)"
        let childId = "child-\(UUID().uuidString)"
        let (connection, _) = makeTestConnection(sessionId: childId)

        connection.sessionStore.upsert(makeTestSession(id: parentId, status: .ready))

        // Simulate the child session having been torn down during navigation.
        connection.disconnectSession()
        connection.wsClient?._setStatusForTesting(.disconnected)
        connection.streamConsumptionTask = nil

        #expect(connection.focusedSessionId == nil)

        var preparedSessionIds: [String] = []
        connection._onPrepareForSessionReentryForTesting = { sessionId in
            preparedSessionIds.append(sessionId)
        }

        let host = makeHost(connection: connection, sessionId: parentId)

        let prepared = await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { preparedSessionIds == [parentId] }
        }

        #expect(prepared, "Expected ChatView.onAppear to prepare session re-entry for the parent session")
        #expect(connection.focusedSessionId == parentId)

        host.teardown()
        connection.disconnectSession()
        connection.disconnectStream()
    }

    @Test func stoppedSessionBecomingBusyReconnectsFocusedStream() async {
        let sessionId = "parent-\(UUID().uuidString)"
        let workspaceId = "w1"
        let (connection, _) = makeTestConnection(sessionId: sessionId)
        connection.setSplitStreamCapabilitiesForTesting(sessionStream: true)
        connection.sessionStore.upsert(makeTestSession(id: sessionId, workspaceId: nil, status: .stopped))
        connection.disconnectSession()
        connection.wsClient?._setStatusForTesting(.disconnected)
        connection.streamConsumptionTask = nil

        let frames = ScriptedFrameStreamFactory()
        connection._connectStreamForTesting = { [weak connection] in
            connection?.wsClient?._setStatusForTesting(.connected)
            return frames.makeStream()
        }

        let host = makeHost(connection: connection, sessionId: sessionId)

        let enteredStoppedSession = await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run {
                connection.sessionStore.activeSessionId == sessionId
                    && connection.focusedSessionId == sessionId
                    && frames.streamsCreated == 0
            }
        }
        #expect(enteredStoppedSession, "Stopped re-entry should focus the session without opening a WebSocket")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(frames.streamsCreated == 0, "The stopped-session connect path must settle without subscribing")

        connection.sessionStore.upsert(makeTestSession(id: sessionId, workspaceId: workspaceId, status: .busy))

        #expect(await frames.waitForCreated(1, timeoutMs: 1_000),
                "When a visible stopped session becomes busy externally, ChatView should reconnect so live parent output is subscribed")

        frames.finish(index: 0)
        host.teardown()
        connection.disconnectStream()
    }

    @Test func onDisappearWithoutPlaybackDisconnectsFocusedSession() async {
        let sessionId = "session-\(UUID().uuidString)"
        let (connection, _) = makeTestConnection(sessionId: sessionId)
        connection.sessionStore.upsert(makeTestSession(id: sessionId, status: .ready))

        let host = makeHost(connection: connection, sessionId: sessionId)

        let appeared = await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { connection.focusedSessionId == sessionId }
        }
        #expect(appeared)

        host.controller.rootView = AnyView(EmptyView())
        host.controller.view.setNeedsLayout()
        host.controller.view.layoutIfNeeded()

        let disconnected = await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { connection.focusedSessionId == nil }
        }
        #expect(disconnected)

        host.teardown()
        connection.disconnectStream()
    }

    @Test func onDisappearDuringLocalPlaybackDisconnectsFocusedSession() async {
        let sessionId = "session-\(UUID().uuidString)"
        let (connection, _) = makeTestConnection(sessionId: sessionId)
        connection.sessionStore.upsert(makeTestSession(id: sessionId, status: .ready))

        let host = makeHost(connection: connection, sessionId: sessionId)

        let appeared = await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { connection.focusedSessionId == sessionId }
        }
        #expect(appeared)

        connection.audioPlayer.setSessionContext(makeTestSession(id: sessionId, status: .ready))
        connection.audioPlayer._setPlaybackStateForTesting(playing: "voice-1", loading: nil)
        host.hide()

        let disconnected = await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { connection.focusedSessionId == nil }
        }
        #expect(disconnected, "Local playback should not keep session focus/subscription lifecycle pinned")
        #expect(connection.audioPlayer.hasActivePlayback, "Expected local playback to survive ChatView disappearance")

        connection.audioPlayer._setPlaybackStateForTesting(playing: nil, loading: nil)

        host.teardown()
        connection.disconnectStream()
    }

    @Test func onDisappearDuringLiveAudioStreamDefersDisconnectUntilStreamDone() async {
        let sessionId = "session-\(UUID().uuidString)"
        let (connection, _) = makeTestConnection(sessionId: sessionId)
        connection.sessionStore.upsert(makeTestSession(id: sessionId, status: .ready))

        let host = makeHost(connection: connection, sessionId: sessionId)

        let appeared = await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { connection.focusedSessionId == sessionId }
        }
        #expect(appeared)

        connection.audioPlayer._setLiveTransportPlaybackForTesting(sessionID: sessionId)
        host.hide()
        try? await Task.sleep(for: .milliseconds(120))

        #expect(connection.focusedSessionId == sessionId)
        #expect(connection.audioPlayer.hasActiveLiveTransportPlayback)

        connection.audioPlayer._setLiveTransportPlaybackForTesting(sessionID: sessionId, receivedDone: true)

        let disconnected = await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { connection.focusedSessionId == nil }
        }
        #expect(disconnected, "Expected deferred disconnect after live stream no longer needs transport")

        connection.audioPlayer._setLiveTransportPlaybackForTesting(sessionID: nil)
        host.teardown()
        connection.disconnectStream()
    }

    private func makeHost(connection: ServerConnection, sessionId: String) -> HostHarness {
        let appNavigation = AppNavigation()
        let quickCommentTemplateStore = QuickCommentTemplateStore(templates: [])
        let root = makeRootView(
            connection: connection,
            sessionId: sessionId,
            appNavigation: appNavigation,
            quickCommentTemplateStore: quickCommentTemplateStore
        )

        let controller = UIHostingController(rootView: root)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)

        let window = UIWindow(frame: controller.view.frame)
        window.rootViewController = controller
        window.makeKeyAndVisible()

        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        return HostHarness(controller: controller, window: window)
    }

    private func makeRootView(
        connection: ServerConnection,
        sessionId: String,
        appNavigation: AppNavigation,
        quickCommentTemplateStore: QuickCommentTemplateStore
    ) -> AnyView {
        AnyView(
            ChatView(sessionId: sessionId)
                .environment(connection)
                .environment(connection.chatState)
                .environment(connection.sessionStore)
                .environment(connection.audioPlayer)
                .environment(connection.gitStatusStore)
                .environment(connection.fileIndexStore)
                .environment(connection.messageQueueStore)
                .environment(connection.permissionStore)
                .environment(connection.askRequestStore)
                .environment(appNavigation)
                .environment(quickCommentTemplateStore)
        )
    }
}

@MainActor
private struct HostHarness {
    let controller: UIHostingController<AnyView>
    let window: UIWindow

    func hide() {
        controller.rootView = AnyView(EmptyView())
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
    }

    func teardown() {
        hide()
        window.isHidden = true
        window.rootViewController = nil
    }
}
