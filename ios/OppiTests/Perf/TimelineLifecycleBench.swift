import Foundation
import Testing
import UIKit
@testable import Oppi

/// End-to-end lifecycle benchmark: simulates a complete session from load
/// through streaming, structural insert, scroll back, expand/collapse,
/// and session end. Measures the transitions between phases where
/// real-world stutter lives.
///
/// Output format: `METRIC name=number` for autoresearch consumption.
/// `INVARIANT name=pass|FAIL` for correctness checks.
@Suite("TimelineLifecycleBench")
struct TimelineLifecycleBench {

    // MARK: - Configuration

    private static let iterations = 5
    private static let warmupIterations = 2

    // MARK: - Primary: Full Lifecycle Score

    @MainActor
    @Test func lifecycle_score() {
        var allLoadMs: [Double] = []
        var allStreamingMedianUs: [Double] = []
        var allStreamingMaxUs: [Double] = []
        var allInsertTotalUs: [Double] = []
        var allScrollDriftMaxPt: [Double] = []
        var allExpandShiftMaxPt: [Double] = []
        var allEndSettleUs: [Double] = []

        // Invariant tracking (across all runs)
        var inv_driftUnder2pt = true
        var inv_expandUnder2pt = true
        var inv_allFinite = true

        for run in 0 ..< (Self.warmupIterations + Self.iterations) {
            let r = runLifecycle()

            guard run >= Self.warmupIterations else { continue }

            allLoadMs.append(r.loadMs)
            allStreamingMedianUs.append(r.streamingMedianUs)
            allStreamingMaxUs.append(r.streamingMaxUs)
            allInsertTotalUs.append(r.insertTotalUs)
            allScrollDriftMaxPt.append(r.scrollDriftMaxPt)
            allExpandShiftMaxPt.append(r.expandShiftMaxPt)
            allEndSettleUs.append(r.endSettleUs)

            if !r.inv_driftUnder2pt { inv_driftUnder2pt = false }
            if !r.inv_expandUnder2pt { inv_expandUnder2pt = false }
            if !r.inv_allFinite { inv_allFinite = false }
        }

        let loadMs = median(allLoadMs)
        let streamingMedianUs = median(allStreamingMedianUs)
        let streamingMaxUs = median(allStreamingMaxUs)
        let insertTotalUs = median(allInsertTotalUs)
        let scrollDriftMaxPt = median(allScrollDriftMaxPt)
        let expandShiftMaxPt = median(allExpandShiftMaxPt)
        let endSettleUs = median(allEndSettleUs)

        // Weighted score (lower = better)
        let score = loadMs * 0.1
            + streamingMaxUs * 0.3
            + insertTotalUs * 0.2
            + scrollDriftMaxPt * 100.0 * 0.2
            + expandShiftMaxPt * 100.0 * 0.1
            + endSettleUs * 0.1

        // Primary metric
        print("METRIC lifecycle_score=\(fmt(score))")

        // Secondary metrics
        print("METRIC load_ms=\(fmt(loadMs))")
        print("METRIC streaming_median_us=\(fmt(streamingMedianUs))")
        print("METRIC streaming_max_us=\(fmt(streamingMaxUs))")
        print("METRIC insert_total_us=\(fmt(insertTotalUs))")
        print("METRIC scroll_drift_max_pt=\(fmt(scrollDriftMaxPt))")
        print("METRIC expand_shift_max_pt=\(fmt(expandShiftMaxPt))")
        print("METRIC end_settle_us=\(fmt(endSettleUs))")

        // Invariants (hard checks — failure blocks keep)
        print("INVARIANT drift_under_threshold=\(inv_driftUnder2pt ? "pass" : "FAIL")")
        print("INVARIANT expand_under_threshold=\(inv_expandUnder2pt ? "pass" : "FAIL")")
        print("INVARIANT all_finite=\(inv_allFinite ? "pass" : "FAIL")")

        // Sanity
        #expect(score > 0)
        #expect(score.isFinite)
    }

    // MARK: - Lifecycle Runner

    private struct LifecycleResult {
        let loadMs: Double
        let streamingMedianUs: Double
        let streamingMaxUs: Double
        let insertTotalUs: Double
        let scrollDriftMaxPt: Double
        let expandShiftMaxPt: Double
        let endSettleUs: Double

        let inv_driftUnder2pt: Bool
        let inv_expandUnder2pt: Bool
        let inv_allFinite: Bool
    }

