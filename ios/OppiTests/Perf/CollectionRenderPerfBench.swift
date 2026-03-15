import Testing
import Foundation
import UIKit
@testable import Oppi

// MARK: - Collection Rendering Performance Benchmarks

/// Benchmarks for the UIKit collection view rendering pipeline:
/// snapshot apply, layout pass, and cell configure costs.
///
/// Uses a real UIWindow + UICollectionView via WindowedTimelineHarness
/// to exercise the full rendering path that users experience.
///
/// Output format: METRIC name=number (microseconds)
@Suite("CollectionRenderPerfBench")
@MainActor
struct CollectionRenderPerfBench {

    // MARK: - Configuration

    private static let iterations = 10
    private static let warmupIterations = 2

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
        return Double(median) / 1000.0
    }

    // MARK: - Item Generators

    /// Build a realistic mixed timeline: user messages, assistant responses,
    /// tool calls, and thinking rows.
    static func realisticTimeline(turnCount: Int) -> [ChatItem] {
        var items: [ChatItem] = []
        items.reserveCapacity(turnCount * 5)

        let now = Date()

        for turn in 0..<turnCount {
            items.append(.userMessage(
                id: "user-\(turn)",
                text: "Please analyze the performance of file\(turn).swift and suggest improvements.",
                timestamp: now
            ))

            items.append(.thinking(
                id: "thinking-\(turn)",
                preview: "Analyzing the code structure for performance issues. Looking at allocation patterns, closure captures, and hot loop inefficiencies.",
                hasMore: true,
                isDone: true
            ))

            items.append(.assistantMessage(
                id: "assistant-\(turn)",
                text: """
                I've analyzed file\(turn).swift. Here are the key findings:

                ## Performance Issues

                1. **Closure allocation in hot loop** — Creates a new closure every iteration
                2. **String concatenation** — Using += in a loop is O(n²)

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
                """,
                timestamp: now
            ))

            for t in 0..<2 {
                items.append(.toolCall(
                    id: "tool-\(turn)-\(t)",
                    tool: t == 0 ? "bash" : "read",
                    argsSummary: t == 0 ? "cat src/file\(turn).swift" : "src/file\(turn).swift",
                    outputPreview: "import Foundation\nlet x = \(turn)\nfunc process() { }",
                    outputByteCount: 512,
                    isError: false,
                    isDone: true
                ))
            }
        }

        return items
    }

    /// Build a streaming-style timeline with one actively streaming assistant message.
    static func streamingTimeline(existingTurns: Int, streamingTextLength: Int) -> (items: [ChatItem], streamingID: String) {
        var items = realisticTimeline(turnCount: existingTurns)
        let streamingID = "streaming-assistant"

        items.append(.userMessage(
            id: "user-streaming",
            text: "Explain how async/await works in Swift.",
            timestamp: Date()
        ))

        let streamingText = String(repeating: "Here's how async/await works in Swift. The key concept is structured concurrency. ", count: max(1, streamingTextLength / 80))
        items.append(.assistantMessage(
            id: streamingID,
            text: streamingText,
            timestamp: Date()
        ))

        return (items, streamingID)
    }

    /// Incremental update: add one new tool call to existing items.
    static func incrementalUpdate(base: [ChatItem]) -> [ChatItem] {
        var updated = base
        let idx = updated.count
        updated.append(.toolCall(
            id: "tool-new-\(idx)",
            tool: "bash",
            argsSummary: "echo 'new tool call'",
            outputPreview: "new tool call\n",
            outputByteCount: 64,
            isError: false,
            isDone: true
        ))
        return updated
    }

    /// Streaming text growth: update the streaming assistant message text.
    static func streamingTextGrowth(base: [ChatItem], streamingID: String, newText: String) -> [ChatItem] {
        base.map { item in
            if item.id == streamingID,
               case .assistantMessage(let id, _, let ts) = item {
                return .assistantMessage(id: id, text: newText, timestamp: ts)
            }
            return item
        }
    }

    // MARK: - Benchmark: Full Apply (Cold Start)

    /// Measures the full apply path for an initial load of N items into an
    /// empty collection view: plan build + snapshot apply + layout + cell configure.
    @Test("Full apply: 20-turn cold start")
    func fullApplyColdStart() {
        let items = Self.realisticTimeline(turnCount: 20)
        var h: WindowedTimelineHarness!

        let us = Self.measureMedianUs(
            setup: {
                h = makeWindowedTimelineHarness(sessionId: "bench-cold")
            },
            {
                h.applyItems(items, isBusy: false)
            }
        )

        print("METRIC apply_cold_20turns_us=\(String(format: "%.1f", us))")
        #expect(h.coordinator.currentIDs.count == items.count)
    }

    // MARK: - Benchmark: Incremental Apply (Streaming Tick)

    /// Measures the incremental apply cost during streaming: one new text delta
    /// appended to the streaming assistant message.
    @Test("Incremental apply: streaming text delta")
    func incrementalApplyStreamingDelta() {
        let (baseItems, streamingID) = Self.streamingTimeline(existingTurns: 10, streamingTextLength: 200)

        var h: WindowedTimelineHarness!
        var tickItems: [ChatItem]!
        var tickCount = 0

        let us = Self.measureMedianUs(
            setup: {
                h = makeWindowedTimelineHarness(sessionId: "bench-stream")
                h.applyItems(baseItems, isBusy: true, streamingID: streamingID)
                h.collectionView.layoutIfNeeded()
                tickCount = 0
            },
            {
                // Simulate 10 streaming ticks (33ms coalesced batches)
                for tick in 0..<10 {
                    let chunk = String(repeating: "More analysis of the codebase. ", count: 2)
                    let existingText: String
                    if case .assistantMessage(_, let text, _) = h.coordinator.currentItemByID[streamingID] {
                        existingText = text
                    } else {
                        existingText = ""
                    }
                    tickItems = Self.streamingTextGrowth(
                        base: baseItems,
                        streamingID: streamingID,
                        newText: existingText + chunk
                    )
                    h.applyItems(tickItems, isBusy: true, streamingID: streamingID)
                    tickCount = tick + 1
                }
            }
        )

        // Per-tick cost
        let perTickUs = us / Double(max(1, tickCount))
        print("METRIC apply_streaming_tick_us=\(String(format: "%.1f", perTickUs))")
        #expect(tickCount == 10)
    }

    // MARK: - Benchmark: Incremental Apply (New Item)

    /// Measures adding a single new item to an existing timeline.
    @Test("Incremental apply: add one tool call")
    func incrementalApplyNewItem() {
        let baseItems = Self.realisticTimeline(turnCount: 15)

        var h: WindowedTimelineHarness!
        var updatedItems: [ChatItem]!

        let us = Self.measureMedianUs(
            setup: {
                h = makeWindowedTimelineHarness(sessionId: "bench-incr")
                h.applyItems(baseItems, isBusy: true)
                h.collectionView.layoutIfNeeded()
                updatedItems = Self.incrementalUpdate(base: baseItems)
            },
            {
                h.applyItems(updatedItems, isBusy: true)
            }
        )

        print("METRIC apply_new_item_us=\(String(format: "%.1f", us))")
        #expect(h.coordinator.currentIDs.count == updatedItems.count)
    }

    // MARK: - Benchmark: ApplyPlan Build (Isolated)

    /// Measures just the ChatTimelineApplyPlan.build() cost, isolated from UIKit.
    @Test("ApplyPlan.build: 100 items")
    func applyPlanBuild() {
        let items = Self.realisticTimeline(turnCount: 20)

        let us = Self.measureMedianUs {
            _ = ChatTimelineApplyPlan.build(
                items: items,
                hiddenCount: 0,
                isBusy: false,
                streamingAssistantID: nil
            )
        }

        print("METRIC plan_build_100items_us=\(String(format: "%.1f", us))")
    }

    // MARK: - Benchmark: Snapshot Diff (Changed Items)

    /// Measures reconfigure cost when multiple items change (e.g. theme change).
    @Test("Snapshot reconfigure: 10 changed items")
    func snapshotReconfigure() {
        let items = Self.realisticTimeline(turnCount: 10)

        var h: WindowedTimelineHarness!
        var updatedItems: [ChatItem]!

        let us = Self.measureMedianUs(
            setup: {
                h = makeWindowedTimelineHarness(sessionId: "bench-reconfig")
                h.applyItems(items, isBusy: false)
                h.collectionView.layoutIfNeeded()

                // Mutate several items to trigger reconfigure
                updatedItems = items.map { item in
                    switch item {
                    case .assistantMessage(let id, let text, let ts):
                        return .assistantMessage(id: id, text: text + " (updated)", timestamp: ts)
                    case .toolCall(let id, let tool, let args, let preview, let bytes, let isErr, _):
                        return .toolCall(id: id, tool: tool, argsSummary: args, outputPreview: preview, outputByteCount: bytes, isError: isErr, isDone: true)
                    default:
                        return item
                    }
                }
            },
            {
                h.applyItems(updatedItems, isBusy: false)
            }
        )

        print("METRIC snapshot_reconfigure_us=\(String(format: "%.1f", us))")
    }

    // MARK: - Benchmark: Layout Pass (Isolated)

    /// Measures just the layoutIfNeeded cost after snapshot apply.
    @Test("Layout pass: 50 items after invalidation")
    func layoutPass() {
        let items = Self.realisticTimeline(turnCount: 10)

        var h: WindowedTimelineHarness!

        let us = Self.measureMedianUs(
            setup: {
                h = makeWindowedTimelineHarness(sessionId: "bench-layout")
                h.applyItems(items, isBusy: false)
                h.collectionView.layoutIfNeeded()
            },
            {
                h.collectionView.setNeedsLayout()
                h.collectionView.layoutIfNeeded()
            }
        )

        print("METRIC layout_pass_50items_us=\(String(format: "%.1f", us))")
    }

    // MARK: - Benchmark: uniqueItemsKeepingLast

    /// Measures the dedup function for common (no duplicates) and rare (has duplicates) cases.
    @Test("uniqueItemsKeepingLast: 100 items no duplicates")
    func uniqueItemsNoDuplicates() {
        let items = Self.realisticTimeline(turnCount: 20)

        let us = Self.measureMedianUs {
            _ = ChatTimelineCollectionHost.Controller.uniqueItemsKeepingLast(items)
        }

        print("METRIC unique_items_no_dup_us=\(String(format: "%.1f", us))")
    }

    // MARK: - Benchmark: Snapshot Diff Detection

    /// Measures the reconfigureItemIDs detection cost (what changed between snapshots).
    @Test("reconfigureItemIDs: 50 items, 5 changed")
    func reconfigureItemIDsDetection() {
        let items = Self.realisticTimeline(turnCount: 10)
        let (nextIDs, nextItemByID) = {
            let deduped = ChatTimelineCollectionHost.Controller.uniqueItemsKeepingLast(items)
            return (deduped.orderedIDs, deduped.itemByID)
        }()
        let nextIDSet = Set(nextIDs)

        // Create "previous" with slightly different items
        var prevItems = items
        for i in stride(from: 0, to: min(prevItems.count, 10), by: 2) {
            if case .assistantMessage(let id, let text, let ts) = prevItems[i] {
                prevItems[i] = .assistantMessage(id: id, text: text + "x", timestamp: ts)
            }
        }
        let prevDeduped = ChatTimelineCollectionHost.Controller.uniqueItemsKeepingLast(prevItems)

        let us = Self.measureMedianUs {
            _ = TimelineSnapshotApplier.reconfigureItemIDs(
                nextIDs: nextIDs,
                nextIDSet: nextIDSet,
                nextItemByID: nextItemByID,
                previousItemByID: prevDeduped.itemByID,
                hiddenCount: 0,
                previousHiddenCount: 0,
                streamingAssistantID: nil,
                previousStreamingAssistantID: nil,
                themeChanged: false
            )
        }

        print("METRIC reconfigure_detect_us=\(String(format: "%.1f", us))")
    }

    // MARK: - Aggregate Primary Metric

    @Test("Aggregate: total collection rendering cost")
    func aggregateMetric() {
        let items20 = Self.realisticTimeline(turnCount: 20)
        let items10 = Self.realisticTimeline(turnCount: 10)
        let items15 = Self.realisticTimeline(turnCount: 15)
        let (streamItems, streamID) = Self.streamingTimeline(existingTurns: 10, streamingTextLength: 200)

        // 1. Full apply cold start (20 turns = 100 items)
        var h1: WindowedTimelineHarness!
        let coldStartUs = Self.measureMedianUs(
            setup: { h1 = makeWindowedTimelineHarness(sessionId: "agg-cold") },
            { h1.applyItems(items20, isBusy: false) }
        )

        // 2. Streaming tick (per-tick cost)
        var h2: WindowedTimelineHarness!
        var tickCount2 = 0
        let streamingTotalUs = Self.measureMedianUs(
            setup: {
                h2 = makeWindowedTimelineHarness(sessionId: "agg-stream")
                h2.applyItems(streamItems, isBusy: true, streamingID: streamID)
                h2.collectionView.layoutIfNeeded()
                tickCount2 = 0
            },
            {
                for tick in 0..<10 {
                    let chunk = String(repeating: "More content. ", count: 2)
                    let existingText: String
                    if case .assistantMessage(_, let text, _) = h2.coordinator.currentItemByID[streamID] {
                        existingText = text
                    } else {
                        existingText = ""
                    }
                    let updated = Self.streamingTextGrowth(
                        base: streamItems,
                        streamingID: streamID,
                        newText: existingText + chunk
                    )
                    h2.applyItems(updated, isBusy: true, streamingID: streamID)
                    tickCount2 = tick + 1
                }
            }
        )
        let streamingTickUs = streamingTotalUs / Double(max(1, tickCount2))

        // 3. Incremental new item
        var h3: WindowedTimelineHarness!
        var updatedItems3: [ChatItem]!
        let newItemUs = Self.measureMedianUs(
            setup: {
                h3 = makeWindowedTimelineHarness(sessionId: "agg-incr")
                h3.applyItems(items15, isBusy: true)
                h3.collectionView.layoutIfNeeded()
                updatedItems3 = Self.incrementalUpdate(base: items15)
            },
            { h3.applyItems(updatedItems3, isBusy: true) }
        )

        // 4. ApplyPlan.build
        let planBuildUs = Self.measureMedianUs {
            _ = ChatTimelineApplyPlan.build(
                items: items20,
                hiddenCount: 0,
                isBusy: false,
                streamingAssistantID: nil
            )
        }

        // 5. Snapshot reconfigure (10 changed items)
        var h5: WindowedTimelineHarness!
        var reconfigItems: [ChatItem]!
        let reconfigureUs = Self.measureMedianUs(
            setup: {
                h5 = makeWindowedTimelineHarness(sessionId: "agg-reconfig")
                h5.applyItems(items10, isBusy: false)
                h5.collectionView.layoutIfNeeded()
                reconfigItems = items10.map { item in
                    switch item {
                    case .assistantMessage(let id, let text, let ts):
                        return .assistantMessage(id: id, text: text + " (v2)", timestamp: ts)
                    default:
                        return item
                    }
                }
            },
            { h5.applyItems(reconfigItems, isBusy: false) }
        )

        // 6. Layout pass only (no content change)
        var h6: WindowedTimelineHarness!
        let layoutUs = Self.measureMedianUs(
            setup: {
                h6 = makeWindowedTimelineHarness(sessionId: "agg-layout")
                h6.applyItems(items10, isBusy: false)
                h6.collectionView.layoutIfNeeded()
            },
            {
                h6.collectionView.setNeedsLayout()
                h6.collectionView.layoutIfNeeded()
            }
        )

        // 7. uniqueItemsKeepingLast
        let uniqueUs = Self.measureMedianUs {
            _ = ChatTimelineCollectionHost.Controller.uniqueItemsKeepingLast(items20)
        }

        // 8. reconfigureItemIDs
        let deduped20 = ChatTimelineCollectionHost.Controller.uniqueItemsKeepingLast(items20)
        let nextIDSet20 = Set(deduped20.orderedIDs)
        var prevItems20 = items20
        for i in stride(from: 0, to: min(prevItems20.count, 10), by: 2) {
            if case .assistantMessage(let id, let text, let ts) = prevItems20[i] {
                prevItems20[i] = .assistantMessage(id: id, text: text + "x", timestamp: ts)
            }
        }
        let prevDeduped20 = ChatTimelineCollectionHost.Controller.uniqueItemsKeepingLast(prevItems20)
        let detectUs = Self.measureMedianUs {
            _ = TimelineSnapshotApplier.reconfigureItemIDs(
                nextIDs: deduped20.orderedIDs,
                nextIDSet: nextIDSet20,
                nextItemByID: deduped20.itemByID,
                previousItemByID: prevDeduped20.itemByID,
                hiddenCount: 0,
                previousHiddenCount: 0,
                streamingAssistantID: nil,
                previousStreamingAssistantID: nil,
                themeChanged: false
            )
        }

        let total = coldStartUs + streamingTickUs + newItemUs + planBuildUs
            + reconfigureUs + layoutUs + uniqueUs + detectUs

        print("METRIC total_us=\(String(format: "%.1f", total))")
        print("METRIC apply_cold_20turns_us=\(String(format: "%.1f", coldStartUs))")
        print("METRIC apply_streaming_tick_us=\(String(format: "%.1f", streamingTickUs))")
        print("METRIC apply_new_item_us=\(String(format: "%.1f", newItemUs))")
        print("METRIC plan_build_100items_us=\(String(format: "%.1f", planBuildUs))")
        print("METRIC snapshot_reconfigure_us=\(String(format: "%.1f", reconfigureUs))")
        print("METRIC layout_pass_50items_us=\(String(format: "%.1f", layoutUs))")
        print("METRIC unique_items_no_dup_us=\(String(format: "%.1f", uniqueUs))")
        print("METRIC reconfigure_detect_us=\(String(format: "%.1f", detectUs))")

        #expect(total > 0)
    }
}
