import Foundation
import Testing
@testable import Oppi

/// Integration tests verifying that ScreenAwakeController is correctly driven
/// by session lifecycle signals in ServerConnection.
///
/// These tests use a fully injectable ScreenAwakeController (no UIApplication
/// dependency) and drive the message pipeline via TestEventPipeline.handle /
/// routeStreamMessage — the same code paths used at runtime.
///
/// Status-bearing triggers are `.state`/`.sessionSummary`: the client no longer
/// infers activity from `agent_start`, `agent_settled`, `stop_confirmed`, or
/// `stop_failed`, which now carry no local effect (`session_ended` is kept,
/// because it is still the only terminal fact some servers broadcast).
@Suite("ScreenAwake integration", .serialized)
@MainActor
struct ScreenAwakeIntegrationTests {

    // MARK: - Helpers

    /// Build a test controller whose release timer never fires automatically.
    /// Captures all idleTimerSetter calls for inspection.
    func makeController(
        timeoutProvider: @escaping @MainActor () -> Duration? = { .seconds(30) }
    ) -> (controller: ScreenAwakeController, updates: () -> [Bool]) {
        var captured: [Bool] = []
        let ctrl = ScreenAwakeController(
            timeoutProvider: timeoutProvider,
            idleTimerSetter: { captured.append($0) },
            sleepFunction: { _ in } // never fires; prevents async release noise
        )
        return (ctrl, { captured })
    }

    /// Build a test controller where the release timer fires immediately
    /// (equivalent to the "Off" preset — no post-activity keep-awake).
    func makeImmediateReleaseController()
    -> (controller: ScreenAwakeController, updates: () -> [Bool]) {
        makeController(timeoutProvider: { nil })
    }

    func makeConnection(
        sessionId: String = "s1",
        screenAwakeController: ScreenAwakeController? = nil
    ) async -> (conn: ServerConnection, pipe: TestEventPipeline) {
        let (connection, pipeline) = await makeTestConnection(sessionId: sessionId)
        if let screenAwakeController {
            connection.screenAwakeController = screenAwakeController
        }
        return (connection, pipeline)
    }

    /// Convenience wrapper: create a StreamMessage for cross-session tests.
    func streamMsg(sessionId: String, message: ServerMessage) -> StreamMessage {
        StreamMessage(sessionId: sessionId, seq: nil, currentSeq: nil, message: message)
    }

    // MARK: - Active-session: busy / ready state

    @Test("a busy state frame on the active session prevents sleep immediately")
    func agentStartPreventsIdleTimer() async {
        let (ctrl, updates) = makeController()
        let (conn, pipe) = await makeConnection(sessionId: "s1", screenAwakeController: ctrl)
        conn.sessionStore.upsert(makeTestSession(id: "s1", status: .ready))

        pipe.handle(.state(session: makeTestSession(id: "s1", status: .busy)), sessionId: "s1")

        #expect(ctrl.isPreventingSleep)
        #expect(updates().last == true)
    }

    @Test("a ready state releases the active-session idle timer (Off preset)")
    func agentSettledReleasesIdleTimer() async {
        let (ctrl, updates) = makeImmediateReleaseController()
        let (conn, pipe) = await makeConnection(sessionId: "s1", screenAwakeController: ctrl)
        conn.sessionStore.upsert(makeTestSession(id: "s1", status: .busy))

        pipe.handle(.state(session: makeTestSession(id: "s1", status: .busy)), sessionId: "s1")
        #expect(ctrl.isPreventingSleep)

        pipe.handle(.state(session: makeTestSession(id: "s1", status: .ready)), sessionId: "s1")
        #expect(!ctrl.isPreventingSleep)
        #expect(conn.sessionStore.session(id: "s1")?.status == .ready)
        #expect(updates().contains(true), "should have enabled sleep prevention first")
        #expect(updates().last == false, "should have released after the ready state")
    }

    @Test("a busy state for the wrong session is ignored")
    func agentStartIgnoredForWrongSession() async {
        let (ctrl, updates) = makeController()
        let (conn, pipe) = await makeConnection(sessionId: "s1", screenAwakeController: ctrl)
        conn.sessionStore.upsert(makeTestSession(id: "s1", status: .ready))

        // Route for "s2" but active session is "s1" — pipe.handle guards this
        pipe.handle(.state(session: makeTestSession(id: "s2", status: .busy)), sessionId: "s2")

        #expect(!ctrl.isPreventingSleep)
        #expect(updates().isEmpty)
    }