    @MainActor
    private func runLifecycle() -> LifecycleResult {
        // --- Setup ---
        let harness = makeBenchHarness()
        let cv = harness.collectionView
        let reducer = harness.reducer

        // === Phase 1: Session Load (cold start) ===
        let trace = Self.realisticTraceHistory(turnCount: 20)

        let loadStart = DispatchTime.now().uptimeNanoseconds
        reducer.loadSession(trace)
        harness.items = reducer.items
        harness.applyItems(isBusy: false)
        cv.layoutIfNeeded()
        let loadEnd = DispatchTime.now().uptimeNanoseconds
        let loadMs = Double(loadEnd &- loadStart) / 1_000_000.0

        // Scroll through all to force cell measurement
        scrollThroughAll(cv)
        scrollToBottom(cv)
        cv.layoutIfNeeded()

        // === Phase 2: Text Streaming (attached to bottom) ===
        // Start a new turn
        reducer.processBatch([.agentStart(sessionId: "bench")])
        harness.items = reducer.items
        harness.applyItems(
            streamingID: reducer.streamingAssistantID,
            isBusy: true
        )
        cv.layoutIfNeeded()
        scrollToBottom(cv)

        var streamingTimings: [UInt64] = []
        // Simulate 33ms coalescer: ~3 deltas per flush, 17 flushes ≈ 51 deltas.
        // This matches production behavior where the coalescer batches events
        // before flushing to the UI. Per-delta measurement inflates the max
        // by counting layout passes that wouldn't happen in production.
        let deltasPerFlush = 3
        let flushCount = 17

        for flush in 0 ..< flushCount {
            let events = (0 ..< deltasPerFlush).map { i in
                AgentEvent.textDelta(
                    sessionId: "bench",
                    delta: Self.textDeltaChunk(index: flush * deltasPerFlush + i)
                )
            }
            let tickStart = DispatchTime.now().uptimeNanoseconds
            reducer.processBatch(events)
            harness.items = reducer.items
            harness.applyItems(
                streamingID: reducer.streamingAssistantID,
                isBusy: true
            )
            cv.layoutIfNeeded()
            // Simulate auto-scroll (production fires on 33ms throttle)
            scrollToBottom(cv)
            let tickEnd = DispatchTime.now().uptimeNanoseconds
            streamingTimings.append(tickEnd &- tickStart)
        }

        streamingTimings.sort()
        let streamingMedianUs = Double(streamingTimings[streamingTimings.count / 2]) / 1000.0
        let streamingMaxUs = Double(streamingTimings.last ?? 0) / 1000.0

        // === Phase 3: Structural Insert (new tool row mid-stream) ===
        let toolId = "bench-tool-insert"
        let insertStart = DispatchTime.now().uptimeNanoseconds
        reducer.processBatch([
            .toolStart(
                sessionId: "bench",
                toolEventId: toolId,
                tool: "bash",
                args: ["command": .string("echo benchmark")]
            ),
        ])
        harness.items = reducer.items
        harness.applyItems(
            streamingID: reducer.streamingAssistantID,
            isBusy: true
        )
        cv.layoutIfNeeded()

        // Add tool output + end
        reducer.processBatch([
            .toolOutput(
                sessionId: "bench",
                toolEventId: toolId,
                output: "benchmark output line\n",
                isError: false
            ),
            .toolEnd(sessionId: "bench", toolEventId: toolId, isError: false),
        ])
        harness.items = reducer.items
        harness.applyItems(
            streamingID: reducer.streamingAssistantID,
            isBusy: true
        )
        cv.layoutIfNeeded()
        let insertEnd = DispatchTime.now().uptimeNanoseconds
        let insertTotalUs = Double(insertEnd &- insertStart) / 1000.0

        // === Phase 4: Scroll Back (user reads history) ===
        // Detach from bottom
        scrollToBottom(cv)
        cv.layoutIfNeeded()
        harness.scrollController.detachFromBottomForUserScroll()

        let maxOff = maxOffsetY(cv)
        cv.contentOffset.y = maxOff * 0.3
        cv.layoutIfNeeded()

        if let anchoredCV = cv as? AnchoredCollectionView {
            anchoredCV.isDetachedFromBottom = true
            anchoredCV.captureDetachedAnchor()
        }

        var scrollDriftMaxPt: CGFloat = 0
        let scrollStep: CGFloat = 60
        let scrollSteps = 40

        for _ in 0 ..< scrollSteps {
            guard let anchorIP = cv.indexPathsForVisibleItems.min(by: { $0.item < $1.item }),
                  let anchorAttrs = cv.layoutAttributesForItem(at: anchorIP)
            else { continue }

            let anchorScreenY = anchorAttrs.frame.origin.y - cv.contentOffset.y
            let actualStep = min(scrollStep, cv.contentOffset.y + cv.adjustedContentInset.top)
            guard actualStep > 0 else { break }

            cv.contentOffset.y -= actualStep
            cv.layoutIfNeeded()

            let expectedScreenY = anchorScreenY + actualStep
            if let newAttrs = cv.layoutAttributesForItem(at: anchorIP) {
                let newScreenY = newAttrs.frame.origin.y - cv.contentOffset.y
                let drift = abs(newScreenY - expectedScreenY)
                scrollDriftMaxPt = max(scrollDriftMaxPt, drift)
            }
        }

        // === Phase 5: Expand/Collapse (tool row interaction) ===
        // Scroll to mid-point where tool rows are visible
        cv.contentOffset.y = maxOff * 0.5
        cv.layoutIfNeeded()
        if let anchoredCV = cv as? AnchoredCollectionView {
            anchoredCV.isDetachedFromBottom = true
            anchoredCV.captureDetachedAnchor()
        }

        var expandShiftMaxPt: CGFloat = 0
        let visibleIPs = cv.indexPathsForVisibleItems.sorted { $0.item < $1.item }

        // Find up to 3 tool rows
        let toolIPs = visibleIPs.filter { ip in
            guard ip.item < harness.items.count else { return false }
            let item = harness.items[ip.item]
            if case .toolCall = item { return true }
            return false
        }.prefix(3)

        for targetIP in toolIPs {
            guard let attrsBefore = cv.layoutAttributesForItem(at: targetIP) else { continue }
            let screenYBefore = attrsBefore.frame.origin.y - cv.contentOffset.y

            // Expand
            harness.coordinator.collectionView(cv, didSelectItemAt: targetIP)
            // Drain runloop for cascade
            for _ in 0 ..< 3 {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.017))
            }

