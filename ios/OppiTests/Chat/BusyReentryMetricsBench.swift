import Foundation
import Testing
@testable import Oppi

// MARK: - Metric Definitions

/// Captures all measurable aspects of a busy session re-entry.
///
/// Two categories:
///   - Latency: how fast the user sees content (lower is better)
///   - Correctness: is the timeline accurate (zero violations is target)
///
/// These metrics define the optimization surface for autoresearch.
struct BusyReentryMetrics: Sendable {
    // -- Latency (milliseconds) --

    /// Entry to first live event processed by reducer.
    /// This is "how long until I see what the agent is doing now."
    var timeToFollowMs: Int64 = 0

    /// Entry to any visible content (cache or live).
    var timeToFirstContentMs: Int64 = 0

    /// Entry to zero-gap timeline. May be lazy (deferred until scroll).
    var timeToCorrectMs: Int64 = 0

    // -- Correctness --

    /// Trace events missing from timeline after merge window.
    var gapEventCount: Int = 0

    /// Items sharing an ID (must be zero).
    var duplicateItemCount: Int = 0

    /// Pairs where earlier item has later timestamp.
    var orderInversions: Int = 0

    /// Items not in trace or known live event set.
    var orphanedItemCount: Int = 0

    // -- Stability --

    /// Times streamingAssistantID went non-nil→nil→non-nil during merge.
    var liveContinuityBreaks: Int = 0

    /// renderVersion bumps during the merge window.
    var renderBumpsDuringMerge: Int = 0

    /// max(items.count) - min(items.count) during merge window.
    var itemCountSwing: Int = 0

    /// Did isNearBottom flip false during merge?
    var scrollDetachDuringMerge: Bool = false

    // -- Composite --

    /// Weighted score for autoresearch optimization.
    /// Higher is better. Hard constraints are heavily penalized.
    var compositeScore: Double {
        var score: Double = 0
        score -= 1.0 * Double(timeToFollowMs)
        score -= 0.5 * Double(timeToCorrectMs)
        score -= 50.0 * Double(gapEventCount)
        score -= 200.0 * Double(duplicateItemCount)
        score -= 100.0 * Double(liveContinuityBreaks)
        score -= 20.0 * Double(renderBumpsDuringMerge)
        score -= 500.0 * (scrollDetachDuringMerge ? 1.0 : 0.0)
        score -= 30.0 * Double(orderInversions)
        score -= 80.0 * Double(orphanedItemCount)
        return score
    }
}

// MARK: - Scenario Parameters

/// Defines the conditions for a single bench run.
struct BusyReentryScenario: Sendable {
    /// How many events the cache has (subset of total trace).
    let cacheEventCount: Int
    /// Total events in the server trace.
    let traceEventCount: Int
    /// Live events per second during the merge window.
    let liveEventsPerSecond: Int
    /// REST roundtrip latency for trace fetch (ms).
    let traceFetchDelayMs: Int

    var label: String {
        "cache=\(cacheEventCount) trace=\(traceEventCount) live=\(liveEventsPerSecond)/s fetch=\(traceFetchDelayMs)ms"
    }
}

// MARK: - Metric Collector

/// Observes the reducer and scroll controller during a bench run to compute metrics.
///
/// Sampling happens synchronously on @MainActor at each observation point.
/// No timers or background threads — the bench drives observation calls
/// explicitly after each state change.
@MainActor
final class BusyReentryMetricCollector {
    private let entryTimestampMs: Int64
    private var firstContentTimestampMs: Int64?
    private var firstLiveEventTimestampMs: Int64?
    private(set) var correctTimestampMs: Int64?

    private var mergeWindowOpen = false
    private var renderVersionAtMergeStart = 0
    private var renderBumps = 0
    private var minItemCount = Int.max
    private var maxItemCount = 0

    private var previousStreamingID: String?
    private var continuityBreaks: Int = 0
    private var scrollDetached = false

    // Ground truth for correctness checks
    private var groundTruthTraceIDs: Set<String> = []
    private var liveEventIDs: Set<String> = []

    init(entryTimestampMs: Int64) {
        self.entryTimestampMs = entryTimestampMs
    }

    func setGroundTruth(traceIDs: [String]) {
        groundTruthTraceIDs = Set(traceIDs)
    }