    // MARK: - Active-session: stop lifecycle

    @Test("a ready state after a stop releases the active-session idle timer")
    func stopConfirmedReleasesIdleTimer() async {
        let (ctrl, updates) = makeImmediateReleaseController()
        let (conn, pipe) = await makeConnection(sessionId: "s1", screenAwakeController: ctrl)
        conn.sessionStore.upsert(makeTestSession(id: "s1", status: .stopping))

        pipe.handle(.state(session: makeTestSession(id: "s1", status: .stopping)), sessionId: "s1")
        #expect(ctrl.isPreventingSleep)

        pipe.handle(.stopConfirmed(source: .user, reason: nil), sessionId: "s1")
        #expect(ctrl.isPreventingSleep, "stop_confirmed alone no longer releases; the server's ready state does")

        pipe.handle(.state(session: makeTestSession(id: "s1", status: .ready)), sessionId: "s1")
        #expect(!ctrl.isPreventingSleep)
        #expect(updates().contains(true))
        #expect(updates().last == false)
    }

    @Test("stopFailed carries no status; the session's busy state keeps the screen awake")
    func stopFailedKeepsIdleTimerActive() async {
        let (ctrl, _) = makeController()
        let (conn, pipe) = await makeConnection(sessionId: "s1", screenAwakeController: ctrl)
        conn.sessionStore.upsert(makeTestSession(id: "s1", status: .stopping))

        pipe.handle(.state(session: makeTestSession(id: "s1", status: .stopping)), sessionId: "s1")
        pipe.handle(.stopFailed(source: .user, reason: "busy"), sessionId: "s1")

        // stopFailed means the agent is still running — screen must stay awake
        #expect(ctrl.isPreventingSleep)
    }

    // MARK: - Active-session: sessionEnded

    @Test("sessionEnded on active session clears activity completely")
    func sessionEndedClearsActivity() async {
        let (ctrl, updates) = makeImmediateReleaseController()
        let (conn, pipe) = await makeConnection(sessionId: "s1", screenAwakeController: ctrl)
        conn.sessionStore.upsert(makeTestSession(id: "s1", status: .busy))

        pipe.handle(.state(session: makeTestSession(id: "s1", status: .busy)), sessionId: "s1")
        pipe.handle(.sessionEnded(reason: "done"), sessionId: "s1")

        #expect(!ctrl.isPreventingSleep)
        #expect(updates().last == false)
    }

    // MARK: - Idle sessions

    /// Every update for a session that never ran must leave the idle timer alone. Each one
    /// used to restart the post-activity timeout, so routine traffic for idle sessions kept
    /// the screen from auto-locking for as long as it kept arriving.
    @Test("updates for sessions that never ran do not wake the screen")
    func idleSessionUpdatesNeverWakeTheScreen() async {
        let (ctrl, updates) = makeController()
        let (conn, pipe) = await makeConnection(sessionId: "s1", screenAwakeController: ctrl)
        conn.sessionStore.upsert(makeTestSession(id: "s1", workspaceId: "w1", status: .ready))
        conn.sessionStore.upsert(makeTestSession(id: "s2", workspaceId: "w1", status: .ready))

        pipe.handle(.state(session: makeTestSession(id: "s1", workspaceId: "w1", status: .ready)), sessionId: "s1")
        conn.handleAppEvent(.sessionSummary(
            sessionId: "s2",
            workspaceId: "w1",
            emittedAt: 1,
            summary: SessionSummary(from: makeTestSession(id: "s2", workspaceId: "w1", status: .ready))
        ))
        conn.routeStreamMessage(streamMsg(sessionId: "s2", message: .sessionEnded(reason: "done")))
        conn.disconnectSession()

        #expect(!ctrl.isPreventingSleep)
        #expect(updates().isEmpty)
    }

    // MARK: - disconnectSession cleanup

    @Test("disconnectSession clears screen-awake for active session")
    func disconnectSessionClearsActivity() async {
        let (ctrl, updates) = makeImmediateReleaseController()
        let (conn, pipe) = await makeConnection(sessionId: "s1", screenAwakeController: ctrl)
        conn.sessionStore.upsert(makeTestSession(id: "s1", status: .busy))

        pipe.handle(.state(session: makeTestSession(id: "s1", status: .busy)), sessionId: "s1")
        #expect(ctrl.isPreventingSleep)

        conn.disconnectSession()
        #expect(!ctrl.isPreventingSleep)
        #expect(updates().last == false)
    }

