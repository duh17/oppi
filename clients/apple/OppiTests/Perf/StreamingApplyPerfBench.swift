import Foundation
import Testing
import UIKit
@testable import Oppi

/// Streaming apply pipeline performance benchmark.
///
/// Measures:
/// - **streaming_p95_us**: p95 apply duration during streaming ticks (primary)
/// - **streaming_max_us**: worst-case apply duration
/// - **zero_change_avg_us**: avg cost when nothing changed between ticks
/// - **jank_pct_over_33ms**: percentage of applies exceeding 33ms coalescer budget
///
/// Uses a real UIWindow + UICollectionView with 80+ items to match production
/// conditions where perf degrades.
@Suite("StreamingApplyPerfBench")
@MainActor
struct StreamingApplyPerfBench {

    // MARK: - Configuration

    /// Number of streaming ticks to measure (excluding warmup).
    private static let measureTicks = 100
    /// Warmup ticks before measurement begins.
    private static let warmupTicks = 10
    /// Number of zero-change ticks to measure.
    private static let zeroChangeTicks = 50
    /// Number of existing turns to build an 80+ item timeline.
    private static let turnCount = 16

    // MARK: - Harness

    @MainActor
    private final class Harness {
        let window: UIWindow
        let collectionView: AnchoredCollectionView
        let coordinator: ChatTimelineCollectionHost.Controller
        let reducer: TimelineReducer
        let toolOutputStore: ToolOutputStore
        let toolArgsStore: ToolArgsStore
        let toolSegmentStore: ToolSegmentStore
        let connection: ServerConnection
        let scrollController: ChatScrollController
        let audioPlayer: AudioPlayerService

        init() {
            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first
            else {
                fatalError("Missing UIWindowScene")
            }

            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)

            collectionView = AnchoredCollectionView(
                frame: window.bounds,
                collectionViewLayout: ChatTimelineCollectionHost.makeTestLayout()
            )
            window.addSubview(collectionView)
            window.makeKeyAndVisible()

            coordinator = ChatTimelineCollectionHost.Controller()
            coordinator.configureDataSource(collectionView: collectionView)
            collectionView.delegate = coordinator

            reducer = TimelineReducer()
            toolOutputStore = ToolOutputStore()
            toolArgsStore = ToolArgsStore()
            toolSegmentStore = ToolSegmentStore()
            connection = ServerConnection()
            scrollController = ChatScrollController()
            audioPlayer = AudioPlayerService()
        }

