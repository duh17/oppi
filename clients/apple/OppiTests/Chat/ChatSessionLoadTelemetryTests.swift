import Foundation
import Testing
@testable import Oppi

/// A session switch or load measures how long the user waited for content. A
/// visit that is abandoned or backgrounded before its first content must not
/// report the idle time (a suspended app once reported a 1.08 h switch).
@Suite("Chat session load telemetry")
@MainActor
struct ChatSessionLoadTelemetryTests {

    /// Connects a session with no cache, holds its trace fetch open until
    /// `duringLoad` has run, then lets it finish and returns what was recorded.
    private func recordLoad(
        duringLoad: @MainActor (ChatSessionManager) -> Void = { _ in }
    ) async -> TelemetryCapture {
        let gate = FetchGate()
        let sessionId = "load-telemetry-\(UUID().uuidString)"
        let manager = ChatSessionManager(sessionId: sessionId)
        let streams = ScriptedStreamFactory()
        manager._streamSessionForTesting = { _ in streams.makeStream() }
        manager._loadCatchUpForTesting = { _, _ in nil }
        manager._fetchSessionTraceForTesting = { _, _ in
            await gate.wait()
            return (
                makeTestSession(id: sessionId, workspaceId: "w1", status: .ready),
                [TraceEvent(
                    id: "t1", type: .user, timestamp: "2026-02-11T00:00:00Z", text: "Hello",
                    tool: nil, args: nil, output: nil, toolCallId: nil, toolName: nil,
                    isError: nil, thinking: nil
                )]
            )
        }
        var inboundMetaQueue: [WebSocketClient.InboundMeta?] = [.init(seq: nil, currentSeq: 5)]
        manager._consumeInboundMetaForTesting = {
            guard !inboundMetaQueue.isEmpty else { return nil }
            return inboundMetaQueue.removeFirst()
        }

        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())
        let sessionStore = SessionStore()
        sessionStore.upsert(makeTestSession(id: sessionId, workspaceId: "w1", status: .ready))

        let capture = TelemetryCapture()
        await capture.run {
            let connectTask = Task { @MainActor in
                await manager.connect(connection: connection, sessionStore: sessionStore)
            }
            #expect(await streams.waitForCreated(1))
            streams.yield(index: 0, message: .connected(session: makeTestSession(id: sessionId, workspaceId: "w1")))
            duringLoad(manager)
            await gate.open()
            // The reducer load, and every measurement it ends, run in one main-actor
            // turn: once the timeline has items, the load's telemetry has been decided.
            #expect(await waitForTestCondition(timeoutMs: 2_000) {
                await MainActor.run { !manager.reducer.items.isEmpty }
            })
            streams.finish(index: 0)
            await connectTask.value
        }
        return capture
    }

    @Test func completedLoadRecordsSwitchAndLoad() async {
        let capture = await recordLoad()

        #expect(capture.events(named: "app.session_switch").count == 1)
        #expect(capture.events(named: "app.session_load").count == 1)
    }

    @Test func loadOpenAcrossBackgroundingRecordsNothing() async {
        let capture = await recordLoad { manager in manager.cancelLoadMeasurements() }

        #expect(capture.events(named: "app.session_switch").isEmpty)
        #expect(capture.events(named: "app.session_load").isEmpty)
        #expect(capture.events(named: "app.fresh_content_lag").isEmpty)
    }

    @Test func sessionSwitchPastTheCatalogCeilingIsDropped() {
        let capture = TelemetryCapture()
        capture.runSync {
            Telemetry.record(AppSessionSwitch(durationMs: 3_888_000, cached: false))
            Telemetry.record(AppWorkspaceLoad(durationMs: 60_000, loadPath: .open))
            Telemetry.record(AppSessionSwitch(durationMs: 59_999, cached: true))
        }

        #expect(capture.events.map(\.name) == ["app.session_switch"])
    }
}

/// Holds a trace fetch until the test opens it.
private actor FetchGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}
