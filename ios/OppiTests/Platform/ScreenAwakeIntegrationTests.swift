import Foundation
import Testing
@testable import Oppi

/// Integration tests verifying that ScreenAwakeController is correctly driven
/// by session lifecycle signals in ServerConnection.
///
/// These tests use a fully injectable ScreenAwakeController (no UIApplication
/// dependency) and drive the message pipeline via TestEventPipeline.handle /
/// routeStreamMessage — the same code paths used at runtime.
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
    ) -> (conn: ServerConnection, pipe: TestEventPipeline) {
        let (connection, pipeline) = makeTestConnection(sessionId: sessionId)
        if let screenAwakeController {
            connection.screenAwakeController = screenAwakeController
        }
        return (connection, pipeline)
    }

    /// Convenience wrapper: create a StreamMessage for cross-session tests.
    func streamMsg(sessionId: String, message: ServerMessage) -> StreamMessage {
        StreamMessage(sessionId: sessionId, streamSeq: nil, seq: nil, currentSeq: nil, message: message)
    }

    // MARK: - Active-session: agentStart / agentEnd

    @Test("agentStart on active session prevents sleep immediately")
    func agentStartPreventsIdleTimer() {
        let (ctrl, updates) = makeController()
        let (conn, pipe) = makeConnection(sessionId: "s1", screenAwakeController: ctrl)
        conn.sessionStore.upsert(makeTestSession(id: "s1", status: .ready))

        pipe.handle(.agentStart, sessionId: "s1")

        #expect(ctrl.isPreventingSleep)
        #expect(updates().last == true)
    }

    @Test("agentEnd on active session releases idle timer immediately (Off preset)")
    func agentEndReleasesIdleTimer() {
        let (ctrl, updates) = makeImmediateReleaseController()
        let (conn, pipe) = makeConnection(sessionId: "s1", screenAwakeController: ctrl)
        conn.sessionStore.upsert(makeTestSession(id: "s1", status: .busy))

        pipe.handle(.agentStart, sessionId: "s1")
        pipe.handle(.agentEnd, sessionId: "s1")

        #expect(!ctrl.isPreventingSleep)
        #expect(updates().contains(true), "should have enabled sleep prevention first")
        #expect(updates().last == false, "should have released after agentEnd")
    }

    @Test("agentStart ignored for wrong sessionId")
    func agentStartIgnoredForWrongSession() {
        let (ctrl, updates) = makeController()
        let (conn, pipe) = makeConnection(sessionId: "s1", screenAwakeController: ctrl)
        conn.sessionStore.upsert(makeTestSession(id: "s1", status: .ready))

        // Route for "s2" but active session is "s1" — pipe.handle guards this
        pipe.handle(.agentStart, sessionId: "s2")

        #expect(!ctrl.isPreventingSleep)
        #expect(updates().isEmpty)
    }

    // MARK: - Active-session: stop lifecycle

    @Test("stopConfirmed on active session releases idle timer")
    func stopConfirmedReleasesIdleTimer() {
        let (ctrl, updates) = makeImmediateReleaseController()
        let (conn, pipe) = makeConnection(sessionId: "s1", screenAwakeController: ctrl)
        conn.sessionStore.upsert(makeTestSession(id: "s1", status: .stopping))

        pipe.handle(.agentStart, sessionId: "s1")
        let isStop = conn.isStopLifecycleMessage(.stopConfirmed(source: .user, reason: nil))
        pipe.handle(.stopConfirmed(source: .user, reason: nil), sessionId: "s1")

        #expect(isStop)
        #expect(!ctrl.isPreventingSleep)
        #expect(updates().contains(true))
        #expect(updates().last == false)
    }

    @Test("stopFailed on active session keeps screen awake (agent still busy)")
    func stopFailedKeepsIdleTimerActive() {
        let (ctrl, _) = makeController()
        let (conn, pipe) = makeConnection(sessionId: "s1", screenAwakeController: ctrl)
        conn.sessionStore.upsert(makeTestSession(id: "s1", status: .stopping))

        pipe.handle(.agentStart, sessionId: "s1")
        pipe.handle(.stopFailed(source: .user, reason: "busy"), sessionId: "s1")

        // stopFailed means the agent is still running — screen must stay awake
        #expect(ctrl.isPreventingSleep)
    }

    // MARK: - Active-session: sessionEnded

    @Test("sessionEnded on active session clears activity completely")
    func sessionEndedClearsActivity() {
        let (ctrl, updates) = makeImmediateReleaseController()
        let (conn, pipe) = makeConnection(sessionId: "s1", screenAwakeController: ctrl)
        conn.sessionStore.upsert(makeTestSession(id: "s1", status: .busy))

        pipe.handle(.agentStart, sessionId: "s1")
        pipe.handle(.sessionEnded(reason: "done"), sessionId: "s1")

        #expect(!ctrl.isPreventingSleep)
        #expect(updates().last == false)
    }

    // MARK: - disconnectSession cleanup

    @Test("disconnectSession clears screen-awake for active session")
    func disconnectSessionClearsActivity() {
        let (ctrl, updates) = makeImmediateReleaseController()
        let (conn, pipe) = makeConnection(sessionId: "s1", screenAwakeController: ctrl)
        conn.sessionStore.upsert(makeTestSession(id: "s1", status: .busy))

        pipe.handle(.agentStart, sessionId: "s1")
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

    @Test("agentStart on non-active session prevents sleep")
    func crossSessionAgentStartPreventsIdleTimer() {
        let (ctrl, updates) = makeController()
        // Active = s1, cross-session = s2
        let (conn, pipe) = makeConnection(sessionId: "s1", screenAwakeController: ctrl)
        conn.sessionStore.upsert(makeTestSession(id: "s2", status: .ready))

        conn.routeStreamMessage(streamMsg(sessionId: "s2", message: .agentStart))

        #expect(ctrl.isPreventingSleep)
        #expect(updates().last == true)
    }

    @Test("agentEnd on non-active session releases idle timer")
    func crossSessionAgentEndReleasesIdleTimer() {
        let (ctrl, updates) = makeImmediateReleaseController()
        let (conn, pipe) = makeConnection(sessionId: "s1", screenAwakeController: ctrl)
        conn.sessionStore.upsert(makeTestSession(id: "s2", status: .busy))

        conn.routeStreamMessage(streamMsg(sessionId: "s2", message: .agentStart))
        conn.routeStreamMessage(streamMsg(sessionId: "s2", message: .agentEnd))

        #expect(!ctrl.isPreventingSleep)
        #expect(updates().last == false)
    }

    @Test("cross-session stopConfirmed releases idle timer")
    func crossSessionStopConfirmedReleasesIdleTimer() {
        let (ctrl, updates) = makeImmediateReleaseController()
        let (conn, pipe) = makeConnection(sessionId: "s1", screenAwakeController: ctrl)
        conn.sessionStore.upsert(makeTestSession(id: "s2", status: .stopping))

        conn.routeStreamMessage(streamMsg(sessionId: "s2", message: .agentStart))
        conn.routeStreamMessage(
            streamMsg(sessionId: "s2", message: .stopConfirmed(source: .user, reason: nil))
        )

        #expect(!ctrl.isPreventingSleep)
        #expect(updates().last == false)
    }

    @Test("cross-session sessionEnded clears activity")
    func crossSessionSessionEndedClearsActivity() {
        let (ctrl, updates) = makeImmediateReleaseController()
        let (conn, pipe) = makeConnection(sessionId: "s1", screenAwakeController: ctrl)
        conn.sessionStore.upsert(makeTestSession(id: "s2", status: .busy))

        conn.routeStreamMessage(streamMsg(sessionId: "s2", message: .agentStart))
        conn.routeStreamMessage(streamMsg(sessionId: "s2", message: .sessionEnded(reason: "done")))

        #expect(!ctrl.isPreventingSleep)
        #expect(updates().last == false)
    }

    @Test("sessionDeleted clears screen-awake for deleted session")
    func sessionDeletedClearsActivity() {
        let (ctrl, updates) = makeImmediateReleaseController()
        let (conn, pipe) = makeConnection(sessionId: "s1", screenAwakeController: ctrl)
        conn.sessionStore.upsert(makeTestSession(id: "s2", status: .busy))

        conn.routeStreamMessage(streamMsg(sessionId: "s2", message: .agentStart))
        conn.routeStreamMessage(streamMsg(sessionId: "s2", message: .sessionDeleted(sessionId: "s2")))

        #expect(!ctrl.isPreventingSleep)
        #expect(updates().last == false)
    }

    // MARK: - Multi-session

    @Test("screen stays awake while any session is active")
    func multiSessionScreenStaysAwake() {
        let (ctrl, _) = makeImmediateReleaseController()
        let (conn, pipe) = makeConnection(sessionId: "s1", screenAwakeController: ctrl)
        conn.sessionStore.upsert(makeTestSession(id: "s1", status: .ready))
        conn.sessionStore.upsert(makeTestSession(id: "s2", status: .ready))

        // Both sessions start
        pipe.handle(.agentStart, sessionId: "s1")
        conn.routeStreamMessage(streamMsg(sessionId: "s2", message: .agentStart))

        // s1 ends — s2 still active
        pipe.handle(.agentEnd, sessionId: "s1")
        #expect(ctrl.isPreventingSleep, "s2 still active — screen must stay awake")

        // s2 ends — all done
        conn.routeStreamMessage(streamMsg(sessionId: "s2", message: .agentEnd))
        #expect(!ctrl.isPreventingSleep, "no active sessions — should release")
    }

    @Test("active session disconnect does not clear cross-session tracking")
    func activeDisconnectDoesNotClearCrossSession() {
        let (ctrl, _) = makeImmediateReleaseController()
        let (conn, pipe) = makeConnection(sessionId: "s1", screenAwakeController: ctrl)
        conn.sessionStore.upsert(makeTestSession(id: "s1", status: .ready))
        conn.sessionStore.upsert(makeTestSession(id: "s2", status: .ready))

        pipe.handle(.agentStart, sessionId: "s1")
        conn.routeStreamMessage(streamMsg(sessionId: "s2", message: .agentStart))

        // Disconnect active session s1 — s2 still tracked
        conn.disconnectSession()
        #expect(ctrl.isPreventingSleep, "s2 still active after s1 disconnected")

        // s2 ends — now both gone
        conn.routeStreamMessage(streamMsg(sessionId: "s2", message: .agentEnd))
        #expect(!ctrl.isPreventingSleep)
    }

    // MARK: - handleState recovery

    @Test("handleState recovery from busy to ready releases idle timer")
    func handleStateRecoveryReleasesIdleTimer() {
        let (ctrl, updates) = makeImmediateReleaseController()
        let (conn, pipe) = makeConnection(sessionId: "s1", screenAwakeController: ctrl)
        conn.sessionStore.upsert(makeTestSession(id: "s1", status: .busy))

        pipe.handle(.agentStart, sessionId: "s1")
        #expect(ctrl.isPreventingSleep)

        // Inject a .state event with status=.ready to trigger the recovery
        // hardening path in handleState (simulates reconnect gap where
        // agentEnd was never observed).
        let recoveredSession = makeTestSession(id: "s1", status: .ready)
        pipe.handle(.state(session: recoveredSession), sessionId: "s1")

        #expect(!ctrl.isPreventingSleep)
        #expect(updates().last == false)
    }
}
