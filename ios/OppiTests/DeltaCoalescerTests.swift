import Testing
import Foundation
@testable import Oppi

@Suite("DeltaCoalescer")
struct DeltaCoalescerTests {

    // MARK: - Immediate flush for non-delta events

    @MainActor
    @Test func toolStartFlushesImmediately() {
        let coalescer = DeltaCoalescer()
        var flushed: [[AgentEvent]] = []
        coalescer.onFlush = { flushed.append($0) }

        coalescer.receive(.toolStart(
            sessionId: "s1", toolEventId: "t1", tool: "bash", args: ["command": "ls"]
        ))

        #expect(flushed.count == 1)
        #expect(flushed[0].count == 1)
        guard case .toolStart(_, _, let tool, _, _) = flushed[0][0] else {
            Issue.record("Expected toolStart")
            return
        }
        #expect(tool == "bash")
    }

    @MainActor
    @Test func toolEndFlushesImmediately() {
        let coalescer = DeltaCoalescer()
        var flushed: [[AgentEvent]] = []
        coalescer.onFlush = { flushed.append($0) }

        coalescer.receive(.toolEnd(sessionId: "s1", toolEventId: "t1"))

        #expect(flushed.count == 1)
    }

    @MainActor
    @Test func permissionRequestFlushesImmediately() {
        let coalescer = DeltaCoalescer()
        var flushed: [[AgentEvent]] = []
        coalescer.onFlush = { flushed.append($0) }

        let perm = PermissionRequest(
            id: "p1", sessionId: "s1", tool: "bash",
            input: [:], displaySummary: "bash: rm",
            risk: .high, reason: "Destructive",
            timeoutAt: Date().addingTimeInterval(120)
        )
        coalescer.receive(.permissionRequest(perm))

        #expect(flushed.count == 1)
        guard case .permissionRequest(let req) = flushed[0][0] else {
            Issue.record("Expected permissionRequest")
            return
        }
        #expect(req.id == "p1")
    }

    @MainActor
    @Test func permissionExpiredFlushesImmediately() {
        let coalescer = DeltaCoalescer()
        var flushed: [[AgentEvent]] = []
        coalescer.onFlush = { flushed.append($0) }

        coalescer.receive(.permissionExpired(id: "p1"))

        #expect(flushed.count == 1)
        guard case .permissionExpired(let id) = flushed[0][0] else {
            Issue.record("Expected permissionExpired")
            return
        }
        #expect(id == "p1")
    }

    @MainActor
    @Test func agentStartFlushesImmediately() {
        let coalescer = DeltaCoalescer()
        var flushed: [[AgentEvent]] = []
        coalescer.onFlush = { flushed.append($0) }

        coalescer.receive(.agentStart(sessionId: "s1"))

        #expect(flushed.count == 1)
    }

    @MainActor
    @Test func agentEndFlushesImmediately() {
        let coalescer = DeltaCoalescer()
        var flushed: [[AgentEvent]] = []
        coalescer.onFlush = { flushed.append($0) }

        coalescer.receive(.agentEnd(sessionId: "s1"))

        #expect(flushed.count == 1)
    }

    @MainActor
    @Test func sessionEndedFlushesImmediately() {
        let coalescer = DeltaCoalescer()
        var flushed: [[AgentEvent]] = []
        coalescer.onFlush = { flushed.append($0) }

        coalescer.receive(.sessionEnded(sessionId: "s1", reason: "stopped"))

        #expect(flushed.count == 1)
    }

    @MainActor
    @Test func errorFlushesImmediately() {
        let coalescer = DeltaCoalescer()
        var flushed: [[AgentEvent]] = []
        coalescer.onFlush = { flushed.append($0) }

        coalescer.receive(.error(sessionId: "s1", message: "boom"))

        #expect(flushed.count == 1)
    }

    // MARK: - Buffered deltas

    @MainActor
    @Test func textDeltaIsBufferedNotImmediate() {
        let coalescer = DeltaCoalescer()
        var flushed: [[AgentEvent]] = []
        coalescer.onFlush = { flushed.append($0) }

        coalescer.receive(.textDelta(sessionId: "s1", delta: "hello"))

        // Should NOT have flushed yet (buffered for 33ms)
        #expect(flushed.isEmpty)
    }

    @MainActor
    @Test func thinkingDeltaIsBuffered() {
        let coalescer = DeltaCoalescer()
        var flushed: [[AgentEvent]] = []
        coalescer.onFlush = { flushed.append($0) }

        coalescer.receive(.thinkingDelta(sessionId: "s1", delta: "thinking..."))

        #expect(flushed.isEmpty)
    }