    @Test("disconnectSession is safe when no active session")
    func disconnectSessionSafeWithNoActiveSession() {
        let (ctrl, _) = makeController()
        let conn = ServerConnection()
        conn.screenAwakeController = ctrl
        // No active session set

        // Must not crash or leak
        conn.disconnectSession()
        #expect(!ctrl.isPreventingSleep)
    }

    // MARK: - Cross-session signals

    @Test("a busy state on a non-active session prevents sleep")
    func crossSessionAgentStartPreventsIdleTimer() async {
        let (ctrl, updates) = makeController()
        // Active = s1, cross-session = s2
        let (conn, pipe) = await makeConnection(sessionId: "s1", screenAwakeController: ctrl)
        conn.sessionStore.upsert(makeTestSession(id: "s2", status: .ready))

        conn.routeStreamMessage(streamMsg(sessionId: "s2", message: .state(session: makeTestSession(id: "s2", status: .busy))))

        #expect(ctrl.isPreventingSleep)
        #expect(updates().last == true)
    }

    @Test("a ready state on a non-active session releases the idle timer")
    func crossSessionAgentSettledReleasesIdleTimer() async {
        let (ctrl, updates) = makeImmediateReleaseController()
        let (conn, pipe) = await makeConnection(sessionId: "s1", screenAwakeController: ctrl)
        conn.sessionStore.upsert(makeTestSession(id: "s2", status: .busy))

        conn.routeStreamMessage(streamMsg(sessionId: "s2", message: .state(session: makeTestSession(id: "s2", status: .busy))))
        #expect(ctrl.isPreventingSleep)

        conn.routeStreamMessage(streamMsg(sessionId: "s2", message: .state(session: makeTestSession(id: "s2", status: .ready))))
        #expect(!ctrl.isPreventingSleep)
        #expect(updates().last == false)
    }

    @Test("a ready state on a non-active session after a stop releases the idle timer")
    func crossSessionStopConfirmedReleasesIdleTimer() async {
        let (ctrl, updates) = makeImmediateReleaseController()
        let (conn, pipe) = await makeConnection(sessionId: "s1", screenAwakeController: ctrl)
        conn.sessionStore.upsert(makeTestSession(id: "s2", status: .stopping))

        conn.routeStreamMessage(streamMsg(sessionId: "s2", message: .state(session: makeTestSession(id: "s2", status: .stopping))))
        conn.routeStreamMessage(
            streamMsg(sessionId: "s2", message: .stopConfirmed(source: .user, reason: nil))
        )
        #expect(ctrl.isPreventingSleep, "stop_confirmed alone no longer releases; the server's ready state does")

        conn.routeStreamMessage(streamMsg(sessionId: "s2", message: .state(session: makeTestSession(id: "s2", status: .ready))))
        #expect(!ctrl.isPreventingSleep)
        #expect(updates().last == false)
    }

    @Test("cross-session sessionEnded clears activity")
    func crossSessionSessionEndedClearsActivity() async {
        let (ctrl, updates) = makeImmediateReleaseController()
        let (conn, pipe) = await makeConnection(sessionId: "s1", screenAwakeController: ctrl)
        conn.sessionStore.upsert(makeTestSession(id: "s2", status: .busy))

        conn.routeStreamMessage(streamMsg(sessionId: "s2", message: .state(session: makeTestSession(id: "s2", status: .busy))))
        conn.routeStreamMessage(streamMsg(sessionId: "s2", message: .sessionEnded(reason: "done")))

        #expect(!ctrl.isPreventingSleep)
        #expect(updates().last == false)
    }

    @Test("sessionDeleted clears screen-awake for deleted session")
    func sessionDeletedClearsActivity() async {
        let (ctrl, updates) = makeImmediateReleaseController()
        let (conn, pipe) = await makeConnection(sessionId: "s1", screenAwakeController: ctrl)
        conn.sessionStore.upsert(makeTestSession(id: "s2", status: .busy))

        conn.routeStreamMessage(streamMsg(sessionId: "s2", message: .state(session: makeTestSession(id: "s2", status: .busy))))
        conn.routeStreamMessage(streamMsg(sessionId: "s2", message: .sessionDeleted(sessionId: "s2")))

        #expect(!ctrl.isPreventingSleep)
        #expect(updates().last == false)
    }

    // MARK: - Multi-session