    func recordLiveEventID(_ id: String) {
        liveEventIDs.insert(id)
    }

    /// Call after each state change during the bench run.
    func observe(
        reducer: TimelineReducer,
        scrollController: ChatScrollController,
        isLiveEvent: Bool = false,
        nowMs: Int64
    ) {
        let itemCount = reducer.items.count

        // First content
        if itemCount > 0, firstContentTimestampMs == nil {
            firstContentTimestampMs = nowMs
        }

        // First live event
        if isLiveEvent, firstLiveEventTimestampMs == nil {
            firstLiveEventTimestampMs = nowMs
        }

        // Track item count swing during merge
        if mergeWindowOpen {
            minItemCount = min(minItemCount, itemCount)
            maxItemCount = max(maxItemCount, itemCount)

            if reducer.renderVersion != renderVersionAtMergeStart {
                renderBumps = reducer.renderVersion - renderVersionAtMergeStart
            }
        }

        // Streaming continuity
        let currentStreamingID = reducer.streamingAssistantID
        if previousStreamingID != nil, currentStreamingID == nil {
            // Was streaming, now not — potential break
            // Only count as a break if it goes back to streaming later
            // (tracked on next observation)
        }
        if previousStreamingID == nil, currentStreamingID != nil, firstLiveEventTimestampMs != nil {
            // Resumed streaming after a break during merge
            if mergeWindowOpen {
                continuityBreaks += 1
            }
        }
        previousStreamingID = currentStreamingID

        // Scroll detach
        if mergeWindowOpen, !scrollController.isCurrentlyNearBottom {
            scrollDetached = true
        }
    }

    func beginMergeWindow(reducer: TimelineReducer) {
        mergeWindowOpen = true
        renderVersionAtMergeStart = reducer.renderVersion
        minItemCount = reducer.items.count
        maxItemCount = reducer.items.count
    }

    func endMergeWindow() {
        mergeWindowOpen = false
    }

    func markTimelineCorrect(nowMs: Int64) {
        if correctTimestampMs == nil {
            correctTimestampMs = nowMs
        }
    }

    /// Compute final metrics from observed state.
    func finalize(reducer: TimelineReducer) -> BusyReentryMetrics {
        var m = BusyReentryMetrics()

        // Latency
        m.timeToFirstContentMs = (firstContentTimestampMs ?? entryTimestampMs) - entryTimestampMs
        m.timeToFollowMs = (firstLiveEventTimestampMs ?? entryTimestampMs) - entryTimestampMs
        m.timeToCorrectMs = (correctTimestampMs ?? entryTimestampMs) - entryTimestampMs

        // Correctness: gap
        let timelineIDs = Set(reducer.items.map(\.id))
        let missingFromTrace = groundTruthTraceIDs.subtracting(timelineIDs)
        m.gapEventCount = missingFromTrace.count

        // Correctness: duplicates
        var idCounts: [String: Int] = [:]
        for item in reducer.items {
            idCounts[item.id, default: 0] += 1
        }
        m.duplicateItemCount = idCounts.values.filter { $0 > 1 }.count

        // Correctness: order inversions (only among items that have timestamps)
        var inversions = 0
        let timestampedItems = reducer.items.compactMap { item -> (id: String, ts: Date)? in
            guard let ts = item.timestamp else { return nil }
            return (item.id, ts)
        }
        for i in 0..<timestampedItems.count {
            for j in (i + 1)..<min(i + 5, timestampedItems.count)
            where timestampedItems[i].ts > timestampedItems[j].ts {
                inversions += 1
            }
        }
        m.orderInversions = inversions

        // Correctness: orphans
        let knownIDs = groundTruthTraceIDs.union(liveEventIDs)
        m.orphanedItemCount = timelineIDs.subtracting(knownIDs).count

        // Stability
        m.liveContinuityBreaks = continuityBreaks
        m.renderBumpsDuringMerge = renderBumps
        m.itemCountSwing = maxItemCount - minItemCount
        m.scrollDetachDuringMerge = scrollDetached

        return m
    }
}

// MARK: - Trace Event Generator

/// Builds synthetic trace events for bench scenarios.
enum BenchTraceGenerator {

