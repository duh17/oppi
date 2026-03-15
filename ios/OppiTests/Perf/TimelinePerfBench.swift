import Testing
import Foundation
@testable import Oppi

// MARK: - Timeline Performance Benchmarks

/// Micro-benchmarks for the iOS timeline hot path:
/// TimelineReducer.processBatch(), DeltaCoalescer, and markdown pipeline.
///
/// Each benchmark runs N iterations, discards the first warmup iteration,
/// and reports the median of the remaining runs. Output format:
///   METRIC name=number
/// for consumption by the autoresearch extension.
@Suite("TimelinePerfBench")
@MainActor
struct TimelinePerfBench {

    // MARK: - Configuration

    /// Number of timed iterations per benchmark (after warmup).
    private static let iterations = 20
    /// Number of warmup iterations (not counted).
    private static let warmupIterations = 3

    // MARK: - Timing Infrastructure

    private static func measureMedianUs(
        setup: () -> Void = {},
        _ block: () -> Void
    ) -> Double {
        var timings: [UInt64] = []
        timings.reserveCapacity(iterations + warmupIterations)

        for i in 0 ..< (warmupIterations + iterations) {
            setup()
            let start = DispatchTime.now().uptimeNanoseconds
            block()
            let end = DispatchTime.now().uptimeNanoseconds
            if i >= warmupIterations {
                timings.append(end &- start)
            }
        }

        timings.sort()
        let median = timings[timings.count / 2]
        return Double(median) / 1000.0 // ns → μs
    }

    // MARK: - Realistic Event Generators

    /// Simulate a realistic streaming turn: thinking → 50 text deltas → 5 tool calls with output.
    private static func realisticStreamingTurn(sessionId: String = "bench") -> [AgentEvent] {
        var events: [AgentEvent] = []
        events.reserveCapacity(200)

        events.append(.agentStart(sessionId: sessionId))

        // 10 thinking deltas
        for i in 0..<10 {
            events.append(.thinkingDelta(
                sessionId: sessionId,
                delta: "Analyzing the problem step \(i). Let me think about the approach carefully and consider multiple angles. "
            ))
        }

        // 50 text deltas (typical LLM streaming)
        for i in 0..<50 {
            events.append(.textDelta(
                sessionId: sessionId,
                delta: textDeltaChunk(index: i)
            ))
        }

        // 5 tool calls with output
        for t in 0..<5 {
            let toolId = "tool-\(t)"
            let args: [String: JSONValue] = [
                "command": .string("echo 'Running test \(t)'"),
                "path": .string("/Users/dev/project/src/file\(t).swift"),
            ]
            events.append(.toolStart(
                sessionId: sessionId,
                toolEventId: toolId,
                tool: t % 2 == 0 ? "bash" : "read",
                args: args
            ))

            // 3 output chunks per tool
            for c in 0..<3 {
                events.append(.toolOutput(
                    sessionId: sessionId,
                    toolEventId: toolId,
                    output: toolOutputChunk(toolIndex: t, chunkIndex: c),
                    isError: false
                ))
            }

            events.append(.toolEnd(
                sessionId: sessionId,
                toolEventId: toolId,
                isError: false
            ))
        }

        events.append(.agentEnd(sessionId: sessionId))
        return events
    }

    /// Simulate a heavy text-only streaming turn (100 deltas, long response).
    private static func heavyTextTurn(sessionId: String = "bench") -> [AgentEvent] {
        var events: [AgentEvent] = []
        events.reserveCapacity(110)

        events.append(.agentStart(sessionId: sessionId))

        for i in 0..<100 {
            events.append(.textDelta(
                sessionId: sessionId,
                delta: textDeltaChunk(index: i)
            ))
        }

        events.append(.agentEnd(sessionId: sessionId))
        return events
    }