    @Test("screen stays awake while any session is active")
    func multiSessionScreenStaysAwake() async {
        let (ctrl, _) = makeImmediateReleaseController()
        let (conn, pipe) = await makeConnection(sessionId: "s1", screenAwakeController: ctrl)
        conn.sessionStore.upsert(makeTestSession(id: "s1", status: .ready))
        conn.sessionStore.upsert(makeTestSession(id: "s2", status: .ready))

        // Both sessions start
        pipe.handle(.state(session: makeTestSession(id: "s1", status: .busy)), sessionId: "s1")
        conn.routeStreamMessage(streamMsg(sessionId: "s2", message: .state(session: makeTestSession(id: "s2", status: .busy))))

        // s1 settles — s2 still active
        pipe.handle(.state(session: makeTestSession(id: "s1", status: .ready)), sessionId: "s1")
        #expect(ctrl.isPreventingSleep, "s2 still active — screen must stay awake")

        // s2 settles — all done
        conn.routeStreamMessage(streamMsg(sessionId: "s2", message: .state(session: makeTestSession(id: "s2", status: .ready))))
        #expect(!ctrl.isPreventingSleep, "no active sessions — should release")
    }

    @Test("active session disconnect does not clear cross-session tracking")
    func activeDisconnectDoesNotClearCrossSession() async {
        let (ctrl, _) = makeImmediateReleaseController()
        let (conn, pipe) = await makeConnection(sessionId: "s1", screenAwakeController: ctrl)
        conn.sessionStore.upsert(makeTestSession(id: "s1", status: .ready))
        conn.sessionStore.upsert(makeTestSession(id: "s2", status: .ready))

        pipe.handle(.state(session: makeTestSession(id: "s1", status: .busy)), sessionId: "s1")
        conn.routeStreamMessage(streamMsg(sessionId: "s2", message: .state(session: makeTestSession(id: "s2", status: .busy))))

        // Disconnect active session s1 — s2 still tracked
        conn.disconnectSession()
        #expect(ctrl.isPreventingSleep, "s2 still active after s1 disconnected")

        // s2 settles — now both gone
        conn.routeStreamMessage(streamMsg(sessionId: "s2", message: .state(session: makeTestSession(id: "s2", status: .ready))))
        #expect(!ctrl.isPreventingSleep)
    }

    // MARK: - handleState recovery

    @Test("handleState recovery from busy to ready releases idle timer")
    func handleStateRecoveryReleasesIdleTimer() async {
        let (ctrl, updates) = makeImmediateReleaseController()
        let (conn, pipe) = await makeConnection(sessionId: "s1", screenAwakeController: ctrl)
        conn.sessionStore.upsert(makeTestSession(id: "s1", status: .busy))

        pipe.handle(.state(session: makeTestSession(id: "s1", status: .busy)), sessionId: "s1")
        #expect(ctrl.isPreventingSleep)

        // Inject a .state event with status=.ready to trigger the recovery
        // hardening path in handleState (simulates reconnect gap where
        // agentEnd was never observed).
        let recoveredSession = makeTestSession(id: "s1", status: .ready)
        pipe.handle(.state(session: recoveredSession), sessionId: "s1")

        #expect(!ctrl.isPreventingSleep)
        #expect(updates().last == false)
    }

    // MARK: - Voice capture overlap

    @Test("voice capture overlapping a busy session holds until both clear")
    func voiceCaptureOverlapsBusySession() async {
        let (ctrl, updates) = makeImmediateReleaseController()
        let manager = VoiceInputManager(screenAwakeController: ctrl)
        let (conn, pipe) = await makeConnection(sessionId: "s1", screenAwakeController: ctrl)
        conn.sessionStore.upsert(makeTestSession(id: "s1", status: .ready))

        for captureState: VoiceInputManager.State in [.preparingModel, .recording, .processing] {
            manager._testState = captureState
            #expect(ctrl.isPreventingSleep, "\(captureState) should hold the idle timer")
        }

        pipe.handle(.state(session: makeTestSession(id: "s1", status: .busy)), sessionId: "s1")
        manager._testState = .idle
        #expect(ctrl.isPreventingSleep, "busy session still holds after capture ends")

        manager._testState = .recording
        pipe.handle(.state(session: makeTestSession(id: "s1", status: .ready)), sessionId: "s1")
        #expect(ctrl.isPreventingSleep, "voice capture still holds after the session settles")

        manager._testState = .error("done")
        #expect(!ctrl.isPreventingSleep)
        #expect(updates().last == false)
    }
}