    static func makeTrace(count: Int, baseTimestamp: String = "2026-03-17T10:00:00Z") -> [TraceEvent] {
        var events: [TraceEvent] = []
        events.reserveCapacity(count)

        for i in 0..<count {
            let id = "trace-\(i)"
            if i % 3 == 0 {
                // User message every 3rd event
                events.append(TraceEvent(
                    id: id,
                    type: .user,
                    timestamp: baseTimestamp,
                    text: "User message \(i)",
                    tool: nil, args: nil, output: nil,
                    toolCallId: nil, toolName: nil, isError: nil, thinking: nil
                ))
            } else if i % 3 == 1 {
                // Tool call
                events.append(TraceEvent(
                    id: id,
                    type: .toolCall,
                    timestamp: baseTimestamp,
                    text: nil,
                    tool: "bash",
                    args: ["command": .string("echo \(i)")],
                    output: "output \(i)",
                    toolCallId: "tc-\(i)", toolName: "bash",
                    isError: false, thinking: nil
                ))
            } else {
                // Assistant message
                events.append(TraceEvent(
                    id: id,
                    type: .assistant,
                    timestamp: baseTimestamp,
                    text: "Assistant response \(i). This has enough text to be meaningful for timeline rendering.",
                    tool: nil, args: nil, output: nil,
                    toolCallId: nil, toolName: nil, isError: nil, thinking: nil
                ))
            }
        }
        return events
    }

    struct LiveEvent {
        let message: ServerMessage
        let id: String
        let seq: Int
    }

    /// Generate the live WS events that arrive during the merge window.
    static func makeLiveSequence(count: Int, startingSeq: Int) -> [LiveEvent] {
        var events: [LiveEvent] = []

        // Start a new turn
        events.append(LiveEvent(message: .agentStart, id: "live-agentstart", seq: startingSeq))

        for i in 0..<count {
            let seq = startingSeq + 1 + i
            let id = "live-\(i)"
            events.append(LiveEvent(
                message: .textDelta(delta: "Live word \(i) "),
                id: id,
                seq: seq
            ))
        }

        return events
    }
}

// MARK: - Bench Harness

/// Runs a single busy re-entry scenario and measures all metrics.
///
/// Orchestrates: cache seed → connect → WS events → trace fetch → merge → finalize.
/// All timing uses a virtual clock (monotonic counter) so results are deterministic.
@MainActor
final class BusyReentryBench {

    /// Run a single scenario and return the measured metrics.
    static func run(scenario: BusyReentryScenario) async -> BusyReentryMetrics {
        let sessionId = "bench-\(UUID().uuidString)"
        let workspaceId = "w-bench"

        // Virtual clock for deterministic timing
        var virtualClockMs: Int64 = 0
        func now() -> Int64 { virtualClockMs }
        func advance(_ ms: Int64) { virtualClockMs += ms }

        let collector = BusyReentryMetricCollector(entryTimestampMs: now())

        // 1. Generate ground truth trace
        let fullTrace = BenchTraceGenerator.makeTrace(count: scenario.traceEventCount)
        let cacheTrace = Array(fullTrace.prefix(scenario.cacheEventCount))
        collector.setGroundTruth(traceIDs: fullTrace.map(\.id))

        // 2. Seed cache
        if !cacheTrace.isEmpty {
            await TimelineCache.shared.saveTrace(sessionId, events: cacheTrace)
        }

        // 3. Set up manager with scripted stream
        let manager = ChatSessionManager(sessionId: sessionId)
        let streams = ScriptedStreamFactory()
        manager._streamSessionForTesting = { _ in streams.makeStream() }

        // Trace fetch with configured delay
        let traceFetchDelay = scenario.traceFetchDelayMs
        manager._fetchSessionTraceForTesting = { _, _ in
            try await Task.sleep(for: .milliseconds(traceFetchDelay))
            return (
                makeTestSession(id: sessionId, workspaceId: workspaceId, status: .busy),
                fullTrace
            )
        }

        // Subscribe ack metadata
        let subscribeSeq = scenario.traceEventCount + 10 // seq beyond trace
        var inboundMetaIndex = 0
        let liveEvents = BenchTraceGenerator.makeLiveSequence(
            count: max(1, scenario.liveEventsPerSecond / 3), // ~333ms worth
            startingSeq: subscribeSeq
        )

        manager._consumeInboundMetaForTesting = {
            defer { inboundMetaIndex += 1 }
            if inboundMetaIndex == 0 {
                // Subscribe ack
                return .init(seq: nil, currentSeq: subscribeSeq)
            }
            let liveIdx = inboundMetaIndex - 1
            if liveIdx < liveEvents.count {
                return .init(seq: liveEvents[liveIdx].seq, currentSeq: nil)
            }
            return nil
        }

        // 4. Connect
        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())
        let reducer = connection.reducer
        let sessionStore = SessionStore()
        sessionStore.upsert(makeTestSession(id: sessionId, workspaceId: workspaceId, status: .busy))
        let scrollController = ChatScrollController()

