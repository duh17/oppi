// swiftlint:disable:next file_length
import Testing
import Foundation
@testable import Oppi

/// Stress tests for the chat timeline hot path.
///
/// These tests exercise the exact code paths that caused real-world hangs:
/// - TimelineReducer.loadSession with 200+ events (ForEach identity tracking)
/// - processBatch under rapid streaming (coalesced 33ms batches)
/// - Session switching (reset + loadSession churn)
/// - MarkdownSegmentCache under eviction pressure
/// - Large timeline preservation (no trimming)
/// - ToolOutputStore memory bounds
///
/// Each test asserts correctness AND measures wall-clock time against a budget.
/// Budgets are generous (10x typical) to catch regressions, not benchmark.
@Suite("TimelineStress")
struct TimelineStressTests {

    // MARK: - loadSession at scale

    @MainActor
    @Test func loadSession200Events() {
        let reducer = TimelineReducer()
        let events = makeTraceEvents(count: 200)

        let start = ContinuousClock.now
        reducer.loadSession(events)
        let elapsed = ContinuousClock.now - start

        #expect(reducer.items.count == 200)
        #expect(elapsed < .milliseconds(500),
            "loadSession(200) took \(elapsed) — budget 500ms")
    }

    @MainActor
    @Test func loadSession400Events() {
        let reducer = TimelineReducer()
        let events = makeTraceEvents(count: 400)

        let start = ContinuousClock.now
        reducer.loadSession(events)
        let elapsed = ContinuousClock.now - start

        #expect(reducer.items.count == 400)
        #expect(elapsed < .seconds(1),
            "loadSession(400) took \(elapsed) — budget 1s")
    }

    @MainActor
    @Test func loadSession600MixedEvents() {
        let reducer = TimelineReducer()
        let events = makeMixedTraceEvents(count: 600)

        let start = ContinuousClock.now
        reducer.loadSession(events)
        let elapsed = ContinuousClock.now - start

        // All items preserved (no trimming)
        // Mixed events: user(120) + assistant(120) + toolCall(120) + toolResult(updates toolCall) + thinking(120) = ~480 items
        #expect(reducer.items.count > 300, "Should preserve all items: got \(reducer.items.count)")
        #expect(elapsed < .seconds(1),
            "loadSession(600 mixed) took \(elapsed) — budget 1s")

        // Verify tool output was stored correctly
        let toolItems = reducer.items.compactMap { item -> String? in
            guard case .toolCall(let id, _, _, _, _, _, _) = item else { return nil }
            return id
        }
        for toolId in toolItems {
            let output = reducer.toolOutputStore.fullOutput(for: toolId)
            #expect(!output.isEmpty, "Tool \(toolId) should have output stored")
        }
    }

    // MARK: - Incremental loadSession (no-op and append)

    @MainActor
    @Test func incrementalNoOpIsFree() {
        let reducer = TimelineReducer()
        let events = makeTraceEvents(count: 200)

        reducer.loadSession(events)
        let versionBefore = reducer.renderVersion

        let start = ContinuousClock.now
        for _ in 0..<50 {
            reducer.loadSession(events)
        }
        let elapsed = ContinuousClock.now - start

        #expect(reducer._lastLoadWasIncrementalForTesting)
        #expect(reducer.renderVersion == versionBefore, "No-op reload should not bump version")
        #expect(elapsed < .milliseconds(100),
            "50x no-op reloads took \(elapsed) — budget 100ms")
    }

    @MainActor
    @Test func incrementalAppend50Events() {
        let reducer = TimelineReducer()
        let base = makeTraceEvents(count: 150)
        reducer.loadSession(base)

        let extended = base + makeTraceEvents(count: 50, startIndex: 150)

        let start = ContinuousClock.now
        reducer.loadSession(extended)
        let elapsed = ContinuousClock.now - start

        #expect(reducer._lastLoadWasIncrementalForTesting)
        #expect(reducer.items.count == 200)
        #expect(elapsed < .milliseconds(200),
            "Incremental append(50) took \(elapsed) — budget 200ms")
    }

    // MARK: - processBatch streaming simulation

    @MainActor
    @Test func processBatch100TextDeltas() {
        let reducer = TimelineReducer()
        reducer.process(.agentStart(sessionId: "s1"))

        var batch: [AgentEvent] = []
        for i in 0..<100 {
            batch.append(.textDelta(sessionId: "s1", delta: "Token \(i) "))
        }

        let start = ContinuousClock.now
        reducer.processBatch(batch)
        let elapsed = ContinuousClock.now - start

        #expect(reducer.items.count == 1) // Single assistant message
        guard case .assistantMessage(_, let text, _) = reducer.items[0] else {
            Issue.record("Expected assistant message")
            return
        }
        #expect(text.count > 500, "Should have accumulated all deltas")
        #expect(elapsed < .milliseconds(100),
            "processBatch(100 deltas) took \(elapsed) — budget 100ms")
    }

    @MainActor
    @Test func processBatchRepeated30FPS() {
        // Simulate 3 seconds of streaming at 30fps (90 batches of 5 deltas)
        let reducer = TimelineReducer()
        reducer.process(.agentStart(sessionId: "s1"))

        let start = ContinuousClock.now
        for frame in 0..<90 {
            var batch: [AgentEvent] = []
            for token in 0..<5 {
                batch.append(.textDelta(sessionId: "s1", delta: "f\(frame)t\(token) "))
            }
            reducer.processBatch(batch)
        }
        let elapsed = ContinuousClock.now - start

        #expect(reducer.items.count == 1)
        guard case .assistantMessage(_, let text, _) = reducer.items[0] else {
            Issue.record("Expected assistant message")
            return
        }
        #expect(text.contains("f89t4"), "Should contain last token")
        #expect(elapsed < .milliseconds(500),
            "90 frames x 5 deltas took \(elapsed) — budget 500ms")
    }

    @MainActor
    @Test func processBatchWithToolOutputBursts() {
        let reducer = TimelineReducer()
        reducer.process(.agentStart(sessionId: "s1"))

        // Simulate a tool that streams large output
        reducer.process(.toolStart(sessionId: "s1", toolEventId: "t1", tool: "bash", args: [:]))

        let lineCount = 500
        var batch: [AgentEvent] = []
        for i in 0..<lineCount {
            batch.append(.toolOutput(
                sessionId: "s1", toolEventId: "t1",
                output: "line \(i): " + String(repeating: "x", count: 80) + "\n",
                isError: false
            ))
        }

        let start = ContinuousClock.now
        reducer.processBatch(batch)
        let elapsed = ContinuousClock.now - start

        let stored = reducer.toolOutputStore.fullOutput(for: "t1")
        #expect(stored.count > 40_000, "Should have accumulated tool output")
        #expect(elapsed < .milliseconds(200),
            "processBatch(\(lineCount) tool output lines) took \(elapsed) — budget 200ms")
    }

    // MARK: - Session switching churn

    @MainActor
    @Test func rapidSessionSwitching20Times() {
        let reducer = TimelineReducer()

        // Pre-build 3 session traces
        let sessions = (0..<3).map { i in
            makeTraceEvents(count: 150, startIndex: i * 1000, prefix: "s\(i)")
        }

        let start = ContinuousClock.now
        for round in 0..<20 {
            let trace = sessions[round % 3]
            reducer.reset()
            reducer.loadSession(trace)
        }
        let elapsed = ContinuousClock.now - start

        #expect(reducer.items.count == 150)
        #expect(elapsed < .seconds(2),
            "20 session switches took \(elapsed) — budget 2s")
    }

    @MainActor
    @Test func sessionSwitchClearsMarkdownCache() {
        let reducer = TimelineReducer()

        // Load a large session so markdown cache gets populated
        let events = makeTraceEvents(count: 300, withMarkdown: true)
        reducer.loadSession(events)

        // Reset triggers cache purge when items > threshold
        let cacheStatsBefore = MarkdownSegmentCache.shared.snapshot()
        reducer.reset()
        let cacheStatsAfter = MarkdownSegmentCache.shared.snapshot()

        // After reset with 300 items (> markdownCachePurgeItemThreshold=250),
        // cache should have been purged
        #expect(cacheStatsAfter.entries <= cacheStatsBefore.entries,
            "Cache should not grow after reset purge")
    }

    // MARK: - Large timeline preservation

    @MainActor
    @Test func largeTimelinePreservesAllItems() {
        let reducer = TimelineReducer()

        for i in 0..<400 {
            reducer.appendUserMessage("msg-\(i)")
        }

        #expect(reducer.items.count == 400, "All 400 items preserved: got \(reducer.items.count)")

        guard case .userMessage(_, let first, _, _) = reducer.items.first else {
            Issue.record("Expected first item to be userMessage"); return
        }
        #expect(first == "msg-0")

        guard case .userMessage(_, let last, _, _) = reducer.items.last else {
            Issue.record("Expected last item to be userMessage"); return
        }
        #expect(last == "msg-399")
    }

    @MainActor
    @Test func allToolCallsPreservedInLargeSession() {
        let reducer = TimelineReducer()

        for i in 0..<120 {
            reducer.appendUserMessage("user-\(i)")
            reducer.process(.toolStart(sessionId: "s1", toolEventId: "tool-\(i)", tool: "bash", args: [:]))
            reducer.process(.toolOutput(sessionId: "s1", toolEventId: "tool-\(i)", output: "output-\(i)", isError: false))
            reducer.process(.toolEnd(sessionId: "s1", toolEventId: "tool-\(i)"))
        }

        let userCount = reducer.items.filter {
            if case .userMessage = $0 { return true }; return false
        }.count
        let toolCount = reducer.items.filter {
            if case .toolCall = $0 { return true }; return false
        }.count

        #expect(userCount == 120, "All user messages preserved")
        #expect(toolCount == 120, "All tool calls preserved")
    }

    @MainActor
    @Test func toolOutputPreservedInLargeSession() {
        let reducer = TimelineReducer()

        for i in 0..<300 {
            reducer.process(.agentStart(sessionId: "s1"))
            reducer.process(.toolStart(sessionId: "s1", toolEventId: "tool-\(i)", tool: "bash", args: [:]))
            reducer.process(.toolOutput(sessionId: "s1", toolEventId: "tool-\(i)",
                output: String(repeating: "x", count: 200), isError: false))
            reducer.process(.toolEnd(sessionId: "s1", toolEventId: "tool-\(i)"))
            reducer.process(.agentEnd(sessionId: "s1"))
        }

        // All 300 tool calls should be preserved
        let toolIDs = reducer.items.compactMap { item -> String? in
            guard case .toolCall(let id, _, _, _, _, _, _) = item else { return nil }
            return id
        }
        #expect(toolIDs.count == 300, "All 300 tool calls preserved: got \(toolIDs.count)")

        // All tool outputs should be stored
        for id in toolIDs {
            let output = reducer.toolOutputStore.fullOutput(for: id)
            #expect(!output.isEmpty, "Tool \(id) should have output stored")
        }
    }

    // MARK: - ToolOutputStore memory bounds

    @MainActor
    @Test func toolOutputStorePerItemCap() {
        let store = ToolOutputStore()
        let oversized = String(repeating: "x", count: ToolOutputStore.perItemCap + 1000)

        store.append(oversized, to: "t1")

        let stored = store.fullOutput(for: "t1")
        #expect(stored.utf8.count <= ToolOutputStore.perItemCap + ToolOutputStore.truncationMarker.utf8.count,
            "Per-item cap should be enforced: got \(stored.utf8.count) bytes")
        #expect(stored.contains("output truncated"))
    }

    @MainActor
    @Test func toolOutputStoreTotalCapEvicts() {
        let store = ToolOutputStore()
        let chunkSize = ToolOutputStore.totalCap / 8 // 2MB chunks
        let chunk = String(repeating: "y", count: chunkSize)

        for i in 0..<12 {
            store.append(chunk, to: "item-\(i)")
        }

        #expect(store.totalBytes <= ToolOutputStore.totalCap,
            "Total cap should be enforced: got \(store.totalBytes) bytes")

        // Oldest should have been evicted
        #expect(store.fullOutput(for: "item-0").isEmpty,
            "Oldest item should have been evicted")

        // Most recent should survive
        #expect(!store.fullOutput(for: "item-11").isEmpty,
            "Most recent item should survive eviction")
    }

    @MainActor
    @Test func toolOutputStoreIncrementalAppend() {
        let store = ToolOutputStore()

        let start = ContinuousClock.now
        for i in 0..<1000 {
            store.append("chunk-\(i)\n", to: "t1")
        }
        let elapsed = ContinuousClock.now - start

        #expect(elapsed < .milliseconds(200),
            "1000 incremental appends took \(elapsed) — budget 200ms")
    }

    // MARK: - MarkdownSegmentCache

    @Test func cacheEvictionUnderPressure() {
        let cache = MarkdownSegmentCache.shared
        cache.clearAll()
        defer { cache.clearAll() }

        let segment = FlatSegment.text(AttributedString("test"))

        let start = ContinuousClock.now
        for i in 0..<500 {
            let text = "entry-\(i)-" + String(repeating: "a", count: 1000)
            cache.set(text, segments: [segment])
        }
        let elapsed = ContinuousClock.now - start

        let stats = cache.snapshot()
        #expect(stats.entries <= 128, "Cache should be bounded: \(stats.entries) entries")
        #expect(stats.totalSourceBytes <= 1024 * 1024,
            "Cache should be byte-bounded: \(stats.totalSourceBytes) bytes")
        #expect(elapsed < .milliseconds(500),
            "500 cache sets with eviction took \(elapsed) — budget 500ms")
    }

    @Test func cacheLookupPerformance() {
        let cache = MarkdownSegmentCache.shared
        cache.clearAll()
        defer { cache.clearAll() }

        // Fill cache
        let segment = FlatSegment.text(AttributedString("cached"))
        var keys: [String] = []
        for i in 0..<100 {
            let text = "lookup-\(i)-" + String(repeating: "b", count: 500)
            cache.set(text, segments: [segment])
            keys.append(text)
        }

        // Lookup all keys 100 times
        let start = ContinuousClock.now
        for _ in 0..<100 {
            for key in keys {
                _ = cache.get(key)
            }
        }
        let elapsed = ContinuousClock.now - start

        #expect(elapsed < .milliseconds(200),
            "10K cache lookups took \(elapsed) — budget 200ms")
    }

    @Test func cacheSkipsOversized() {
        let cache = MarkdownSegmentCache.shared
        cache.clearAll()
        defer { cache.clearAll() }

        let huge = String(repeating: "z", count: 20_000) // > 16KB limit
        #expect(!cache.shouldCache(huge))
        cache.set(huge, segments: [.text(AttributedString("big"))])
        #expect(cache.get(huge) == nil)
    }

    // MARK: - Index integrity under mutation

    @MainActor
    @Test func indexRemainsCorrectAfterInsertRemoveChurn() {
        let reducer = TimelineReducer()

        // Load some history
        reducer.loadSession(makeTraceEvents(count: 50))

        // Interleave live events
        for i in 0..<30 {
            reducer.process(.agentStart(sessionId: "s1"))
            reducer.process(.textDelta(sessionId: "s1", delta: "live-\(i)"))
            reducer.process(.toolStart(sessionId: "s1", toolEventId: "lt-\(i)", tool: "bash", args: [:]))
            reducer.process(.toolOutput(sessionId: "s1", toolEventId: "lt-\(i)", output: "out-\(i)", isError: false))
            reducer.process(.toolEnd(sessionId: "s1", toolEventId: "lt-\(i)"))
            reducer.process(.agentEnd(sessionId: "s1"))
        }

        // Add more user messages
        for i in 0..<100 {
            reducer.appendUserMessage("churn-\(i)")
        }

        // All items preserved — 50 history + 30*(assistant+tool) + 100 user
        #expect(reducer.items.count > 200, "All items should be preserved: got \(reducer.items.count)")

        // Verify every item's ID is unique
        let ids = reducer.items.map(\.id)
        #expect(Set(ids).count == ids.count, "Duplicate IDs found after churn")
    }

    @MainActor
    @Test func removeItemMaintainsIndex() {
        let reducer = TimelineReducer()

        let id1 = reducer.appendUserMessage("first")
        _ = reducer.appendUserMessage("second")
        let id3 = reducer.appendUserMessage("third")

        reducer.removeItem(id: id1)

        #expect(reducer.items.count == 2)
        // After removing first, the remaining items should be findable
        guard case .userMessage(_, let text2, _, _) = reducer.items[0] else {
            Issue.record("Expected userMessage at [0]")
            return
        }
        #expect(text2 == "second")

        // Remove the third
        reducer.removeItem(id: id3)
        #expect(reducer.items.count == 1)
        guard case .userMessage(_, let text, _, _) = reducer.items[0] else {
            Issue.record("Expected userMessage at [0]")
            return
        }
        #expect(text == "second")
    }

    // MARK: - Memory warning during heavy load

    @MainActor
    @Test func memoryWarningDuringHeavyTimeline() {
        let reducer = TimelineReducer()

        // Build a heavy timeline with tool output
        for i in 0..<100 {
            reducer.process(.agentStart(sessionId: "s1"))
            reducer.process(.toolStart(sessionId: "s1", toolEventId: "t-\(i)", tool: "bash", args: [:]))
            reducer.process(.toolOutput(sessionId: "s1", toolEventId: "t-\(i)",
                output: String(repeating: "x", count: 1000), isError: false))
            reducer.process(.toolEnd(sessionId: "s1", toolEventId: "t-\(i)"))
            reducer.process(.agentEnd(sessionId: "s1"))
            reducer.expandedItemIDs.insert("t-\(i)")
        }

        let bytesBefore = reducer.toolOutputStore.totalBytes
        #expect(bytesBefore > 0)

        let stats = reducer.handleMemoryWarning()

        #expect(stats.toolOutputBytesCleared > 0)
        #expect(stats.expandedItemsCollapsed > 0)
        #expect(reducer.toolOutputStore.totalBytes == 0)
        #expect(reducer.expandedItemIDs.isEmpty)
        // Items themselves should still exist
        #expect(!reducer.items.isEmpty)
    }

    // MARK: - Combined streaming + history reload

    @MainActor
    @Test func streamingInterruptedByHistoryReload() {
        let reducer = TimelineReducer()

        // Start streaming
        reducer.process(.agentStart(sessionId: "s1"))
        for i in 0..<50 {
            reducer.process(.textDelta(sessionId: "s1", delta: "token-\(i) "))
        }
        #expect(reducer.streamingAssistantID != nil, "Should be in streaming mode")

        // Server sends updated history (reconnect scenario)
        let history = makeTraceEvents(count: 100)
        reducer.loadSession(history)

        // Streaming state should be reset
        #expect(reducer.streamingAssistantID == nil,
            "Streaming should be cleared after history load")
        #expect(reducer.items.count == 100)
    }

    @MainActor
    @Test func streamingThenProcessBatchThenReload() {
        let reducer = TimelineReducer()
        let history = makeTraceEvents(count: 80)
        reducer.loadSession(history)

        // Live streaming via processBatch
        reducer.processBatch([
            .agentStart(sessionId: "s1"),
            .textDelta(sessionId: "s1", delta: "live-1 "),
            .textDelta(sessionId: "s1", delta: "live-2 "),
        ])
        #expect(reducer.items.count == 81) // 80 history + 1 streaming

        // Server sends updated history with more events
        let extended = history + makeTraceEvents(count: 20, startIndex: 80)
        reducer.loadSession(extended)

        // Should have done a full rebuild (streaming broke incremental mode)
        #expect(!reducer._lastLoadWasIncrementalForTesting)
        #expect(reducer.items.count == 100)
    }

    // MARK: - Concurrent-like batch patterns

    @MainActor
    @Test func interleavedMultiToolBatch() {
        // Simulate multiple concurrent tool calls in a single batch
        let reducer = TimelineReducer()
        reducer.process(.agentStart(sessionId: "s1"))

        let batch: [AgentEvent] = [
            .toolStart(sessionId: "s1", toolEventId: "t1", tool: "read", args: ["path": "/a"]),
            .toolStart(sessionId: "s1", toolEventId: "t2", tool: "bash", args: ["command": "ls"]),
            .toolOutput(sessionId: "s1", toolEventId: "t1", output: "content-a", isError: false),
            .toolOutput(sessionId: "s1", toolEventId: "t2", output: "file1\n", isError: false),
            .toolOutput(sessionId: "s1", toolEventId: "t2", output: "file2\n", isError: false),
            .toolEnd(sessionId: "s1", toolEventId: "t1"),
            .toolEnd(sessionId: "s1", toolEventId: "t2"),
        ]

        reducer.processBatch(batch)

        let toolItems = reducer.items.filter {
            if case .toolCall = $0 { return true }
            return false
        }
        #expect(toolItems.count == 2)

        #expect(reducer.toolOutputStore.fullOutput(for: "t1") == "content-a")
        #expect(reducer.toolOutputStore.fullOutput(for: "t2") == "file1\nfile2\n")
    }

    // MARK: - Image extraction edge cases

    @MainActor
    @Test func loadSessionWithLargeBase64Images() {
        // Simulate trace events with embedded data URIs
        let fakeBase64 = String(repeating: "A", count: 10_000)
        let textWithImage = "Check this image: data:image/png;base64,\(fakeBase64) and this text"
        let events = [
            TraceEvent(id: "e1", type: .user, timestamp: "2025-01-01T00:00:00.000Z",
                       text: textWithImage, tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
        ]

        let start = ContinuousClock.now
        let reducer = TimelineReducer()
        reducer.loadSession(events)
        let elapsed = ContinuousClock.now - start

        #expect(reducer.items.count == 1)
        guard case .userMessage(_, let cleanText, let images, _) = reducer.items[0] else {
            Issue.record("Expected userMessage")
            return
        }
        #expect(!cleanText.contains("data:image"), "Data URI should be extracted from text")
        #expect(images.count == 1, "Should have extracted 1 image")
        #expect(elapsed < .milliseconds(200),
            "Image extraction from 10KB base64 took \(elapsed) — budget 200ms")
    }

    // MARK: - Thinking overflow at scale

    @MainActor
    @Test func thinkingOverflow10KChars() {
        let reducer = TimelineReducer()
        reducer.process(.agentStart(sessionId: "s1"))

        // Stream thinking in small chunks that overflow the preview cap
        let chunkSize = 50
        let totalChunks = 200 // 10K chars total

        let start = ContinuousClock.now
        var batch: [AgentEvent] = []
        for i in 0..<totalChunks {
            batch.append(.thinkingDelta(sessionId: "s1",
                delta: "chunk\(i)-" + String(repeating: "t", count: chunkSize - 8) + " "))
        }
        reducer.processBatch(batch)
        let elapsed = ContinuousClock.now - start

        #expect(reducer.items.count == 1)
        guard case .thinking(_, let preview, let hasMore, _) = reducer.items[0] else {
            Issue.record("Expected thinking item")
            return
        }
        #expect(hasMore)
        #expect(preview.count > 9000, "Full thinking should stay inline: got \(preview.count)")
        #expect(elapsed < .milliseconds(200),
            "10K thinking overflow took \(elapsed) — budget 200ms")
    }

    // MARK: - Helpers

    /// Generate simple user+assistant trace event pairs.
    private func makeTraceEvents(
        count: Int,
        startIndex: Int = 0,
        prefix: String = "e",
        withMarkdown: Bool = false
    ) -> [TraceEvent] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        var events: [TraceEvent] = []
        events.reserveCapacity(count)

        for i in startIndex..<(startIndex + count) {
            let ts = formatter.string(from: base.addingTimeInterval(Double(i)))
            let isAssistant = i % 2 == 1
            let text: String
            if isAssistant {
                if withMarkdown {
                    text = """
                    ### Response \(i)
                    - Point one about **important** topic
                    - Point two with `code` example
                    ```swift
                    let x = \(i)
                    print("hello \\(x)")
                    ```
                    Final paragraph with *emphasis*.
                    """
                } else {
                    text = "Response \(i): analysis of item \(i) with details."
                }
            } else {
                text = "Query \(i): investigate item \(i)"
            }

            events.append(TraceEvent(
                id: "\(prefix)\(i)",
                type: isAssistant ? .assistant : .user,
                timestamp: ts,
                text: text,
                tool: nil, args: nil, output: nil,
                toolCallId: nil, toolName: nil, isError: nil, thinking: nil
            ))
        }

        return events
    }

    /// Generate trace events with mixed types (user, assistant, tool, thinking, system).
    private func makeMixedTraceEvents(count: Int) -> [TraceEvent] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        var events: [TraceEvent] = []
        events.reserveCapacity(count)

        for i in 0..<count {
            let ts = formatter.string(from: base.addingTimeInterval(Double(i)))

            switch i % 5 {
            case 0:
                events.append(TraceEvent(
                    id: "m\(i)", type: .user, timestamp: ts,
                    text: "User query \(i)", tool: nil, args: nil, output: nil,
                    toolCallId: nil, toolName: nil, isError: nil, thinking: nil
                ))
            case 1:
                events.append(TraceEvent(
                    id: "m\(i)", type: .assistant, timestamp: ts,
                    text: "Assistant response \(i) with detailed explanation.",
                    tool: nil, args: nil, output: nil,
                    toolCallId: nil, toolName: nil, isError: nil, thinking: nil
                ))
            case 2:
                events.append(TraceEvent(
                    id: "m\(i)", type: .toolCall, timestamp: ts,
                    text: nil, tool: "bash",
                    args: ["command": .string("echo \(i)")],
                    output: nil, toolCallId: nil, toolName: nil, isError: nil, thinking: nil
                ))
            case 3:
                events.append(TraceEvent(
                    id: "m\(i)", type: .toolResult, timestamp: ts,
                    text: nil, tool: nil, args: nil,
                    output: "result-\(i)\n" + String(repeating: "x", count: 100),
                    toolCallId: "m\(i-1)", toolName: "bash", isError: false, thinking: nil
                ))
            case 4:
                events.append(TraceEvent(
                    id: "m\(i)", type: .thinking, timestamp: ts,
                    text: nil, tool: nil, args: nil, output: nil,
                    toolCallId: nil, toolName: nil, isError: nil,
                    thinking: "Thinking about item \(i)..."
                ))
            default:
                break
            }
        }

        return events
    }
}