    /// Generate a batch of text deltas only (coalescer hot path).
    private static func textDeltaBatch(count: Int, sessionId: String = "bench") -> [AgentEvent] {
        (0..<count).map { i in
            .textDelta(sessionId: sessionId, delta: textDeltaChunk(index: i))
        }
    }

    /// Generate a batch of tool output deltas (coalescer hot path).
    private static func toolOutputBatch(count: Int, toolId: String = "tool-0", sessionId: String = "bench") -> [AgentEvent] {
        (0..<count).map { i in
            .toolOutput(
                sessionId: sessionId,
                toolEventId: toolId,
                output: "Line \(i): processing result with some typical output data\n",
                isError: false
            )
        }
    }

    /// Build trace events for a realistic session history (session resume scenario).
    private static func realisticTraceHistory(turnCount: Int) -> [TraceEvent] {
        var events: [TraceEvent] = []
        let baseDate = "2026-03-15T10:00:00.000Z"

        for turn in 0..<turnCount {
            // User message
            events.append(TraceEvent(
                id: "user-\(turn)",
                type: .user,
                timestamp: baseDate,
                text: "Please analyze the code in file\(turn).swift and suggest improvements for performance and readability.",
                tool: nil, args: nil, output: nil, toolCallId: nil, toolName: nil, isError: nil, thinking: nil
            ))

            // Thinking
            events.append(TraceEvent(
                id: "thinking-\(turn)",
                type: .thinking,
                timestamp: baseDate,
                text: nil, tool: nil, args: nil, output: nil, toolCallId: nil, toolName: nil, isError: nil,
                thinking: "Let me analyze the code structure and identify areas for improvement. The key patterns to look for include unnecessary allocations, closure captures, and hot loop inefficiencies."
            ))

            // Assistant response
            let responseText = generateAssistantResponse(turnIndex: turn)
            events.append(TraceEvent(
                id: "assistant-\(turn)",
                type: .assistant,
                timestamp: baseDate,
                text: responseText,
                tool: nil, args: nil, output: nil, toolCallId: nil, toolName: nil, isError: nil, thinking: nil
            ))

            // 2 tool calls per turn
            for t in 0..<2 {
                let toolCallId = "tc-\(turn)-\(t)"
                events.append(TraceEvent(
                    id: toolCallId,
                    type: .toolCall,
                    timestamp: baseDate,
                    text: nil,
                    tool: "bash",
                    args: ["command": .string("cat src/file\(turn)_\(t).swift")],
                    output: nil, toolCallId: nil, toolName: nil, isError: nil, thinking: nil
                ))

                events.append(TraceEvent(
                    id: "tr-\(turn)-\(t)",
                    type: .toolResult,
                    timestamp: baseDate,
                    text: nil, tool: nil, args: nil,
                    output: String(repeating: "import Foundation\nlet x = \(turn)\n", count: 20),
                    toolCallId: toolCallId,
                    toolName: "bash",
                    isError: false, thinking: nil
                ))
            }
        }

        return events
    }

    // MARK: - Text Fixtures

    private static func textDeltaChunk(index: Int) -> String {
        // Varied realistic text: markdown, code snippets, prose
        switch index % 8 {
        case 0: return "Here's the analysis of the "
        case 1: return "code structure. The main "
        case 2: return "issue is in the `processBatch` "
        case 3: return "method where **closures** are "
        case 4: return "allocated on every iteration.\n\n"
        case 5: return "```swift\nfunc optimized() {\n"
        case 6: return "    let result = buffer.joined()\n"
        case 7: return "}\n```\n\nThis reduces allocations.\n\n"
        default: return "text "
        }
    }

    private static func toolOutputChunk(toolIndex: Int, chunkIndex: Int) -> String {
        switch chunkIndex {
        case 0: return "$ Running command for tool \(toolIndex)...\n"
        case 1: return String(repeating: "  processing line \(toolIndex)\n", count: 10)
        case 2: return "Done. \(toolIndex * 100) items processed.\n"
        default: return "output\n"
        }
    }

