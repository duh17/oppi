import Foundation
import Testing
import UIKit
@testable import Oppi

/// Measures viewport stability when structural items are inserted into
/// the timeline during streaming. The primary metric captures the
/// contentOffset deviation caused by each type of structural insert.
///
/// Since UICollectionViewDiffableDataSource.apply(animatingDifferences: false)
/// resolves all cell heights synchronously, the drift measurement captures
/// the offset jump that occurs during the snapshot apply + forced layout
/// cycle. Lower = more stable.
@Suite("InsertStabilityBench")
struct InsertStabilityBench {

    private static let iterations = 5
    private static let warmupIterations = 2

    @MainActor
    @Test func insert_stability_score() {
        var allToolDrift: [Double] = []
        var allSystemDrift: [Double] = []
        var allPermDrift: [Double] = []
        var allMultiDrift: [Double] = []
        var allTotalMs: [Double] = []
        var inv_allFinite = true

        for run in 0 ..< (Self.warmupIterations + Self.iterations) {
            let r = runInsertStability()
            guard run >= Self.warmupIterations else { continue }

            allToolDrift.append(r.toolDrift)
            allSystemDrift.append(r.systemDrift)
            allPermDrift.append(r.permissionDrift)
            allMultiDrift.append(r.multiDrift)
            allTotalMs.append(r.totalInsertMs)

            if !r.allFinite { inv_allFinite = false }
        }

        let toolDrift = median(allToolDrift)
        let sysDrift = median(allSystemDrift)
        let permDrift = median(allPermDrift)
        let multiDrift = median(allMultiDrift)
        let totalMs = median(allTotalMs)

        let score = toolDrift * 3
            + sysDrift * 2
            + permDrift * 3
            + multiDrift * 2

        print("METRIC insert_stability_score=\(fmt(score))")
        print("METRIC tool_insert_drift_pt=\(fmt(toolDrift))")
        print("METRIC system_insert_drift_pt=\(fmt(sysDrift))")
        print("METRIC permission_insert_drift_pt=\(fmt(permDrift))")
        print("METRIC multi_insert_drift_pt=\(fmt(multiDrift))")
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
        let multiDrift: Double
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

        // --- Test 1: Tool call in animation context ---
        // Simulate what happens in production when a SwiftUI animation
        // transaction wraps the updateUIView call (e.g. from PermissionOverlay).
        let toolDrift = measureInsertWithAnimationContext(
            harness: harness, cv: cv, totalNs: &totalInsertNs
        ) {
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
        }
        settle(harness: harness, cv: cv, reducer: reducer)

        // --- Test 2: System event in animation context ---
        let sysDrift = measureInsertWithAnimationContext(
            harness: harness, cv: cv, totalNs: &totalInsertNs
        ) {
            reducer.processBatch([
                .compactionStart(sessionId: "bench", reason: "overflow"),
            ])
            harness.items = reducer.items
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

        // --- Test 3: Permission resolved in animation context ---
        let permDrift = measureInsertWithAnimationContext(
            harness: harness, cv: cv, totalNs: &totalInsertNs
        ) {
            reducer.resolvePermission(
                id: "bench-perm-1",
                outcome: .allowed,
                tool: "bash",
                summary: "rm -rf /tmp/test"
            )
            harness.items = reducer.items
        }
        settle(harness: harness, cv: cv, reducer: reducer)

        // --- Test 4: Multiple items in animation context ---
        let multiDrift = measureInsertWithAnimationContext(
            harness: harness, cv: cv, totalNs: &totalInsertNs
        ) {
            let toolId2 = "bench-tool-multi"
            reducer.processBatch([
                .toolStart(
                    sessionId: "bench",
                    toolEventId: toolId2,
                    tool: "bash",
                    args: ["command": .string("echo test")]
                ),
                .toolOutput(
                    sessionId: "bench",
                    toolEventId: toolId2,
                    output: "test\n",
                    isError: false
                ),
                .toolEnd(sessionId: "bench", toolEventId: toolId2, isError: false),
            ])
            reducer.processBatch([
                .compactionStart(sessionId: "bench", reason: "manual"),
            ])
            harness.items = reducer.items
        }

        let totalMs = Double(totalInsertNs) / 1_000_000.0
        let allMetrics = [toolDrift, sysDrift, permDrift, multiDrift, totalMs]
        let allFinite = allMetrics.allSatisfy { $0.isFinite && $0 >= 0 }

        harness.window.isHidden = true

        return InsertResult(
            toolDrift: toolDrift,
            systemDrift: sysDrift,
            permissionDrift: permDrift,
            multiDrift: multiDrift,
            totalInsertMs: totalMs,
            allFinite: allFinite
        )
    }

    // MARK: - Drift with Animation Context

    /// Measures drift when the apply happens inside a UIKit animation context.
    ///
    /// In production, SwiftUI can wrap `updateUIView` in an implicit animation
    /// transaction (from `.animation()` modifiers on sibling views). This
    /// causes snapshot applies and layout changes to animate with spring
    /// dynamics, creating visible bounce.
    ///
    /// The metric captures the offset deviation during and after a
    /// spring-animated insertion, then drains 10 frames to measure the
    /// cumulative bounce.
    @MainActor
    private func measureInsertWithAnimationContext(
        harness: BenchHarness,
        cv: AnchoredCollectionView,
        totalNs: inout UInt64,
        insert: () -> Void
    ) -> Double {
        scrollToBottom(cv)
        cv.layoutIfNeeded()
        harness.scrollController.updateNearBottom(true)

        let offsetBefore = cv.contentOffset.y

        let start = DispatchTime.now().uptimeNanoseconds

        // Simulate SwiftUI animation context leaking into updateUIView.
        // Use UIView.animate with spring to match what .animation(.snappy)
        // would produce.
        insert()

        UIView.animate(
            withDuration: 0.3,
            delay: 0,
            usingSpringWithDamping: 0.7,
            initialSpringVelocity: 0,
            options: [.beginFromCurrentState]
        ) {
            harness.applyItems(
                streamingID: harness.reducer.streamingAssistantID,
                isBusy: true
            )
            cv.layoutIfNeeded()
        }

        // The apply happened inside the animation block. Capture the
        // presentation layer's position vs model layer to measure bounce.
        let modelOffset = cv.contentOffset.y

        // Drain frames to let the spring animation play out
        var maxDrift: CGFloat = 0
        for _ in 0 ..< 10 {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.033))

            // Check presentation layer offset
            if let presentationLayer = cv.layer.presentation() {
                let presentationOffset = -presentationLayer.bounds.origin.y
                let drift = abs(presentationOffset - modelOffset)
                maxDrift = max(maxDrift, drift)
            }

            // Also check the actual contentOffset (model)
            let offsetDrift = abs(cv.contentOffset.y - modelOffset)
            maxDrift = max(maxDrift, offsetDrift)
        }

        // Settle
        cv.layer.removeAllAnimations()
        cv.layoutIfNeeded()

        let end = DispatchTime.now().uptimeNanoseconds
        totalNs += (end &- start)

        // Scroll back to bottom
        scrollToBottom(cv)
        cv.layoutIfNeeded()
        harness.scrollController.updateNearBottom(true)

        return Double(maxDrift)
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