        func apply(
            items: [ChatItem],
            streamingAssistantID: String? = nil,
            isBusy: Bool = true
        ) {
            let config = makeTimelineConfiguration(
                items: items,
                isBusy: isBusy,
                streamingAssistantID: streamingAssistantID,
                sessionId: "bench-streaming-apply",
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

        deinit {
            MainActor.assumeIsolated {
                window.isHidden = true
            }
        }
    }

    // MARK: - Timeline Builder

    /// Build a realistic 80+ item timeline with mixed content.
    /// turnCount=16 produces: 16 user + 16 thinking + 16 assistant + 32 tool = 80 items.
    private static func buildTimeline(turnCount: Int) -> [ChatItem] {
        var items: [ChatItem] = []
        items.reserveCapacity(turnCount * 5 + 2)
        let now = Date()

        for turn in 0..<turnCount {
            items.append(.userMessage(
                id: "user-\(turn)",
                text: "Analyze the performance of module\(turn) and suggest improvements for the hot path.",
                timestamp: now
            ))

            items.append(.thinking(
                id: "thinking-\(turn)",
                preview: "Looking at allocation patterns, closure captures, and loop inefficiencies in module\(turn).",
                hasMore: true,
                isDone: true
            ))

            items.append(.assistantMessage(
                id: "assistant-\(turn)",
                text: """
                I've analyzed module\(turn). Key findings:

                ## Performance Issues

                1. **Closure allocation in hot loop** — Creates a new closure every iteration
                2. **String concatenation** — Using += in a loop is O(n^2)

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

                The fix reduces allocation count by 3x and eliminates the quadratic growth.
                """,
                timestamp: now
            ))

            for t in 0..<2 {
                items.append(.toolCall(
                    id: "tool-\(turn)-\(t)",
                    tool: t == 0 ? "bash" : "read",
                    argsSummary: t == 0 ? "$ cat src/module\(turn).swift" : "src/module\(turn).swift",
                    outputPreview: "import Foundation\nlet x = \(turn)\nfunc process() { /* ... */ }",
                    outputByteCount: 512,
                    isError: false,
                    isDone: true
                ))
            }
        }

        return items
    }

    /// Append a streaming assistant + in-flight tool to the base timeline.
    private static func withStreamingTail(
        base: [ChatItem],
        streamingText: String
    ) -> (items: [ChatItem], streamingID: String) {
        var items = base
        let streamingID = "streaming-assistant"

        items.append(.userMessage(
            id: "user-streaming",
            text: "Explain how async/await works in Swift.",
            timestamp: Date()
        ))

        // In-flight tool alongside the streaming assistant — tests mutable scan cost.
        items.append(.toolCall(
            id: "tool-inflight",
            tool: "bash",
            argsSummary: "$ npm test",
            outputPreview: "",
            outputByteCount: 0,
            isError: false,
            isDone: false
        ))

        items.append(.assistantMessage(
            id: streamingID,
            text: streamingText,
            timestamp: Date()
        ))

        return (items, streamingID)
    }

    // MARK: - Stats

    private struct Stats {
        let p50Us: Double
        let p95Us: Double
        let maxUs: Double
        let avgUs: Double
        let jankPctOver33ms: Double

        init(durationsNs: [UInt64]) {
            let sorted = durationsNs.sorted()
            let count = sorted.count
            guard count > 0 else {
                p50Us = 0; p95Us = 0; maxUs = 0; avgUs = 0; jankPctOver33ms = 0
                return
            }

            let toUs = { (ns: UInt64) -> Double in Double(ns) / 1000.0 }
            p50Us = toUs(sorted[count / 2])
            p95Us = toUs(sorted[min(count - 1, count * 95 / 100)])
            maxUs = toUs(sorted[count - 1])
            avgUs = toUs(sorted.reduce(0, +) / UInt64(count))

            let jankThresholdNs: UInt64 = 33_000_000  // 33ms
            let jankCount = sorted.filter { $0 > jankThresholdNs }.count
            jankPctOver33ms = Double(jankCount) / Double(count) * 100.0
        }
    }

    // MARK: - Primary Benchmark

    @Test("Streaming apply pipeline: p95, max, zero-change, jank")
    func streamingApplyPipeline() {
        let h = Harness()
        let baseItems = Self.buildTimeline(turnCount: Self.turnCount)
        let initialText = "Here's how async/await works in Swift. "

        // --- Setup: prime the timeline with 80+ items ---
        let (initialItems, streamingID) = Self.withStreamingTail(
            base: baseItems,
            streamingText: initialText
        )
        h.apply(items: initialItems, streamingAssistantID: streamingID)
        h.collectionView.layoutIfNeeded()

        let itemCount = h.coordinator.currentIDs.count
        #expect(itemCount >= 80, "Need 80+ items for realistic bench, got \(itemCount)")

        // Scroll to bottom so the streaming assistant cell is visible.
        // In production, the user watches the streaming assistant at the bottom.
        // Without this, the cell configure (including markdown rendering) doesn't
        // fire during reconfigure, making the bench unrealistically fast.
        let lastIndex = IndexPath(item: h.coordinator.currentIDs.count - 1, section: 0)
        h.collectionView.scrollToItem(at: lastIndex, at: .bottom, animated: false)
        h.collectionView.layoutIfNeeded()

        // --- Phase 1: Streaming ticks (text grows each tick) ---
        var streamingDurationsNs: [UInt64] = []
        streamingDurationsNs.reserveCapacity(Self.measureTicks)

        var currentText = initialText
        let totalTicks = Self.warmupTicks + Self.measureTicks

        for tick in 0..<totalTicks {
            let chunk = "The key concept is structured concurrency, which provides safety guarantees. Tick \(tick). "
            currentText += chunk

            let (tickItems, _) = Self.withStreamingTail(
                base: baseItems,
                streamingText: currentText
            )

            let startNs = DispatchTime.now().uptimeNanoseconds
            h.apply(items: tickItems, streamingAssistantID: streamingID)
            let endNs = DispatchTime.now().uptimeNanoseconds

            if tick >= Self.warmupTicks {
                streamingDurationsNs.append(endNs &- startNs)
            }
        }

        let streamingStats = Stats(durationsNs: streamingDurationsNs)

        // --- Phase 2: Zero-change ticks (identical input) ---
        let lastItems: [ChatItem]
        (lastItems, _) = Self.withStreamingTail(
            base: baseItems,
            streamingText: currentText
        )

        // Prime with the current state.
        h.apply(items: lastItems, streamingAssistantID: streamingID)

        var zeroChangeDurationsNs: [UInt64] = []
        zeroChangeDurationsNs.reserveCapacity(Self.zeroChangeTicks)

        for _ in 0..<Self.zeroChangeTicks {
            let startNs = DispatchTime.now().uptimeNanoseconds
            h.apply(items: lastItems, streamingAssistantID: streamingID)
            let endNs = DispatchTime.now().uptimeNanoseconds
            zeroChangeDurationsNs.append(endNs &- startNs)
        }

        let zeroChangeStats = Stats(durationsNs: zeroChangeDurationsNs)

        // --- Emit METRIC lines ---
        print("METRIC streaming_p95_us=\(String(format: "%.1f", streamingStats.p95Us))")
        print("METRIC streaming_max_us=\(String(format: "%.1f", streamingStats.maxUs))")
        print("METRIC streaming_p50_us=\(String(format: "%.1f", streamingStats.p50Us))")
        print("METRIC streaming_avg_us=\(String(format: "%.1f", streamingStats.avgUs))")
        print("METRIC zero_change_avg_us=\(String(format: "%.1f", zeroChangeStats.avgUs))")
        print("METRIC zero_change_max_us=\(String(format: "%.1f", zeroChangeStats.maxUs))")
        print("METRIC jank_pct_over_33ms=\(String(format: "%.1f", streamingStats.jankPctOver33ms))")
        print("METRIC item_count=\(itemCount)")

        // Sanity: streaming assistant text actually grew.
        if case .assistantMessage(_, let finalText, _) = h.coordinator.currentItemByID[streamingID] {
            #expect(finalText.count > initialText.count, "Streaming text should have grown")
        } else {
            Issue.record("Expected streaming assistant item at end of bench")
        }
    }
}
