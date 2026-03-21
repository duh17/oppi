import Foundation
import Testing
import UIKit
@testable import Oppi

/// Measures viewport stability when structural items are inserted and
/// during streaming text updates. The primary metric captures the total
/// height mismatch between what UIKit has resolved after snapshot apply
/// vs after explicit layout. Lower = smoother.
@Suite("InsertStabilityBench")
struct InsertStabilityBench {

    private static let iterations = 5
    private static let warmupIterations = 2

    @MainActor
    @Test func insert_stability_score() {
        var allToolDrift: [Double] = []
        var allSystemDrift: [Double] = []
        var allPermDrift: [Double] = []
        var allStreamDrift: [Double] = []
        var allTotalMs: [Double] = []
        var inv_allFinite = true

        for run in 0 ..< (Self.warmupIterations + Self.iterations) {
            let r = runInsertStability()
            guard run >= Self.warmupIterations else { continue }

            allToolDrift.append(r.toolDrift)
            allSystemDrift.append(r.systemDrift)
            allPermDrift.append(r.permissionDrift)
            allStreamDrift.append(r.streamingDrift)
            allTotalMs.append(r.totalInsertMs)

            if !r.allFinite { inv_allFinite = false }
        }

        let toolDrift = median(allToolDrift)
        let sysDrift = median(allSystemDrift)
        let permDrift = median(allPermDrift)
        let streamDrift = median(allStreamDrift)
        let totalMs = median(allTotalMs)

        let score = toolDrift * 3
            + sysDrift * 2
            + permDrift * 3
            + streamDrift * 2

        print("METRIC insert_stability_score=\(fmt(score))")
        print("METRIC tool_insert_drift_pt=\(fmt(toolDrift))")
        print("METRIC system_insert_drift_pt=\(fmt(sysDrift))")
        print("METRIC permission_insert_drift_pt=\(fmt(permDrift))")
        print("METRIC streaming_bubble_drift_pt=\(fmt(streamDrift))")
        print("METRIC total_insert_ms=\(fmt(totalMs))")

        print("INVARIANT all_finite=\(inv_allFinite ? "pass" : "FAIL")")

        #expect(score >= 0)
        #expect(score.isFinite)
    }

    // MARK: - Result

    private struct InsertResult {
        let toolDrift: Double
        let systemDrift: Double
        let permissionDrift: Double
        let streamingDrift: Double
        let totalInsertMs: Double
        let allFinite: Bool
    }

    // MARK: - Runner