    private static func generateAssistantResponse(turnIndex: Int) -> String {
        """
        I've analyzed the code in file\(turnIndex).swift. Here are the key findings:

        ## Performance Issues

        1. **Closure allocation in hot loop** — The `process` method creates a new closure on every iteration.
        2. **String concatenation** — Using `+=` in a loop creates O(n²) copies.

        ## Suggested Fix

        ```swift
        func optimized() {
            var parts: [String] = []
            parts.reserveCapacity(items.count)
            for item in items {
                parts.append(item.description)
            }
            return parts.joined()
        }
        ```

        This reduces the time complexity from O(n²) to O(n).
        """
    }

    // MARK: - Benchmark: processBatch (Realistic Streaming Turn)

    @Test("processBatch: realistic streaming turn")
    func processBatchRealisticTurn() {
        let events = Self.realisticStreamingTurn()
        var reducer: TimelineReducer!

        let us = Self.measureMedianUs(
            setup: { reducer = TimelineReducer() },
            { reducer.processBatch(events) }
        )

        print("METRIC processBatch_realistic_us=\(String(format: "%.1f", us))")
        // Sanity: should produce items
        #expect(!reducer.items.isEmpty)
    }

    // MARK: - Benchmark: processBatch (Text-Only Heavy)

    @Test("processBatch: heavy text turn (100 deltas)")
    func processBatchHeavyText() {
        let events = Self.heavyTextTurn()
        var reducer: TimelineReducer!

        let us = Self.measureMedianUs(
            setup: { reducer = TimelineReducer() },
            { reducer.processBatch(events) }
        )

        print("METRIC processBatch_text_us=\(String(format: "%.1f", us))")
        #expect(!reducer.items.isEmpty)
    }

    // MARK: - Benchmark: processBatch (Text Delta Batch Only)

    @Test("processBatch: 50 text deltas (coalesced batch)")
    func processBatchTextDeltas() {
        let batch = Self.textDeltaBatch(count: 50)
        var reducer: TimelineReducer!

        let us = Self.measureMedianUs(
            setup: {
                reducer = TimelineReducer()
                // Start a turn so deltas have context
                reducer.processBatch([.agentStart(sessionId: "bench")])
            },
            { reducer.processBatch(batch) }
        )

        print("METRIC processBatch_deltas_us=\(String(format: "%.1f", us))")
        #expect(!reducer.items.isEmpty)
    }

    // MARK: - Benchmark: processBatch (Tool Output Batch)

    @Test("processBatch: 20 tool output chunks")
    func processBatchToolOutput() {
        let batch = Self.toolOutputBatch(count: 20)
        var reducer: TimelineReducer!

        let us = Self.measureMedianUs(
            setup: {
                reducer = TimelineReducer()
                reducer.processBatch([
                    .agentStart(sessionId: "bench"),
                    .toolStart(sessionId: "bench", toolEventId: "tool-0", tool: "bash", args: ["command": .string("ls")]),
                ])
            },
            { reducer.processBatch(batch) }
        )

        print("METRIC processBatch_tooloutput_us=\(String(format: "%.1f", us))")
    }

    // MARK: - Benchmark: loadSession (History Rebuild)

    @Test("loadSession: 10-turn history rebuild")
    func loadSession10Turns() {
        let trace = Self.realisticTraceHistory(turnCount: 10)
        var reducer: TimelineReducer!

        let us = Self.measureMedianUs(
            setup: { reducer = TimelineReducer() },
            { reducer.loadSession(trace) }
        )

        print("METRIC loadSession_10turns_us=\(String(format: "%.1f", us))")
        #expect(!reducer.items.isEmpty)
    }

    // MARK: - Benchmark: loadSession (Large History)