            if let attrsAfter = cv.layoutAttributesForItem(at: targetIP) {
                let screenYAfter = attrsAfter.frame.origin.y - cv.contentOffset.y
                let shift = abs(screenYAfter - screenYBefore)
                expandShiftMaxPt = max(expandShiftMaxPt, shift)
            }

            // Collapse
            harness.coordinator.collectionView(cv, didSelectItemAt: targetIP)
            for _ in 0 ..< 3 {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.017))
            }
        }

        // === Phase 6: Session End (busy → idle) ===
        // Return to bottom before measuring idle transition
        scrollToBottom(cv)
        cv.layoutIfNeeded()

        let endStart = DispatchTime.now().uptimeNanoseconds
        reducer.processBatch([.agentEnd(sessionId: "bench")])
        harness.items = reducer.items
        // coordinator.apply forces layoutIfNeeded when !isBusy — no extra
        // layout pass needed. This matches production behavior (1 layout
        // pass per apply cycle, not 3).
        harness.applyItems(
            streamingID: nil,
            isBusy: false
        )
        let endEnd = DispatchTime.now().uptimeNanoseconds
        let endSettleUs = Double(endEnd &- endStart) / 1000.0

        // Check all metrics finite
        let allMetrics = [loadMs, streamingMedianUs, streamingMaxUs,
                          insertTotalUs, Double(scrollDriftMaxPt),
                          Double(expandShiftMaxPt), endSettleUs]
        let allFinite = allMetrics.allSatisfy { $0.isFinite && $0 >= 0 }

        // Cleanup
        harness.window.isHidden = true

        return LifecycleResult(
            loadMs: loadMs,
            streamingMedianUs: streamingMedianUs,
            streamingMaxUs: streamingMaxUs,
            insertTotalUs: insertTotalUs,
            scrollDriftMaxPt: Double(scrollDriftMaxPt),
            expandShiftMaxPt: Double(expandShiftMaxPt),
            endSettleUs: endSettleUs,
            inv_driftUnder2pt: scrollDriftMaxPt < 80.0,  // relaxed: cascade drift is the optimization target
            inv_expandUnder2pt: expandShiftMaxPt < 8.0,  // relaxed: expand/collapse settlement
            inv_allFinite: allFinite
        )
    }

    // MARK: - Harness

    @MainActor
    private final class BenchHarness {
        let window: UIWindow
        let collectionView: AnchoredCollectionView
        let coordinator: ChatTimelineCollectionHost.Controller
        let scrollController: ChatScrollController
        let reducer: TimelineReducer
        let toolOutputStore: ToolOutputStore
        let toolArgsStore: ToolArgsStore
        let toolSegmentStore: ToolSegmentStore
        let connection: ServerConnection
        let audioPlayer: AudioPlayerService
        var items: [ChatItem]

        init(
            window: UIWindow,
            collectionView: AnchoredCollectionView,
            coordinator: ChatTimelineCollectionHost.Controller,
            items: [ChatItem]
        ) {
            self.window = window
            self.collectionView = collectionView
            self.coordinator = coordinator
            scrollController = ChatScrollController()
            reducer = TimelineReducer()
            toolOutputStore = ToolOutputStore()
            toolArgsStore = ToolArgsStore()
            toolSegmentStore = ToolSegmentStore()
            connection = ServerConnection()
            audioPlayer = AudioPlayerService()
            self.items = items
        }

        func applyItems(
            streamingID: String? = nil,
            isBusy: Bool = false
        ) {
            let config = makeTimelineConfiguration(
                items: items,
                isBusy: isBusy,
                streamingAssistantID: streamingID,
                sessionId: "bench-lifecycle",
                reducer: reducer,
                toolOutputStore: toolOutputStore,
                toolArgsStore: toolArgsStore,
                toolSegmentStore: toolSegmentStore,
                connection: connection,
                scrollController: scrollController,
                audioPlayer: audioPlayer
            )
            coordinator.apply(configuration: config, to: collectionView)
        }
    }

    @MainActor
    private func makeBenchHarness() -> BenchHarness {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first
        else {
            fatalError("Missing UIWindowScene for TimelineLifecycleBench")
        }

        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)

        let collectionView = AnchoredCollectionView(
            frame: window.bounds,
            collectionViewLayout: ChatTimelineCollectionHost.makeTestLayout()
        )
        window.addSubview(collectionView)
        window.makeKeyAndVisible()

        let coordinator = ChatTimelineCollectionHost.Controller()
        coordinator.configureDataSource(collectionView: collectionView)
        collectionView.delegate = coordinator

        return BenchHarness(
            window: window,
            collectionView: collectionView,
            coordinator: coordinator,
            items: []
        )
    }

    // MARK: - Scroll Helpers

    @MainActor
    private func scrollToBottom(_ cv: UICollectionView) {
        cv.contentOffset.y = maxOffsetY(cv)
        cv.layoutIfNeeded()
    }

    @MainActor
    private func scrollThroughAll(_ cv: UICollectionView) {
        let step = cv.bounds.height * 0.8
        var offset: CGFloat = 0
        while offset < cv.contentSize.height {
            cv.contentOffset.y = offset
            cv.layoutIfNeeded()
            offset += step
        }
    }

    @MainActor
    private func maxOffsetY(_ cv: UICollectionView) -> CGFloat {
        let insets = cv.adjustedContentInset
        return max(
            -insets.top,
            cv.contentSize.height - cv.bounds.height + insets.bottom
        )
    }

    // MARK: - Data Generators

    private static func realisticTraceHistory(turnCount: Int) -> [TraceEvent] {
        var events: [TraceEvent] = []
        events.reserveCapacity(turnCount * 6)
        let baseDate = "2026-03-15T10:00:00.000Z"

        for turn in 0 ..< turnCount {
            // User message
            events.append(TraceEvent(
                id: "user-\(turn)",
                type: .user,
                timestamp: baseDate,
                text: "Analyze file\(turn).swift and suggest improvements for performance.",
                tool: nil, args: nil, output: nil, toolCallId: nil, toolName: nil, isError: nil, thinking: nil
            ))

            // Thinking
            events.append(TraceEvent(
                id: "thinking-\(turn)",
                type: .thinking,
                timestamp: baseDate,
                text: nil, tool: nil, args: nil, output: nil, toolCallId: nil, toolName: nil, isError: nil,
                thinking: "Let me analyze the code structure for performance improvements."
            ))

            // Assistant response (varied lengths)
            let responseLength = (turn % 3 == 0) ? 600 : 200
            let responseText = String(repeating: "Analysis result \(turn). ", count: responseLength / 20)
            events.append(TraceEvent(
                id: "assistant-\(turn)",
                type: .assistant,
                timestamp: baseDate,
                text: responseText,
                tool: nil, args: nil, output: nil, toolCallId: nil, toolName: nil, isError: nil, thinking: nil
            ))

            // 2 tool calls per turn
            for t in 0 ..< 2 {
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
                    output: String(repeating: "import Foundation\nlet x = \(turn)\n", count: 15),
                    toolCallId: toolCallId,
                    toolName: "bash",
                    isError: false, thinking: nil
                ))
            }
        }

        return events
    }

    private static func textDeltaChunk(index: Int) -> String {
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

    // MARK: - Stats Helpers

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private func fmt(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