    @MainActor
    private func runInsertStability() -> InsertResult {
        let harness = makeBenchHarness()
        let cv = harness.collectionView
        let reducer = harness.reducer

        // Load history to fill viewport
        let trace = makeBaseHistory(turnCount: 10)
        reducer.loadSession(trace)
        harness.items = reducer.items
        harness.applyItems(isBusy: false)
        cv.layoutIfNeeded()

        // Force all cells measured
        scrollThroughAll(cv)
        scrollToBottom(cv)
        cv.layoutIfNeeded()

        // Start streaming
        reducer.processBatch([.agentStart(sessionId: "bench")])
        for i in 0 ..< 5 {
            reducer.processBatch([
                .textDelta(sessionId: "bench", delta: "Analysis chunk \(i). ")
            ])
        }
        harness.items = reducer.items
        harness.applyItems(
            streamingID: reducer.streamingAssistantID,
            isBusy: true
        )
        cv.layoutIfNeeded()
        scrollToBottom(cv)
        cv.layoutIfNeeded()
        harness.scrollController.updateNearBottom(true)

        var totalInsertNs: UInt64 = 0

        // --- Test 1: Tool call insertion ---
        let toolDrift = measureDrift(harness: harness, cv: cv, totalNs: &totalInsertNs) {
            let toolId = "bench-tool-1"
            reducer.processBatch([
                .toolStart(
                    sessionId: "bench",
                    toolEventId: toolId,
                    tool: "read",
                    args: ["path": .string("/src/main.swift")]
                ),
                .toolOutput(
                    sessionId: "bench",
                    toolEventId: toolId,
                    output: "import Foundation\n",
                    isError: false
                ),
                .toolEnd(sessionId: "bench", toolEventId: toolId, isError: false),
            ])
            harness.items = reducer.items
            harness.applyItems(
                streamingID: reducer.streamingAssistantID,
                isBusy: true
            )
        }
        settle(harness: harness, cv: cv, reducer: reducer)

        // --- Test 2: System event ---
        let sysDrift = measureDrift(harness: harness, cv: cv, totalNs: &totalInsertNs) {
            reducer.processBatch([
                .compactionStart(sessionId: "bench", reason: "overflow"),
            ])
            harness.items = reducer.items
            harness.applyItems(
                streamingID: reducer.streamingAssistantID,
                isBusy: true
            )
        }
        reducer.processBatch([
            .compactionEnd(
                sessionId: "bench",
                aborted: false,
                willRetry: false,
                summary: "Compacted",
                tokensBefore: 45000
            ),
        ])
        settle(harness: harness, cv: cv, reducer: reducer)

        // --- Test 3: Permission resolved ---
        let permDrift = measureDrift(harness: harness, cv: cv, totalNs: &totalInsertNs) {
            reducer.resolvePermission(
                id: "bench-perm-1",
                outcome: .allowed,
                tool: "bash",
                summary: "rm -rf /tmp/test"
            )
            harness.items = reducer.items
            harness.applyItems(
                streamingID: reducer.streamingAssistantID,
                isBusy: true
            )
        }
        settle(harness: harness, cv: cv, reducer: reducer)

        // --- Test 4: Streaming text growth (bubble expand) ---
        // Measure how much the viewport shifts when the assistant text
        // grows significantly across a single coalescer flush.
        let streamDrift = measureDrift(harness: harness, cv: cv, totalNs: &totalInsertNs) {
            // Simulate a large coalescer flush that adds multiple lines
            reducer.processBatch([
                .textDelta(sessionId: "bench", delta: "Here is a detailed analysis:\n\n"),
                .textDelta(sessionId: "bench", delta: "1. The first point is about performance.\n"),
                .textDelta(sessionId: "bench", delta: "2. The second point covers architecture.\n"),
                .textDelta(sessionId: "bench", delta: "3. The third examines data flow patterns.\n\n"),
                .textDelta(sessionId: "bench", delta: "```swift\nfunc optimize() {\n    let x = 42\n}\n```\n\n"),
            ])
            harness.items = reducer.items
            harness.applyItems(
                streamingID: reducer.streamingAssistantID,
                isBusy: true
            )
        }

        let totalMs = Double(totalInsertNs) / 1_000_000.0
        let allMetrics = [toolDrift, sysDrift, permDrift, streamDrift, totalMs]
        let allFinite = allMetrics.allSatisfy { $0.isFinite && $0 >= 0 }

        harness.window.isHidden = true

        return InsertResult(
            toolDrift: toolDrift,
            systemDrift: sysDrift,
            permissionDrift: permDrift,
            streamingDrift: streamDrift,
            totalInsertMs: totalMs,
            allFinite: allFinite
        )
    }

    // MARK: - Drift Measurement

