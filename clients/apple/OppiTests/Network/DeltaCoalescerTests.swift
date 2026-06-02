import Testing
import Foundation
@testable import Oppi

@Suite("DeltaCoalescer")
@MainActor
struct DeltaCoalescerTests {

    // MARK: - Immediate flush for non-delta events

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

    @Test func repeatedToolUpdateForSameToolIsBufferedAndCoalesced() {
        let coalescer = DeltaCoalescer()
        var flushed: [[AgentEvent]] = []
        coalescer.onFlush = { flushed.append($0) }

        coalescer.receive(.toolUpdate(
            sessionId: "s1", toolEventId: "t1", tool: "write", args: ["content": "a"]
        ))
        coalescer.receive(.toolUpdate(
            sessionId: "s1", toolEventId: "t1", tool: "write", args: ["content": "ab"]
        ))
        coalescer.receive(.toolUpdate(
            sessionId: "s1", toolEventId: "t1", tool: "write", args: ["content": "abc"]
        ))

        #expect(flushed.count == 1, "Only the initial toolUpdate should flush immediately")

        coalescer.flushNow()

        #expect(flushed.count == 2)
        #expect(flushed[1].count == 1)
        guard case .toolUpdate(_, _, _, let args, _) = flushed[1][0] else {
            Issue.record("Expected buffered toolUpdate")
            return
        }
        #expect(args["content"]?.stringValue == "abc")
    }

    @Test func toolStartAfterPreviewFlushesImmediately() {
        let coalescer = DeltaCoalescer()
        var flushed: [[AgentEvent]] = []
        coalescer.onFlush = { flushed.append($0) }

        coalescer.receive(.toolUpdate(
            sessionId: "s1", toolEventId: "t1", tool: "edit", args: ["path": "READ"]
        ))
        coalescer.receive(.toolUpdate(
            sessionId: "s1", toolEventId: "t1", tool: "edit", args: ["path": "README.md"]
        ))
        coalescer.receive(.toolStart(
            sessionId: "s1", toolEventId: "t1", tool: "edit", args: ["path": "README.md"]
        ))

        #expect(flushed.count == 3)
        guard case .toolUpdate(_, _, _, let previewArgs, _) = flushed[1][0] else {
            Issue.record("Expected buffered preview before toolStart")
            return
        }
        #expect(previewArgs["path"]?.stringValue == "README.md")
        guard case .toolStart = flushed[2][0] else {
            Issue.record("Expected immediate toolStart after preview")
            return
        }
    }

    @Test func toolEndFlushesImmediately() {
        let coalescer = DeltaCoalescer()
        var flushed: [[AgentEvent]] = []
        coalescer.onFlush = { flushed.append($0) }

        coalescer.receive(.toolEnd(sessionId: "s1", toolEventId: "t1"))

        #expect(flushed.count == 1)
    }

    @Test func toolEndFlushesBufferedToolUpdateBeforeEnding() {
        let coalescer = DeltaCoalescer()
        var flushed: [[AgentEvent]] = []
        coalescer.onFlush = { flushed.append($0) }

        coalescer.receive(.toolUpdate(
            sessionId: "s1", toolEventId: "t1", tool: "write", args: ["content": "a"]
        ))
        coalescer.receive(.toolUpdate(
            sessionId: "s1", toolEventId: "t1", tool: "write", args: ["content": "ab"]
        ))
        coalescer.receive(.toolEnd(sessionId: "s1", toolEventId: "t1"))

        #expect(flushed.count == 3)
        guard case .toolUpdate(_, _, _, let args, _) = flushed[1][0] else {
            Issue.record("Expected buffered toolUpdate before toolEnd")
            return
        }
        #expect(args["content"]?.stringValue == "ab")
        guard case .toolEnd = flushed[2][0] else {
            Issue.record("Expected final toolEnd flush")
            return
        }
    }

    @Test func agentStartFlushesImmediately() {
        let coalescer = DeltaCoalescer()
        var flushed: [[AgentEvent]] = []
        coalescer.onFlush = { flushed.append($0) }

        coalescer.receive(.agentStart(sessionId: "s1"))

        #expect(flushed.count == 1)
    }

    @Test func agentEndFlushesImmediately() {
        let coalescer = DeltaCoalescer()
        var flushed: [[AgentEvent]] = []
        coalescer.onFlush = { flushed.append($0) }

        coalescer.receive(.agentEnd(sessionId: "s1"))

        #expect(flushed.count == 1)
    }

    @Test func sessionEndedFlushesImmediately() {
        let coalescer = DeltaCoalescer()
        var flushed: [[AgentEvent]] = []
        coalescer.onFlush = { flushed.append($0) }

        coalescer.receive(.sessionEnded(sessionId: "s1", reason: "stopped"))

        #expect(flushed.count == 1)
    }

    @Test func errorFlushesImmediately() {
        let coalescer = DeltaCoalescer()
        var flushed: [[AgentEvent]] = []
        coalescer.onFlush = { flushed.append($0) }

        coalescer.receive(.error(sessionId: "s1", message: "boom"))

        #expect(flushed.count == 1)
    }

    // MARK: - Buffered deltas

