import SwiftUI
import Testing
import UIKit
@testable import Oppi

@Suite("Chat screen lifecycle")
@MainActor
struct ChatViewLifecycleTests {
    @Test func sessionWarningChromeRendersGenericNoticesWithoutBranchingOnText() {
        #expect(ChatSessionWarningChrome.messages(from: nil).isEmpty)
        #expect(ChatSessionWarningChrome.messages(from: []).isEmpty)
        #expect(ChatSessionWarningChrome.messages(from: ["", "  "]).isEmpty)
        #expect(
            ChatSessionWarningChrome.messages(from: [
                "Configured Agent tool is unavailable and was dropped from this session: foo.",
                "  Another notice  ",
                "Configured Agent tool is unavailable and was dropped from this session: foo.",
            ]) == [
                "Configured Agent tool is unavailable and was dropped from this session: foo.",
                "Another notice",
            ]
        )
        let arbitrary = ["alpha", "beta"]
        #expect(ChatSessionWarningChrome.messages(from: arbitrary) == arbitrary)
    }

    @Test func inactiveAndBackgroundPauseTimelinePresentation() {
        #expect(ChatViewController.shouldPauseTimelinePresentation(for: .inactive))
        #expect(ChatViewController.shouldPauseTimelinePresentation(for: .background))
        #expect(!ChatViewController.shouldPauseTimelinePresentation(for: .active))
    }

    @Test func onAppearPreparesSessionReentryBeforeAsyncConnectLoop() async {
        let parentId = "parent-\(UUID().uuidString)"
        let childId = "child-\(UUID().uuidString)"
        let (connection, _) = makeTestConnection(sessionId: childId)

        connection.sessionStore.upsert(makeTestSession(id: parentId, status: .ready))

        // Simulate the session having been torn down during navigation.
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

        #expect(prepared, "Expected ChatViewController.onAppear to prepare session re-entry")
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
                "When a visible stopped session becomes busy externally, ChatViewController should reconnect so live parent output is subscribed")

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

        host.hide()

        let disconnected = await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { connection.focusedSessionId == nil }
        }
        #expect(disconnected)

        host.teardown()
        connection.disconnectStream()
    }

    @Test func coveredNavigationPushRetainsFocusedSession() async {
        let sessionId = "session-\(UUID().uuidString)"
        let (connection, _) = makeTestConnection(sessionId: sessionId)
        connection.sessionStore.upsert(makeTestSession(id: sessionId, status: .ready))

        let appNavigation = AppNavigation()
        appNavigation.openWorkspaceSession(
            WorkspaceSessionNavTarget(
                serverId: connection.currentServerId ?? "server-1",
                sessionId: sessionId
            )
        )
        let (host, stack) = makeStackedHost(
            connection: connection,
            sessionId: sessionId,
            appNavigation: appNavigation
        )

        let appeared = await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { connection.focusedSessionId == sessionId }
        }
        #expect(appeared)

        let reader = ChatReaderNavTarget(id: UUID())
        appNavigation.openChatReader(reader)
        #expect(appNavigation.isCoveringChat(sessionId: sessionId))

        stack.pushViewController(UIViewController(), animated: false)
        stack.view.layoutIfNeeded()
        #expect(host.controller?.viewIfLoaded?.window == nil, "Covered-alive proof requires the chat to leave the window")

        let retained = await waitForMainActorConditionToStayTrue(for: .milliseconds(120)) {
            connection.focusedSessionId == sessionId
        }
        #expect(
            retained,
            "Covered ChatViewController must stay alive under a real reader push"
        )

        host.teardown()
        connection.disconnectStream()
    }

    @Test func destroyingCoveredChatViewDisconnectsFocusedSession() async {
        let sessionId = "session-\(UUID().uuidString)"
        let workspaceId = "w1"
        let (connection, _) = makeTestConnection(sessionId: sessionId)
        connection.setSplitStreamCapabilitiesForTesting(sessionStream: true)
        connection.sessionStore.upsert(
            makeTestSession(id: sessionId, workspaceId: workspaceId, status: .ready)
        )

        let frames = ScriptedFrameStreamFactory()
        connection._connectStreamForTesting = { [weak connection] in
            connection?.wsClient?._setStatusForTesting(.connected)
            return frames.makeStream()
        }

        let appNavigation = AppNavigation()
        appNavigation.openWorkspaceSession(
            WorkspaceSessionNavTarget(
                serverId: connection.currentServerId ?? "server-1",
                sessionId: sessionId,
                workspaceId: workspaceId
            )
        )
        var host: HostHarness? = makeHost(
            connection: connection,
            sessionId: sessionId,
            appNavigation: appNavigation
        )

        let appeared = await waitForTestCondition(timeoutMs: 1_000) {
            await MainActor.run {
                connection.focusedSessionId == sessionId && frames.streamsCreated >= 1
            }
        }
        #expect(appeared, "Covered destroy proof needs a live focused stream")

        appNavigation.openChatReader(ChatReaderNavTarget(id: UUID()))
        #expect(appNavigation.isCoveringChat(sessionId: sessionId))

        host?.hide()
        host?.window.rootViewController = nil
        host?.window.isHidden = true
        host = nil
        await Task.yield()

        let disconnected = await waitForTestCondition(timeoutMs: 1_000) {
            await MainActor.run { connection.focusedSessionId == nil }
        }
        #expect(
            disconnected,
            "Destroying a covered ChatViewController must still release the focused session"
        )

        frames.finish(index: 0)
        connection.disconnectStream()
    }

    @Test func destroyingCoveredStoppedChatViewDisconnectsFocusedSession() async {
        let sessionId = "session-\(UUID().uuidString)"
        let (connection, _) = makeTestConnection(sessionId: sessionId)
        connection.setSplitStreamCapabilitiesForTesting(sessionStream: true)
        connection.sessionStore.upsert(makeTestSession(id: sessionId, status: .stopped))
        connection.disconnectSession()
        connection.wsClient?._setStatusForTesting(.disconnected)
        connection.streamConsumptionTask = nil

        var streamsCreated = 0
        connection._connectStreamForTesting = {
            streamsCreated += 1
            return AsyncStream { _ in }
        }

        let appNavigation = AppNavigation()
        appNavigation.openWorkspaceSession(
            WorkspaceSessionNavTarget(
                serverId: connection.currentServerId ?? "server-1",
                sessionId: sessionId
            )
        )
        var host: HostHarness? = makeHost(
            connection: connection,
            sessionId: sessionId,
            appNavigation: appNavigation
        )

        let appeared = await waitForTestCondition(timeoutMs: 1_000) {
            await MainActor.run {
                connection.focusedSessionId == sessionId && streamsCreated == 0
            }
        }
        #expect(appeared, "Stopped re-entry should focus the session without opening a WebSocket")

        appNavigation.openChatReader(ChatReaderNavTarget(id: UUID()))
        #expect(appNavigation.isCoveringChat(sessionId: sessionId))

        host?.hide()
        host?.window.rootViewController = nil
        host?.window.isHidden = true
        host = nil
        await Task.yield()

        let disconnected = await waitForTestCondition(timeoutMs: 1_000) {
            await MainActor.run { connection.focusedSessionId == nil }
        }
        #expect(
            disconnected,
            "Destroying a covered stopped ChatViewController must still release the focused session"
        )
        #expect(streamsCreated == 0, "Stopped covered destroy must not open a stream")

        connection.disconnectStream()
    }

    @Test func onDisappearDoesNotDisconnectPrefocusedNotificationTargetSession() async {
        let previousSessionId = "previous-\(UUID().uuidString)"
        let targetSessionId = "target-\(UUID().uuidString)"
        let workspaceId = "w1"
        let (connection, _) = makeTestConnection(sessionId: previousSessionId)
        connection.setSplitStreamCapabilitiesForTesting(sessionStream: true)
        connection.sessionStore.upsert(makeTestSession(id: previousSessionId, workspaceId: workspaceId, status: .busy))
        connection.sessionStore.upsert(makeTestSession(id: targetSessionId, workspaceId: workspaceId, status: .busy))

        let host = makeHost(connection: connection, sessionId: previousSessionId)

        let appeared = await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { connection.focusedSessionId == previousSessionId }
        }
        #expect(appeared)

        // Regression: notification/deep-link navigation pre-focuses the target
        // before the old chat view disappears. The disappearing old view must
        // not disconnect the newly focused stream.
        connection.prepareForSessionReentry(targetSessionId)
        #expect(connection.focusedSessionId == targetSessionId)

        host.hide()
        try? await Task.sleep(for: .milliseconds(120))

        #expect(
            connection.focusedSessionId == targetSessionId,
            "Old ChatViewController disappearance must not clear the notification target session"
        )

        host.teardown()
        connection.disconnectStream()
    }

    @Test func staleChatViewAppearDoesNotStealNotificationTargetStream() async {
        let staleSessionId = "stale-\(UUID().uuidString)"
        let targetSessionId = "target-\(UUID().uuidString)"
        let workspaceId = "w1"
        let (connection, _) = makeTestConnection(sessionId: staleSessionId)
        connection.setAPIClientForTesting(nil)
        connection.setSplitStreamCapabilitiesForTesting(sessionStream: true)
        connection.sessionStore.upsert(makeTestSession(id: staleSessionId, workspaceId: workspaceId, status: .busy))
        connection.sessionStore.upsert(makeTestSession(id: targetSessionId, workspaceId: workspaceId, status: .busy))

        var streamConnects = 0
        connection._connectStreamForTesting = {
            streamConnects += 1
            return AsyncStream { _ in }
        }

        // Notification tap binds the target stream before navigation commits.
        await connection.prepareExternalSessionOpen(sessionId: targetSessionId)
        #expect(connection.focusedSessionId == targetSessionId)
        #expect(streamConnects == 1)

        // The previous session's ChatViewController is still mounted and appears again
        // while the tapped session's socket is still connecting.
        let host = makeHost(connection: connection, sessionId: staleSessionId)
        try? await Task.sleep(for: .milliseconds(200))

        #expect(
            connection.focusedSessionId == targetSessionId,
            "A stale ChatViewController appearing must not steal focus from the notification target"
        )
        #expect(
            connection.focusedSessionStreamURLForTesting?.path
                == "/workspaces/\(workspaceId)/sessions/\(targetSessionId)/stream"
        )
        #expect(streamConnects == 1, "The notification target's socket must survive the stale appear")

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
        #expect(connection.audioPlayer.hasActivePlayback, "Expected local playback to survive ChatViewController disappearance")

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

    private func makeHost(
        connection: ServerConnection,
        sessionId: String,
        appNavigation: AppNavigation = AppNavigation()
    ) -> HostHarness {
        let chat = makeChat(connection: connection, sessionId: sessionId, appNavigation: appNavigation)
        return show(chat, in: chat)
    }

    /// The chat at the root of a UIKit navigation stack, as the shell hosts it.
    private func makeStackedHost(
        connection: ServerConnection,
        sessionId: String,
        appNavigation: AppNavigation
    ) -> (HostHarness, UINavigationController) {
        let chat = makeChat(connection: connection, sessionId: sessionId, appNavigation: appNavigation)
        let stack = UINavigationController(rootViewController: chat)
        return (show(chat, in: stack), stack)
    }

    private func show(_ chat: ChatViewController, in windowRoot: UIViewController) -> HostHarness {
        // A window in the app's scene, so UIKit runs the chat's
        // `updateProperties()` when the stores it reads change.
        let window = makeSceneWindow()
        // The chat's leaves and the timeline's empty state need the app root.
        window.traitOverrides.appRootEnvironment = makeTestAppRoot()
        window.rootViewController = windowRoot
        window.makeKeyAndVisible()

        windowRoot.view.setNeedsLayout()
        windowRoot.view.layoutIfNeeded()
        return HostHarness(controller: chat, window: window)
    }

    private func makeChat(
        connection: ServerConnection,
        sessionId: String,
        appNavigation: AppNavigation
    ) -> ChatViewController {
        ChatViewController(sessionId: sessionId, connection: connection, navigation: appNavigation)
    }
}

@MainActor
private struct HostHarness {
    weak var controller: ChatViewController?
    let window: UIWindow

    /// Takes the chat out of the window, the way a pop removes it.
    func hide() {
        window.rootViewController = UIViewController()
        window.layoutIfNeeded()
    }

    func teardown() {
        hide()
        window.isHidden = true
        window.rootViewController = nil
    }
}