    @MainActor
    @Test func toolOutputIsBuffered() {
        let coalescer = DeltaCoalescer()
        var flushed: [[AgentEvent]] = []
        coalescer.onFlush = { flushed.append($0) }

        coalescer.receive(.toolOutput(sessionId: "s1", toolEventId: "t1", output: "data", isError: false))

        #expect(flushed.isEmpty)
    }

    // MARK: - flushNow

    @MainActor
    @Test func flushNowDeliversBufferedDeltas() {
        let coalescer = DeltaCoalescer()
        var flushed: [[AgentEvent]] = []
        coalescer.onFlush = { flushed.append($0) }

        coalescer.receive(.textDelta(sessionId: "s1", delta: "a"))
        coalescer.receive(.textDelta(sessionId: "s1", delta: "b"))
        coalescer.receive(.textDelta(sessionId: "s1", delta: "c"))

        #expect(flushed.isEmpty)

        coalescer.flushNow()

        #expect(flushed.count == 1)
        #expect(flushed[0].count == 3)
    }

    @MainActor
    @Test func flushNowOnEmptyBufferIsNoOp() {
        let coalescer = DeltaCoalescer()
        var flushed: [[AgentEvent]] = []
        coalescer.onFlush = { flushed.append($0) }

        coalescer.flushNow()

        // Empty buffer should not call onFlush
        #expect(flushed.isEmpty)
    }

    @MainActor
    @Test func doubleFlushNowIsIdempotent() {
        let coalescer = DeltaCoalescer()
        var flushed: [[AgentEvent]] = []
        coalescer.onFlush = { flushed.append($0) }

        coalescer.receive(.textDelta(sessionId: "s1", delta: "x"))
        coalescer.flushNow()
        coalescer.flushNow()

        #expect(flushed.count == 1)
    }

    // MARK: - Immediate event flushes pending buffer first

    @MainActor
    @Test func immediateEventFlushesPendingBufferFirst() {
        let coalescer = DeltaCoalescer()
        var flushed: [[AgentEvent]] = []
        coalescer.onFlush = { flushed.append($0) }

        // Buffer some deltas
        coalescer.receive(.textDelta(sessionId: "s1", delta: "partial"))
        #expect(flushed.isEmpty)

        // Now send an immediate event — should flush buffer first
        coalescer.receive(.agentEnd(sessionId: "s1"))

        // Two flushes: buffered deltas, then the agentEnd
        #expect(flushed.count == 2)
        // First flush is the buffered delta
        guard case .textDelta = flushed[0][0] else {
            Issue.record("Expected textDelta in first flush")
            return
        }
        // Second flush is the immediate event
        guard case .agentEnd = flushed[1][0] else {
            Issue.record("Expected agentEnd in second flush")
            return
        }
    }

    // MARK: - Timer-based flush

    @MainActor
    @Test func bufferedDeltasFlushAfterInterval() async throws {
        let coalescer = DeltaCoalescer()
        var flushed: [[AgentEvent]] = []
        coalescer.onFlush = { flushed.append($0) }

        coalescer.receive(.textDelta(sessionId: "s1", delta: "delayed"))

        // Wait longer than the 33ms flush interval
        try await Task.sleep(for: .milliseconds(80))

        #expect(flushed.count == 1)
        #expect(flushed[0].count == 1)
    }

    @MainActor
    @Test func multipleBufferedDeltasCoalesceInSingleFlush() async throws {
        let coalescer = DeltaCoalescer()
        var flushed: [[AgentEvent]] = []
        coalescer.onFlush = { flushed.append($0) }

        coalescer.receive(.textDelta(sessionId: "s1", delta: "a"))
        coalescer.receive(.thinkingDelta(sessionId: "s1", delta: "b"))
        coalescer.receive(.toolOutput(sessionId: "s1", toolEventId: "t1", output: "c", isError: false))

        try await Task.sleep(for: .milliseconds(80))

        #expect(flushed.count == 1)
        #expect(flushed[0].count == 3)
    }

    // MARK: - No onFlush handler

    @MainActor
    @Test func noOnFlushHandlerDoesNotCrash() {
        let coalescer = DeltaCoalescer()
        // onFlush is nil — should not crash
        coalescer.receive(.textDelta(sessionId: "s1", delta: "ignored"))
        coalescer.receive(.agentStart(sessionId: "s1"))
        coalescer.flushNow()
    }
}