        advance(1) // t=1: entry
        let connectTask = Task { @MainActor in
            await manager.connect(connection: connection, reducer: reducer, sessionStore: sessionStore)
        }

        // Wait for stream creation
        _ = await streams.waitForCreated(1)

        advance(5) // t=6: cache loaded (fast path)
        collector.observe(reducer: reducer, scrollController: scrollController, nowMs: now())

        // 5. WS connected
        streams.yield(index: 0, message: .connected(
            session: makeTestSession(id: sessionId, workspaceId: workspaceId, status: .busy)
        ))
        try? await Task.sleep(for: .milliseconds(20))
        advance(20)
        collector.observe(reducer: reducer, scrollController: scrollController, nowMs: now())

        // 6. Live events arrive
        collector.beginMergeWindow(reducer: reducer)

        for event in liveEvents {
            streams.yield(index: 0, message: event.message)
            collector.recordLiveEventID(event.id)
        }

        // Let coalescer flush
        try? await Task.sleep(for: .milliseconds(50))
        advance(50)
        collector.observe(reducer: reducer, scrollController: scrollController, isLiveEvent: true, nowMs: now())

        // 7. Wait for trace fetch to complete
        let traceWaitMs = max(0, scenario.traceFetchDelayMs - 70) // account for time already elapsed
        if traceWaitMs > 0 {
            try? await Task.sleep(for: .milliseconds(traceWaitMs + 100))
            advance(Int64(traceWaitMs + 100))
        } else {
            try? await Task.sleep(for: .milliseconds(100))
            advance(100)
        }

        collector.observe(reducer: reducer, scrollController: scrollController, nowMs: now())

        // 8. Check correctness
        let timelineIDs = Set(reducer.items.map(\.id))
        let traceIDs = Set(fullTrace.map(\.id))
        let missingCount = traceIDs.subtracting(timelineIDs).count
        if missingCount == 0 {
            collector.markTimelineCorrect(nowMs: now())
        }

        collector.endMergeWindow()

        // 9. Finalize
        let metrics = collector.finalize(reducer: reducer)

        // Cleanup
        streams.finish(index: 0)
        await connectTask.value
        await TimelineCache.shared.removeTrace(sessionId)

        return metrics
    }
}

// MARK: - Bench Tests (baseline measurement)

@Suite("Busy Re-entry Metrics Bench")
struct BusyReentryMetricsBenchTests {

    // MARK: - Baseline: current behavior measurement

    /// Measure the CURRENT behavior for the core scenario:
    /// cache is 30 events stale, session has 100 events total, moderate streaming.
    ///
    /// This establishes the baseline metrics that autoresearch will improve.
    @MainActor
    @Test func baselineModerateStaleCache() async {
        let scenario = BusyReentryScenario(
            cacheEventCount: 70,
            traceEventCount: 100,
            liveEventsPerSecond: 30,
            traceFetchDelayMs: 200
        )

        let metrics = await BusyReentryBench.run(scenario: scenario)

        // Log baseline for reference
        printMetrics(label: "BASELINE moderate", scenario: scenario, metrics: metrics)

        // Structural assertions (must always hold)
        #expect(metrics.duplicateItemCount == 0, "No duplicate items")
        #expect(!metrics.scrollDetachDuringMerge, "Scroll should not detach during merge")
    }