    @Test func textDeltaIsBufferedNotImmediate() {
        let coalescer = DeltaCoalescer()
        var flushed: [[AgentEvent]] = []
        coalescer.onFlush = { flushed.append($0) }

        coalescer.receive(.textDelta(sessionId: "s1", delta: "hello"))

        // Should NOT have flushed yet (buffered for a short streaming tick)
        #expect(flushed.isEmpty)
    }

    @Test func thinkingDeltaIsBuffered() {
        let coalescer = DeltaCoalescer()
        var flushed: [[AgentEvent]] = []
        coalescer.onFlush = { flushed.append($0) }

        coalescer.receive(.thinkingDelta(sessionId: "s1", delta: "thinking..."))

        #expect(flushed.isEmpty)
    }

    @Test func toolOutputIsBuffered() {
        let coalescer = DeltaCoalescer()
        var flushed: [[AgentEvent]] = []
        coalescer.onFlush = { flushed.append($0) }

        coalescer.receive(.toolOutput(sessionId: "s1", toolEventId: "t1", output: "data", isError: false))

        #expect(flushed.isEmpty)
    }

    // MARK: - flushNow

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

    @Test func flushNowOnEmptyBufferIsNoOp() {
        let coalescer = DeltaCoalescer()
        var flushed: [[AgentEvent]] = []
        coalescer.onFlush = { flushed.append($0) }

        coalescer.flushNow()

        // Empty buffer should not call onFlush
        #expect(flushed.isEmpty)
    }

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

    @Test func immediateEventPreservesMixedDeltaOrderingWithinFlush() {
        let coalescer = DeltaCoalescer()
        var flushed: [[AgentEvent]] = []
        coalescer.onFlush = { flushed.append($0) }

        coalescer.receive(.textDelta(sessionId: "s1", delta: "a"))
        coalescer.receive(.thinkingDelta(sessionId: "s1", delta: "b"))
        coalescer.receive(.toolOutput(sessionId: "s1", toolEventId: "t1", output: "c", isError: false))

        coalescer.receive(.toolStart(
            sessionId: "s1",
            toolEventId: "t1",
            tool: "bash",
            args: ["command": "echo hi"]
        ))

        #expect(flushed.count == 2)
        #expect(flushed[0].map(\.typeLabel) == ["textDelta", "thinkingDelta", "toolOutput"])
        #expect(flushed[1].map(\.typeLabel) == ["toolStart"])
    }

    @Test func maxBufferedEventCountForcesDeterministicFlush() {
        let coalescer = DeltaCoalescer()
        var flushed: [[AgentEvent]] = []
        coalescer.onFlush = { flushed.append($0) }

        for _ in 0..<512 {
            coalescer.receive(.textDelta(sessionId: "s1", delta: "x"))
        }

        #expect(flushed.count == 1)
        #expect(flushed[0].count == 512)
    }

    @Test func maxBufferedBytesForcesDeterministicFlush() {
        let coalescer = DeltaCoalescer()
        var flushed: [[AgentEvent]] = []
        coalescer.onFlush = { flushed.append($0) }

        let oversized = String(repeating: "z", count: (256 * 1024) + 8)
        coalescer.receive(.textDelta(sessionId: "s1", delta: oversized))

        #expect(flushed.count == 1)
        #expect(flushed[0].count == 1)
        guard case .textDelta(_, let payload) = flushed[0][0] else {
            Issue.record("Expected textDelta payload")
            return
        }
        #expect(payload.count == oversized.count)
    }

    // MARK: - Timer-based flush

    @Test func bufferedDeltasFlushAfterInterval() async {
        let coalescer = DeltaCoalescer()
        var flushed: [[AgentEvent]] = []
        coalescer.onFlush = { flushed.append($0) }

        coalescer.receive(.textDelta(sessionId: "s1", delta: "delayed"))

        let didFlush = await waitForMainActorCondition(timeout: .milliseconds(300), poll: .milliseconds(10)) {
            flushed.count == 1
        }

        #expect(didFlush)
        #expect(flushed.count == 1)
        #expect(flushed[0].count == 1)
    }

    @Test func multipleBufferedDeltasCoalesceInSingleFlush() async {
        let coalescer = DeltaCoalescer()
        var flushed: [[AgentEvent]] = []
        coalescer.onFlush = { flushed.append($0) }

        coalescer.receive(.textDelta(sessionId: "s1", delta: "a"))
        coalescer.receive(.thinkingDelta(sessionId: "s1", delta: "b"))
        coalescer.receive(.toolOutput(sessionId: "s1", toolEventId: "t1", output: "c", isError: false))

        let didFlush = await waitForMainActorCondition(timeout: .milliseconds(300), poll: .milliseconds(10)) {
            flushed.count == 1
        }

        #expect(didFlush)
        #expect(flushed.count == 1)
        #expect(flushed[0].count == 3)
    }

    // MARK: - No onFlush handler

    @Test func noOnFlushHandlerDoesNotCrash() {
        let coalescer = DeltaCoalescer()
        // onFlush is nil — should not crash
        coalescer.receive(.textDelta(sessionId: "s1", delta: "ignored"))
        coalescer.receive(.agentStart(sessionId: "s1"))
        coalescer.flushNow()
    }
}