    @Test("loadSession: 50-turn history rebuild")
    func loadSession50Turns() {
        let trace = Self.realisticTraceHistory(turnCount: 50)
        var reducer: TimelineReducer!

        let us = Self.measureMedianUs(
            setup: { reducer = TimelineReducer() },
            { reducer.loadSession(trace) }
        )

        print("METRIC loadSession_50turns_us=\(String(format: "%.1f", us))")
        #expect(!reducer.items.isEmpty)
    }

    // MARK: - Benchmark: loadSession Incremental (Append-Only)

    @Test("loadSession: incremental append (5 new events)")
    func loadSessionIncremental() {
        let baseTurns = 10
        let baseTrace = Self.realisticTraceHistory(turnCount: baseTurns)
        let extendedTrace = Self.realisticTraceHistory(turnCount: baseTurns + 1)

        var reducer: TimelineReducer!

        let us = Self.measureMedianUs(
            setup: {
                reducer = TimelineReducer()
                reducer.loadSession(baseTrace)
            },
            { reducer.loadSession(extendedTrace) }
        )

        print("METRIC loadSession_incremental_us=\(String(format: "%.1f", us))")
        #expect(reducer._lastLoadWasIncrementalForTesting)
    }

    // MARK: - Benchmark: DeltaCoalescer Throughput

    @Test("DeltaCoalescer: receive 100 text deltas")
    func coalescerReceive() {
        let events: [AgentEvent] = (0..<100).map { i in
            .textDelta(sessionId: "bench", delta: Self.textDeltaChunk(index: i))
        }

        var coalescer: DeltaCoalescer!
        var flushedCount = 0

        let us = Self.measureMedianUs(
            setup: {
                coalescer = DeltaCoalescer()
                flushedCount = 0
                coalescer.onFlush = { batch in flushedCount += batch.count }
            },
            {
                for event in events {
                    coalescer.receive(event)
                }
                coalescer.flushNow()
            }
        )

        print("METRIC coalescer_receive_us=\(String(format: "%.1f", us))")
        #expect(flushedCount == 100)
    }

    // MARK: - Benchmark: DeltaCoalescer Mixed Events

    @Test("DeltaCoalescer: mixed event types (text + tools + output)")
    func coalescerMixed() {
        var events: [AgentEvent] = []
        events.append(.agentStart(sessionId: "bench"))
        for i in 0..<20 {
            events.append(.textDelta(sessionId: "bench", delta: Self.textDeltaChunk(index: i)))
        }
        events.append(.toolStart(sessionId: "bench", toolEventId: "t1", tool: "bash", args: [:]))
        for i in 0..<10 {
            events.append(.toolOutput(
                sessionId: "bench",
                toolEventId: "t1",
                output: "line \(i)\n",
                isError: false
            ))
        }
        events.append(.toolEnd(sessionId: "bench", toolEventId: "t1"))
        events.append(.agentEnd(sessionId: "bench"))

        var coalescer: DeltaCoalescer!
        var totalFlushed = 0

        let us = Self.measureMedianUs(
            setup: {
                coalescer = DeltaCoalescer()
                totalFlushed = 0
                coalescer.onFlush = { batch in totalFlushed += batch.count }
            },
            {
                for event in events {
                    coalescer.receive(event)
                }
                coalescer.flushNow()
            }
        )

        print("METRIC coalescer_mixed_us=\(String(format: "%.1f", us))")
        #expect(totalFlushed == events.count)
    }

    // MARK: - Benchmark: ItemIndex Lookup

    @Test("ItemIndex: 200 lookups in 100-item timeline")
    func itemIndexLookup() {
        let reducer = TimelineReducer()
        let events = Self.realisticStreamingTurn()
        reducer.processBatch(events)

        let ids = reducer.items.map(\.id)
        let itemCount = ids.count
        #expect(itemCount > 0)

        // Measure lookup speed through processBatch (exercises indexForID internally)
        // by replaying the same events through an already-populated reducer
        let replayEvents = Self.realisticStreamingTurn()

        let us = Self.measureMedianUs {
            reducer.processBatch(replayEvents)
        }

        print("METRIC index_replay_us=\(String(format: "%.1f", us))")
    }

