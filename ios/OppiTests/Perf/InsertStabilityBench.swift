import Foundation
import Testing
import UIKit
@testable import Oppi

/// Measures viewport stability when structural items (tool calls, system events,
/// permission markers) are inserted into the timeline while the user is attached
/// to the bottom (following streaming).
///
/// The primary metric `insert_stability_score` captures maximum contentOffset
/// drift across different insertion types. Lower = more stable = less bounce.
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

            allToolDrift.append(r.toolInsertDriftPt)
            allSystemDrift.append(r.systemInsertDriftPt)
            allPermDrift.append(r.permissionInsertDriftPt)
            allMultiDrift.append(r.multiInsertDriftPt)
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
        let toolInsertDriftPt: Double
        let systemInsertDriftPt: Double
        let permissionInsertDriftPt: Double
        let multiInsertDriftPt: Double
        let totalInsertMs: Double
        let allFinite: Bool
    }

    // MARK: - Runner

    @MainActor
    private func runInsertStability() -> InsertResult {
        let harness = makeBenchHarness()
        let cv = harness.collectionView
        let reducer = harness.reducer

        // Load some history to fill the viewport
        let trace = makeBaseHistory(turnCount: 10)
        reducer.loadSession(trace)
        harness.items = reducer.items
        harness.applyItems(isBusy: false)
        cv.layoutIfNeeded()

        // Force all cells to be measured (scroll through all content)
        scrollThroughAll(cv)
        scrollToBottom(cv)
        cv.layoutIfNeeded()

        // Start streaming — user is attached to bottom
        reducer.processBatch([.agentStart(sessionId: "bench")])

        // Add some streaming text so there's an active assistant row at bottom
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

        var totalInsertNs: UInt64 = 0

        // --- Test 1: Single tool call insertion ---
        let toolDrift = measureInsertDrift(harness: harness, cv: cv) {
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
        } totalNs: &totalInsertNs

        // Continue streaming after tool
        reducer.processBatch([
            .textDelta(sessionId: "bench", delta: "After tool result. ")
        ])
        harness.items = reducer.items
        harness.applyItems(
            streamingID: reducer.streamingAssistantID,
            isBusy: true
        )
        cv.layoutIfNeeded()
        scrollToBottom(cv)
        cv.layoutIfNeeded()

        // --- Test 2: System event (compaction) insertion ---
        let sysDrift = measureInsertDrift(harness: harness, cv: cv) {
            reducer.processBatch([
                .compactionStart(sessionId: "bench", reason: "overflow"),
            ])
            harness.items = reducer.items
            harness.applyItems(
                streamingID: reducer.streamingAssistantID,
                isBusy: true
            )
        } totalNs: &totalInsertNs

        // Complete compaction and continue
        reducer.processBatch([
            .compactionEnd(
                sessionId: "bench",
                aborted: false,
                willRetry: false,
                summary: "Compacted successfully",
                tokensBefore: 45000
            ),
        ])
        harness.items = reducer.items
        harness.applyItems(
            streamingID: reducer.streamingAssistantID,
            isBusy: true
        )
        cv.layoutIfNeeded()
        scrollToBottom(cv)
        cv.layoutIfNeeded()

        // --- Test 3: Permission resolved insertion ---
        let permDrift = measureInsertDrift(harness: harness, cv: cv) {
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
        } totalNs: &totalInsertNs

        // Continue streaming
        reducer.processBatch([
            .textDelta(sessionId: "bench", delta: "Permission handled. ")
        ])
        harness.items = reducer.items
        harness.applyItems(
            streamingID: reducer.streamingAssistantID,
            isBusy: true
        )
        cv.layoutIfNeeded()
        scrollToBottom(cv)
        cv.layoutIfNeeded()

        // --- Test 4: Multiple items inserted at once ---
        let multiDrift = measureInsertDrift(harness: harness, cv: cv) {
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
            // Also a system event in the same batch
            reducer.processBatch([
                .compactionStart(sessionId: "bench", reason: "manual"),
            ])
            harness.items = reducer.items
            harness.applyItems(
                streamingID: reducer.streamingAssistantID,
                isBusy: true
            )
        } totalNs: &totalInsertNs

        let totalMs = Double(totalInsertNs) / 1_000_000.0

        let allMetrics = [toolDrift, sysDrift, permDrift, multiDrift, totalMs]
        let allFinite = allMetrics.allSatisfy { $0.isFinite && $0 >= 0 }

        harness.window.isHidden = true

        return InsertResult(
            toolInsertDriftPt: toolDrift,
            systemInsertDriftPt: sysDrift,
            permissionInsertDriftPt: permDrift,
            multiInsertDriftPt: multiDrift,
            totalInsertMs: totalMs,
            allFinite: allFinite
        )
    }

    // MARK: - Drift Measurement

    /// Measure the maximum contentOffset drift caused by an insertion.
    ///
    /// The key insight: when the user is at the bottom and new items are inserted,
    /// the viewport should stay pinned to the bottom. Any transient jump in
    /// contentOffset between the snapshot apply and the settled layout is
    /// visible bounce.
    ///
    /// We measure this by capturing the contentOffset and contentSize before
    /// the insertion, then after insertion + layout, checking if the relationship
    /// between contentOffset and contentSize bottom edge has changed.
    @MainActor
    private func measureInsertDrift(
        harness: BenchHarness,
        cv: AnchoredCollectionView,
        insert: () -> Void,
        totalNs: inout UInt64
    ) -> Double {
        // Settle at bottom
        scrollToBottom(cv)
        cv.layoutIfNeeded()

        // Capture pre-insert state
        let offsetBefore = cv.contentOffset.y
        let contentHeightBefore = cv.contentSize.height

        let start = DispatchTime.now().uptimeNanoseconds

        // Perform the insertion
        insert()

        // After the coordinator.apply() inside the insert block, the snapshot
        // is applied but cells may not be fully self-sized yet. Capture
        // the intermediate state.
        let offsetAfterApply = cv.contentOffset.y
        let contentHeightAfterApply = cv.contentSize.height

        // Force full layout resolution
        cv.layoutIfNeeded()
        let offsetAfterLayout = cv.contentOffset.y
        let contentHeightAfterLayout = cv.contentSize.height

        let end = DispatchTime.now().uptimeNanoseconds
        totalNs += (end &- start)

        // The drift is the difference in distance-from-bottom before and after.
        // If the insertion was perfectly stable, the user would stay at the bottom
        // throughout. Any intermediate deviation is visible as a bounce.
        let insets = cv.adjustedContentInset
        let viewportH = cv.bounds.height - insets.top - insets.bottom

        // Distance from bottom after apply (before layout settles)
        let bottomAfterApply = contentHeightAfterApply - (offsetAfterApply + insets.top + viewportH)

        // Distance from bottom after layout settles
        let bottomAfterLayout = contentHeightAfterLayout - (offsetAfterLayout + insets.top + viewportH)

        // The drift the user sees is the maximum deviation from "at bottom" (0pt)
        // during the insertion process
        let maxDeviation = max(abs(bottomAfterApply), abs(bottomAfterLayout))

        // Also track the jump between apply and layout (the self-sizing correction)
        let layoutJump = abs(offsetAfterLayout - offsetAfterApply)

        return max(maxDeviation, layoutJump)
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
