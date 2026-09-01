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

        coalescer.receive(.toolOutput(.init(sessionId: "s1", toolEventId: "t1", output: "data", isError: false)))

        #expect(flushed.isEmpty)
    }

    @Test func consecutiveReplaceToolOutputsKeepLatestSnapshotAndStickyMetadata() {
        let coalescer = DeltaCoalescer()
        var flushed: [[AgentEvent]] = []
        coalescer.onFlush = { flushed.append($0) }
        let firstDetails = JSONValue.object(["phase": .string("first")])

        coalescer.receive(.toolOutput(.init(
            sessionId: "s1",
            toolEventId: "t1",
            output: "first",
            isError: true,
            mode: .replace,
            truncated: true,
            totalBytes: 100,
            details: firstDetails
        )))
        coalescer.receive(.toolOutput(.init(
            sessionId: "s1",
            toolEventId: "t1",
            output: "latest",
            isError: false,
            mode: .replace,
            truncated: false,
            totalBytes: 200
        )))
        coalescer.flushNow()

        #expect(flushed.count == 1)
        #expect(flushed[0].count == 1)
        guard case .toolOutput(let payload) = flushed[0][0] else {
            Issue.record("Expected toolOutput")
            return
        }
        #expect(payload.output == "latest")
        #expect(payload.mode == .replace)
        #expect(payload.isError)
        #expect(payload.details == firstDetails)
        #expect(!payload.truncated)
        #expect(payload.totalBytes == 200)
    }

    @Test func replaceToolOutputDoesNotCrossOrderingBarriers() {
        let coalescer = DeltaCoalescer()
        var flushed: [[AgentEvent]] = []
        coalescer.onFlush = { flushed.append($0) }

        coalescer.receive(.toolOutput(.init(
            sessionId: "s1", toolEventId: "t1", output: "t1-first",
            isError: false, mode: .replace
        )))
        coalescer.receive(.toolOutput(.init(
            sessionId: "s1", toolEventId: "t2", output: "t2",
            isError: false, mode: .replace
        )))
        coalescer.receive(.toolOutput(.init(
            sessionId: "s1", toolEventId: "t1", output: "t1-latest",
            isError: false, mode: .replace
        )))
        coalescer.flushNow()

        let outputs = flushed.flatMap { $0 }.compactMap { event -> String? in
            guard case .toolOutput(let payload) = event else { return nil }
            return payload.output
        }
        #expect(outputs == ["t1-first", "t2", "t1-latest"])
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
        coalescer.receive(.toolOutput(.init(sessionId: "s1", toolEventId: "t1", output: "c", isError: false)))

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
        coalescer.flushNow()

        #expect(flushed.count == 2)
        #expect(flushed[0].count == 1)
        #expect(flushed[1].count == 1)
        let payload = flushed.flatMap { $0 }.compactMap { event -> String? in
            guard case .textDelta(_, let payload, _) = event else { return nil }
            return payload
        }.joined()
        #expect(payload == oversized)
    }

    @Test func oversizedAppendPayloadsAreChunkedBeforeTimelineFlush() {
        let coalescer = DeltaCoalescer()
        var flushed: [[AgentEvent]] = []
        coalescer.onFlush = { flushed.append($0) }

        let oversized = String(repeating: "z", count: (DeltaCoalescer.maxBufferedBytesForTesting * 2) + 17)
        coalescer.receive(.toolOutput(.init(sessionId: "s1", toolEventId: "t1", output: oversized, isError: false)))
        coalescer.flushNow()

        let outputs = flushed.flatMap { $0 }.compactMap { event -> String? in
            guard case .toolOutput(let payload) = event else { return nil }
            #expect(payload.output.utf8.count <= DeltaCoalescer.maxBufferedBytesForTesting)
            return payload.output
        }
        #expect(outputs.count == 3)
        #expect(outputs.joined() == oversized)
    }

    // MARK: - Paused presentation

    @Test func pauseBlocksImmediateEventsUntilResume() {
        let coalescer = DeltaCoalescer()
        var flushed: [[AgentEvent]] = []
        coalescer.onFlush = { flushed.append($0) }

        coalescer.pause()
        coalescer.receive(.toolStart(
            sessionId: "s1", toolEventId: "t1", tool: "bash", args: ["command": "ls"]
        ))
        coalescer.receive(.toolEnd(sessionId: "s1", toolEventId: "t1"))

        #expect(flushed.isEmpty)

        let requiresReload = coalescer.resume()

        #expect(!requiresReload)
        #expect(flushed.count == 1)
        #expect(flushed[0].map(\.typeLabel) == ["toolStart", "toolEnd"])
    }

    @Test func pauseBlocksBufferCapFlushUntilResume() {
        let coalescer = DeltaCoalescer()
        var flushed: [[AgentEvent]] = []
        coalescer.onFlush = { flushed.append($0) }

        coalescer.pause()
        for _ in 0..<512 {
            coalescer.receive(.textDelta(sessionId: "s1", delta: "x"))
        }

        #expect(flushed.isEmpty)

        let requiresReload = coalescer.resume()

        #expect(!requiresReload)
        #expect(flushed.count == 1)
        #expect(flushed[0].count == 512)
    }

    @Test func pausedBufferOverflowRequestsTraceReloadWithoutPublishing() {
        let coalescer = DeltaCoalescer()
        var flushed: [[AgentEvent]] = []
        coalescer.onFlush = { flushed.append($0) }

        coalescer.pause()
        for _ in 0...512 {
            coalescer.receive(.textDelta(sessionId: "s1", delta: "x"))
        }

        #expect(flushed.isEmpty)
        #expect(coalescer.resume())
        #expect(flushed.isEmpty)
    }

    @Test func resumeDeliversPausedStateOnce() {
        let coalescer = DeltaCoalescer()
        var flushed: [[AgentEvent]] = []
        coalescer.onFlush = { flushed.append($0) }

        coalescer.pause()
        coalescer.receive(.textDelta(sessionId: "s1", delta: "a"))
        coalescer.receive(.textDelta(sessionId: "s1", delta: "b"))
        coalescer.receive(.textDelta(sessionId: "s1", delta: "c"))

        #expect(flushed.isEmpty)
        #expect(!coalescer.resume())
        #expect(flushed.count == 1)
        #expect(flushed[0].count == 3)

        #expect(!coalescer.resume())
        #expect(flushed.count == 1)
    }

    @Test func pausedToolStartIsNotReplacedByToolUpdate() {
        let coalescer = DeltaCoalescer()
        let reducer = TimelineReducer()
        var flushed: [[AgentEvent]] = []
        coalescer.onFlush = { events in
            flushed.append(events)
            reducer.processBatch(events)
        }

        coalescer.pause()
        coalescer.receive(.toolStart(
            sessionId: "s1", toolEventId: "t1", tool: "bash", args: ["command": .string("ls")]
        ))
        coalescer.receive(.toolUpdate(
            sessionId: "s1", toolEventId: "t1", tool: "bash", args: ["command": .string("ls -la")]
        ))

        #expect(flushed.isEmpty)
        #expect(!coalescer.resume())
        #expect(flushed.count == 1)
        #expect(flushed[0].map(\.typeLabel) == ["toolStart", "toolUpdate"])
        #expect(
            reducer.toolStartTime(for: "t1") != nil,
            "Resume must deliver toolStart so the reducer records elapsed start time"
        )
    }

    @Test func pausedToolUpdateStillCoalescesAfterRetainedToolStart() {
        let coalescer = DeltaCoalescer()
        var flushed: [[AgentEvent]] = []
        coalescer.onFlush = { flushed.append($0) }

        coalescer.pause()
        coalescer.receive(.toolStart(
            sessionId: "s1", toolEventId: "t1", tool: "write", args: ["content": .string("a")]
        ))
        coalescer.receive(.toolUpdate(
            sessionId: "s1", toolEventId: "t1", tool: "write", args: ["content": .string("ab")]
        ))
        coalescer.receive(.toolUpdate(
            sessionId: "s1", toolEventId: "t1", tool: "write", args: ["content": .string("abc")]
        ))

        #expect(!coalescer.resume())
        #expect(flushed.count == 1)
        #expect(flushed[0].map(\.typeLabel) == ["toolStart", "toolUpdate"])
        guard case .toolUpdate(_, _, _, let args, _) = flushed[0][1] else {
            Issue.record("Expected coalesced toolUpdate after retained toolStart")
            return
        }
        #expect(args["content"]?.stringValue == "abc")
    }

    @Test func pausedPreviewAndExecutionToolUpdatesPreserveLifecycleOrdering() {
        let coalescer = DeltaCoalescer()
        var flushed: [[AgentEvent]] = []
        coalescer.onFlush = { flushed.append($0) }

        coalescer.pause()
        coalescer.receive(.toolUpdate(
            sessionId: "s1", toolEventId: "t1", tool: "write",
            args: ["content": .string("preview")]
        ))
        coalescer.receive(.toolStart(
            sessionId: "s1", toolEventId: "t1", tool: "write",
            args: ["content": .string("started")]
        ))
        coalescer.receive(.toolUpdate(
            sessionId: "s1", toolEventId: "t1", tool: "write",
            args: ["content": .string("after-start-1")]
        ))
        coalescer.receive(.toolUpdate(
            sessionId: "s1", toolEventId: "t1", tool: "write",
            args: ["content": .string("after-start-2")]
        ))

        #expect(!coalescer.resume())
        #expect(flushed.count == 1)
        #expect(flushed[0].map(\.typeLabel) == ["toolUpdate", "toolStart", "toolUpdate"])

        guard case .toolUpdate(_, _, _, let previewArgs, _) = flushed[0][0],
              case .toolStart = flushed[0][1],
              case .toolUpdate(_, _, _, let finalArgs, _) = flushed[0][2] else {
            Issue.record("Expected preview, toolStart, and post-start toolUpdate ordering")
            return
        }
        #expect(previewArgs["content"]?.stringValue == "preview")
        #expect(finalArgs["content"]?.stringValue == "after-start-2")
    }

    @Test func pausedTerminalPayloadsCountTowardByteBoundary() {
        let factories: [(name: String, make: (String) -> AgentEvent)] = [
            ("messageEnd", { payload in
                .messageEnd(sessionId: "s1", content: payload)
            }),
            ("toolEnd.details", { payload in
                .toolEnd(
                    sessionId: "s1",
                    toolEventId: "t1",
                    details: .object(["payload": .string(payload)])
                )
            }),
            ("toolEnd.resultSegments", { payload in
                .toolEnd(
                    sessionId: "s1",
                    toolEventId: "t1",
                    resultSegments: [StyledSegment(text: payload, style: .error)]
                )
            }),
            ("commandResult.data", { payload in
                .commandResult(
                    sessionId: "s1",
                    command: "get_stats",
                    requestId: "r1",
                    success: true,
                    data: .object(["payload": .string(payload)]),
                    error: nil
                )
            }),
            ("commandResult.error", { payload in
                .commandResult(
                    sessionId: "s1",
                    command: "get_stats",
                    requestId: "r1",
                    success: false,
                    data: nil,
                    error: payload
                )
            }),
            ("error", { payload in
                .error(sessionId: "s1", message: payload)
            }),
        ]

        let underLimitPayloadBytes = DeltaCoalescer.maxBufferedBytesForTesting - 1_024
        for testCase in factories {
            let underLimit = DeltaCoalescer()
            underLimit.pause()
            underLimit.receive(testCase.make(String(repeating: "u", count: underLimitPayloadBytes)))
            #expect(
                !underLimit.needsPresentationTraceReload,
                "\(testCase.name) should fit below the paused byte cap"
            )

            let overLimit = DeltaCoalescer()
            overLimit.pause()
            overLimit.receive(testCase.make(String(repeating: "o", count: DeltaCoalescer.maxBufferedBytesForTesting + 1)))
            #expect(
                overLimit.needsPresentationTraceReload,
                "\(testCase.name) must arm reload above the paused byte cap"
            )
        }
    }

    @Test func pausedByteCapOverflowRequestsTraceReloadWithoutPublishing() {
        let coalescer = DeltaCoalescer()
        var flushed: [[AgentEvent]] = []
        coalescer.onFlush = { flushed.append($0) }

        coalescer.pause()
        let oversized = String(repeating: "z", count: DeltaCoalescer.maxBufferedBytesForTesting + 1)
        coalescer.receive(.textDelta(sessionId: "s1", delta: oversized))

        #expect(flushed.isEmpty)
        #expect(coalescer.needsPresentationTraceReload)
        #expect(coalescer.resume())
        #expect(flushed.isEmpty)
        #expect(
            coalescer.needsPresentationTraceReload,
            "Overflow reload stays armed until an authoritative history apply acknowledges it"
        )
    }

    @Test func eventsAfterPausedOverflowAreDroppedUntilResumeAcknowledged() {
        let coalescer = DeltaCoalescer()
        var flushed: [[AgentEvent]] = []
        coalescer.onFlush = { flushed.append($0) }

        coalescer.pause()
        for _ in 0...512 {
            coalescer.receive(.textDelta(sessionId: "s1", delta: "x"))
        }
        coalescer.receive(.toolStart(
            sessionId: "s1", toolEventId: "t1", tool: "bash", args: ["command": .string("ls")]
        ))
        coalescer.receive(.textDelta(sessionId: "s1", delta: "after-overflow"))

        #expect(flushed.isEmpty)
        #expect(coalescer.resume())
        #expect(flushed.isEmpty)

        // Still armed: further resume attempts keep requesting reload.
        #expect(coalescer.resume())
        coalescer.acknowledgePresentationTraceReload()
        #expect(!coalescer.needsPresentationTraceReload)
        #expect(!coalescer.resume())
    }

    @Test func markPresentationNeedsTraceReloadWhilePausedSurvivesFailedResumeUntilAck() {
        let coalescer = DeltaCoalescer()
        var flushed: [[AgentEvent]] = []
        coalescer.onFlush = { flushed.append($0) }

        coalescer.pause()
        coalescer.receive(.textDelta(sessionId: "s1", delta: "buffered"))
        coalescer.markPresentationNeedsTraceReload()

        #expect(coalescer.resume())
        #expect(flushed.isEmpty)
        #expect(coalescer.needsPresentationTraceReload)

        coalescer.acknowledgePresentationTraceReload()
        #expect(!coalescer.resume())
        #expect(flushed.isEmpty)
    }

    @Test func staleHistoryAcknowledgementDoesNotClearNewerPausedMutation() {
        let coalescer = DeltaCoalescer()
        coalescer.pause()
        let fetchMarker = coalescer.presentationTraceReloadMarker

        coalescer.markPresentationNeedsTraceReload()
        coalescer.acknowledgePresentationTraceReload(ifMarker: fetchMarker)

        #expect(coalescer.needsPresentationTraceReload)
    }

    // MARK: - Timer-based flush

    @Test func pauseBlocksTimerFlushUntilResume() async {
        let coalescer = DeltaCoalescer()
        var flushed: [[AgentEvent]] = []
        coalescer.onFlush = { flushed.append($0) }

        coalescer.receive(.textDelta(sessionId: "s1", delta: "delayed"))
        coalescer.pause()

        try? await Task.sleep(for: .milliseconds(120))
        #expect(flushed.isEmpty)

        #expect(!coalescer.resume())
        #expect(flushed.count == 1)
    }

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
        coalescer.receive(.toolOutput(.init(sessionId: "s1", toolEventId: "t1", output: "c", isError: false)))

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

    // MARK: - Telemetry

    @Test func telemetrySinkReceivesFlushWindowWhenDrainHasSignal() async {
        let recorder = DeltaCoalescerTelemetryRecorder()
        let coalescer = DeltaCoalescer(telemetry: .init(
            recordFlushWindow: { window in
                await recorder.record(window)
            }
        ))
        coalescer.sessionId = "s1"

        coalescer.receive(.textDelta(sessionId: "s1", delta: String(repeating: "x", count: 70 * 1024)))
        coalescer.flushNow()

        let didRecord = await waitForTestCondition(timeout: .milliseconds(500), poll: .milliseconds(10)) {
            await recorder.flushWindowCount() == 1
        }
        #expect(didRecord)

        let window = await recorder.firstFlushWindow()
        #expect(window?.sessionId == "s1")
        #expect(window?.eventCount == 1)
        #expect(window?.byteCount == 70 * 1024)
        #expect(window?.flushCount == 1)
    }

    @Test func telemetrySinkReceivesOversizedTimelinePayload() async {
        let recorder = DeltaCoalescerTelemetryRecorder()
        let coalescer = DeltaCoalescer(telemetry: .init(
            recordLargeTimelinePayload: { payload in
                Task { await recorder.record(payload) }
            }
        ))

        let oversized = String(repeating: "z", count: DeltaCoalescer.maxBufferedBytesForTesting + 1)
        coalescer.receive(.textDelta(sessionId: "s1", delta: oversized))

        let didRecord = await waitForTestCondition(timeout: .milliseconds(500), poll: .milliseconds(10)) {
            await recorder.largePayloadCount() == 1
        }
        #expect(didRecord)

        let payload = await recorder.firstLargePayload()
        #expect(payload?.sessionId == "s1")
        #expect(payload?.eventCount == 1)
        #expect(payload?.byteCount == oversized.utf8.count)
        #expect(payload?.largestEventByteCount == oversized.utf8.count)
    }
}

private actor DeltaCoalescerTelemetryRecorder {
    private var flushWindows: [DeltaCoalescerFlushWindow] = []
    private var largePayloads: [DeltaCoalescerLargeTimelinePayload] = []

    func record(_ window: DeltaCoalescerFlushWindow) {
        flushWindows.append(window)
    }

    func record(_ payload: DeltaCoalescerLargeTimelinePayload) {
        largePayloads.append(payload)
    }

    func flushWindowCount() -> Int {
        flushWindows.count
    }

    func firstFlushWindow() -> DeltaCoalescerFlushWindow? {
        flushWindows.first
    }

    func largePayloadCount() -> Int {
        largePayloads.count
    }

    func firstLargePayload() -> DeltaCoalescerLargeTimelinePayload? {
        largePayloads.first
    }
}