    /// Measures the visual drift caused by a content change.
    ///
    /// Captures the last visible item's screen position before the change,
    /// then measures how far it moved after the change. In an ideal stable
    /// timeline, visible items shouldn't shift when new items are added
    /// below them (user is at bottom following content).
    ///
    /// When the coordinator forces layoutIfNeeded, all heights resolve in
    /// one pass and drift should be near zero. When layout is deferred,
    /// estimated heights create intermediate frames where items are at
    /// wrong positions.
    @MainActor
    private func measureDrift(
        harness: BenchHarness,
        cv: AnchoredCollectionView,
        totalNs: inout UInt64,
        change: () -> Void
    ) -> Double {
        scrollToBottom(cv)
        cv.layoutIfNeeded()
        harness.scrollController.updateNearBottom(true)

        // Find the second-to-last visible item (the "anchor" that should
        // stay stable during the change — the last item is the one growing).
        let visibleIPs = cv.indexPathsForVisibleItems.sorted { $0.item < $1.item }
        guard visibleIPs.count >= 2 else { return 0 }
        let anchorIP = visibleIPs[visibleIPs.count - 2]

        guard let attrsBefore = cv.layoutAttributesForItem(at: anchorIP) else { return 0 }
        let anchorScreenYBefore = attrsBefore.frame.origin.y - cv.contentOffset.y

        let start = DispatchTime.now().uptimeNanoseconds

        // Apply the change
        change()

        // Measure: after the coordinator's apply (which may or may not
        // have forced layout), where is the anchor item now?
        // If layout was forced, it should be at the same screen position.
        // If layout was deferred, estimated heights may have shifted it.

        // Don't force additional layout here — we want to measure what
        // the coordinator left us with.
        let end = DispatchTime.now().uptimeNanoseconds
        totalNs += (end &- start)

        guard let attrsAfter = cv.layoutAttributesForItem(at: anchorIP) else { return 0 }
        let anchorScreenYAfter = attrsAfter.frame.origin.y - cv.contentOffset.y
        let drift = abs(anchorScreenYAfter - anchorScreenYBefore)

        // Re-settle for the next measurement
        cv.layoutIfNeeded()
        scrollToBottom(cv)
        cv.layoutIfNeeded()
        harness.scrollController.updateNearBottom(true)

        return Double(drift)
    }

    // MARK: - Helpers

    @MainActor
    private func settle(harness: BenchHarness, cv: AnchoredCollectionView, reducer: TimelineReducer) {
        reducer.processBatch([
            .textDelta(sessionId: "bench", delta: "Continue. ")
        ])
        harness.items = reducer.items
        harness.applyItems(
            streamingID: reducer.streamingAssistantID,
            isBusy: true
        )
        cv.layoutIfNeeded()
        scrollToBottom(cv)
        cv.layoutIfNeeded()
        harness.scrollController.updateNearBottom(true)
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
                sessionId: "bench-insert",
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
            fatalError("Missing UIWindowScene for InsertStabilityBench")
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
        let insets = cv.adjustedContentInset
        let maxY = max(
            -insets.top,
            cv.contentSize.height - cv.bounds.height + insets.bottom
        )
        cv.contentOffset.y = maxY
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

    // MARK: - Data Generators

    private func makeBaseHistory(turnCount: Int) -> [TraceEvent] {
        var events: [TraceEvent] = []
        events.reserveCapacity(turnCount * 4)
        let ts = "2026-03-21T10:00:00.000Z"

        for turn in 0 ..< turnCount {
            events.append(TraceEvent(
                id: "user-\(turn)",
                type: .user,
                timestamp: ts,
                text: "Question about file\(turn).swift",
                tool: nil, args: nil, output: nil, toolCallId: nil,
                toolName: nil, isError: nil, thinking: nil
            ))

            let responseText = String(repeating: "Response text \(turn). ", count: 10)
            events.append(TraceEvent(
                id: "assistant-\(turn)",
                type: .assistant,
                timestamp: ts,
                text: responseText,
                tool: nil, args: nil, output: nil, toolCallId: nil,
                toolName: nil, isError: nil, thinking: nil
            ))

            let toolCallId = "tc-\(turn)"
            events.append(TraceEvent(
                id: toolCallId,
                type: .toolCall,
                timestamp: ts,
                text: nil,
                tool: "bash",
                args: ["command": .string("cat file\(turn).swift")],
                output: nil, toolCallId: nil, toolName: nil,
                isError: nil, thinking: nil
            ))

            events.append(TraceEvent(
                id: "tr-\(turn)",
                type: .toolResult,
                timestamp: ts,
                text: nil, tool: nil, args: nil,
                output: "import Foundation\nlet x = \(turn)\n",
                toolCallId: toolCallId,
                toolName: "bash",
                isError: false, thinking: nil
            ))
        }

        return events
    }

    // MARK: - Stats

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private func fmt(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