    /// Cache is very stale (only 20 of 200 events cached).
    /// This is the worst case for the gap bug.
    @MainActor
    @Test func baselineVeryStaleCache() async {
        let scenario = BusyReentryScenario(
            cacheEventCount: 20,
            traceEventCount: 200,
            liveEventsPerSecond: 30,
            traceFetchDelayMs: 500
        )

        let metrics = await BusyReentryBench.run(scenario: scenario)

        printMetrics(label: "BASELINE very stale", scenario: scenario, metrics: metrics)

        #expect(metrics.duplicateItemCount == 0, "No duplicate items")
    }

    /// No cache at all (cold start into busy session).
    @MainActor
    @Test func baselineNoCache() async {
        let scenario = BusyReentryScenario(
            cacheEventCount: 0,
            traceEventCount: 100,
            liveEventsPerSecond: 30,
            traceFetchDelayMs: 200
        )

        let metrics = await BusyReentryBench.run(scenario: scenario)

        printMetrics(label: "BASELINE no cache", scenario: scenario, metrics: metrics)

        #expect(metrics.duplicateItemCount == 0, "No duplicate items")
    }

    /// Fast network (50ms trace fetch) — minimal merge window.
    @MainActor
    @Test func baselineFastNetwork() async {
        let scenario = BusyReentryScenario(
            cacheEventCount: 80,
            traceEventCount: 100,
            liveEventsPerSecond: 30,
            traceFetchDelayMs: 50
        )

        let metrics = await BusyReentryBench.run(scenario: scenario)

        printMetrics(label: "BASELINE fast net", scenario: scenario, metrics: metrics)

        #expect(metrics.duplicateItemCount == 0, "No duplicate items")
    }

    /// Slow network (5s trace fetch) — long merge window, many live events.
    @MainActor
    @Test func baselineSlowNetwork() async {
        let scenario = BusyReentryScenario(
            cacheEventCount: 50,
            traceEventCount: 100,
            liveEventsPerSecond: 30,
            traceFetchDelayMs: 2000
        )

        let metrics = await BusyReentryBench.run(scenario: scenario)

        printMetrics(label: "BASELINE slow net", scenario: scenario, metrics: metrics)

        #expect(metrics.duplicateItemCount == 0, "No duplicate items")
    }

    // MARK: - Correctness invariant: gap must be zero after merge

    /// This test will FAIL on the current codebase because shouldDeferRebuild
    /// prevents the trace from being applied for busy sessions.
    /// Autoresearch experiments must make this pass.
    @MainActor
    @Test func gapMustBeZeroAfterMerge() async {
        let scenario = BusyReentryScenario(
            cacheEventCount: 50,
            traceEventCount: 100,
            liveEventsPerSecond: 10,
            traceFetchDelayMs: 200
        )

        let metrics = await BusyReentryBench.run(scenario: scenario)

        printMetrics(label: "GAP CHECK", scenario: scenario, metrics: metrics)

        // THE KEY ASSERTION:
        // After the trace fetch completes, the timeline must contain ALL trace events.
        // Currently fails because shouldDeferRebuild skips the trace for busy sessions.
        #expect(
            metrics.gapEventCount == 0,
            "Expected zero gap events, got \(metrics.gapEventCount) missing from timeline"
        )
    }

    // MARK: - Helpers

    private func printMetrics(label: String, scenario: BusyReentryScenario, metrics: BusyReentryMetrics) {
        print("""
        [\(label)] \(scenario.label)
          ttFirstContent: \(metrics.timeToFirstContentMs)ms
          ttFollow:       \(metrics.timeToFollowMs)ms
          ttCorrect:      \(metrics.timeToCorrectMs)ms
          gap:            \(metrics.gapEventCount) events
          duplicates:     \(metrics.duplicateItemCount)
          inversions:     \(metrics.orderInversions)
          orphans:        \(metrics.orphanedItemCount)
          continuity:     \(metrics.liveContinuityBreaks) breaks
          renderBumps:    \(metrics.renderBumpsDuringMerge)
          itemSwing:      \(metrics.itemCountSwing)
          scrollDetach:   \(metrics.scrollDetachDuringMerge)
          composite:      \(String(format: "%.1f", metrics.compositeScore))
        """)

        // Unified vital metrics (same names as production telemetry)
        print("METRIC chat.catchup_ms=\(String(format: "%.1f", Double(metrics.timeToCorrectMs)))")
    }
}