    // MARK: - Aggregate Primary Metric

    @Test("Aggregate: total hot-path cost")
    func aggregateMetric() {
        // Run all sub-benchmarks and sum for primary metric
        let events = Self.realisticStreamingTurn()
        let heavyEvents = Self.heavyTextTurn()
        let deltasBatch = Self.textDeltaBatch(count: 50)
        let toolBatch = Self.toolOutputBatch(count: 20)
        let trace10 = Self.realisticTraceHistory(turnCount: 10)
        let trace50 = Self.realisticTraceHistory(turnCount: 50)
        let coalescerEvents: [AgentEvent] = (0..<100).map { i in
            .textDelta(sessionId: "bench", delta: TimelinePerfBench.textDeltaChunk(index: i))
        }

        // processBatch_realistic
        var r1: TimelineReducer!
        let processBatchRealistic = Self.measureMedianUs(
            setup: { r1 = TimelineReducer() },
            { r1.processBatch(events) }
        )

        // processBatch_text
        var r2: TimelineReducer!
        let processBatchText = Self.measureMedianUs(
            setup: { r2 = TimelineReducer() },
            { r2.processBatch(heavyEvents) }
        )

        // processBatch_deltas
        var r3: TimelineReducer!
        let processBatchDeltas = Self.measureMedianUs(
            setup: {
                r3 = TimelineReducer()
                r3.processBatch([.agentStart(sessionId: "bench")])
            },
            { r3.processBatch(deltasBatch) }
        )

        // processBatch_tooloutput
        var r4: TimelineReducer!
        let processBatchTool = Self.measureMedianUs(
            setup: {
                r4 = TimelineReducer()
                r4.processBatch([
                    .agentStart(sessionId: "bench"),
                    .toolStart(sessionId: "bench", toolEventId: "tool-0", tool: "bash", args: ["command": .string("ls")]),
                ])
            },
            { r4.processBatch(toolBatch) }
        )

        // loadSession_10turns
        var r5: TimelineReducer!
        let loadSession10 = Self.measureMedianUs(
            setup: { r5 = TimelineReducer() },
            { r5.loadSession(trace10) }
        )

        // loadSession_50turns
        var r6: TimelineReducer!
        let loadSession50 = Self.measureMedianUs(
            setup: { r6 = TimelineReducer() },
            { r6.loadSession(trace50) }
        )

        // coalescer_receive
        var coalescer: DeltaCoalescer!
        let coalescerUs = Self.measureMedianUs(
            setup: {
                coalescer = DeltaCoalescer()
                coalescer.onFlush = { _ in }
            },
            {
                for event in coalescerEvents {
                    coalescer.receive(event)
                }
                coalescer.flushNow()
            }
        )

        let total = processBatchRealistic + processBatchText + processBatchDeltas
            + processBatchTool + loadSession10 + loadSession50 + coalescerUs

        // Print all metrics
        print("METRIC total_us=\(String(format: "%.1f", total))")
        print("METRIC processBatch_realistic_us=\(String(format: "%.1f", processBatchRealistic))")
        print("METRIC processBatch_text_us=\(String(format: "%.1f", processBatchText))")
        print("METRIC processBatch_deltas_us=\(String(format: "%.1f", processBatchDeltas))")
        print("METRIC processBatch_tooloutput_us=\(String(format: "%.1f", processBatchTool))")
        print("METRIC loadSession_10turns_us=\(String(format: "%.1f", loadSession10))")
        print("METRIC loadSession_50turns_us=\(String(format: "%.1f", loadSession50))")
        print("METRIC coalescer_us=\(String(format: "%.1f", coalescerUs))")

        // Sanity
        #expect(total > 0)
    }
}
