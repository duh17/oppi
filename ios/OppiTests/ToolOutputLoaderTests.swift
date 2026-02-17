import Foundation
import Testing

@testable import Oppi

@MainActor
@Suite("ToolOutputLoader")
struct ToolOutputLoaderTests {

    // MARK: - Disposition Tests

    @Test("apply when output is non-empty and item is visible")
    func dispositionApply() {
        let result = ToolOutputLoader.completionDisposition(
            output: "hello world",
            isTaskCancelled: false,
            isItemVisible: true,
            isCurrentSession: true
        )
        #expect(result == .apply)
    }

    @Test("canceled when task is cancelled")
    func dispositionCanceled() {
        let result = ToolOutputLoader.completionDisposition(
            output: "hello",
            isTaskCancelled: true,
            isItemVisible: true,
            isCurrentSession: true
        )
        #expect(result == .canceled)
    }

    @Test("staleSession when session changed")
    func dispositionStaleSession() {
        let result = ToolOutputLoader.completionDisposition(
            output: "hello",
            isTaskCancelled: false,
            isItemVisible: true,
            isCurrentSession: false
        )
        #expect(result == .staleSession)
    }

    @Test("missingItem when item no longer visible")
    func dispositionMissingItem() {
        let result = ToolOutputLoader.completionDisposition(
            output: "hello",
            isTaskCancelled: false,
            isItemVisible: false,
            isCurrentSession: true
        )
        #expect(result == .missingItem)
    }

    @Test("emptyOutput when output is whitespace-only")
    func dispositionEmptyOutput() {
        let result = ToolOutputLoader.completionDisposition(
            output: "   \n  ",
            isTaskCancelled: false,
            isItemVisible: true,
            isCurrentSession: true
        )
        #expect(result == .emptyOutput)
    }

    @Test("emptyOutput when output is empty string")
    func dispositionEmptyString() {
        let result = ToolOutputLoader.completionDisposition(
            output: "",
            isTaskCancelled: false,
            isItemVisible: true,
            isCurrentSession: true
        )
        #expect(result == .emptyOutput)
    }

    @Test("canceled takes priority over staleSession")
    func dispositionPriority() {
        let result = ToolOutputLoader.completionDisposition(
            output: "hello",
            isTaskCancelled: true,
            isItemVisible: true,
            isCurrentSession: false
        )
        #expect(result == .canceled)
    }

    // MARK: - Load State Tests

    @Test("isLoading is false initially")
    func initialState() {
        let loader = ToolOutputLoader()
        #expect(!loader.isLoading("item-1"))
        #expect(loader.loadTaskCount == 0)
    }

    @Test("loadIfNeeded starts a load and calls onApplied")
    func loadSuccess() async throws {
        let loader = ToolOutputLoader()
        var appliedItems: [(String, String)] = []

        loader.loadIfNeeded(
            itemID: "tool-1",
            tool: "read",
            sessionId: "session-1",
            fetch: { _, _ in "file contents" },
            isItemVisible: { true },
            isExpanded: { true },
            onApplied: { id, output in appliedItems.append((id, output)) }
        )

        #expect(loader.isLoading("tool-1"))

        // Let the task complete
        try await Task.sleep(for: .milliseconds(50))

        #expect(!loader.isLoading("tool-1"))
        #expect(appliedItems.count == 1)
        #expect(appliedItems[0].0 == "tool-1")
        #expect(appliedItems[0].1 == "file contents")
        #expect(loader.appliedCount == 1)
    }

    @Test("loadIfNeeded skips if already loading")
    func loadDedup() async throws {
        let loader = ToolOutputLoader()
        var fetchCount = 0

        let fetch: ToolOutputLoader.FetchOutput = { _, _ in
            fetchCount += 1
            try await Task.sleep(for: .milliseconds(100))
            return "output"
        }

        loader.loadIfNeeded(
            itemID: "tool-1", tool: "read", sessionId: "s1",
            fetch: fetch,
            isItemVisible: { true }, isExpanded: { true },
            onApplied: { _, _ in }
        )

        // Second call should be a no-op
        loader.loadIfNeeded(
            itemID: "tool-1", tool: "read", sessionId: "s1",
            fetch: fetch,
            isItemVisible: { true }, isExpanded: { true },
            onApplied: { _, _ in }
        )

        #expect(loader.loadTaskCount == 1)
        try await Task.sleep(for: .milliseconds(200))
        #expect(fetchCount == 1)
    }

    @Test("cancelLoad stops in-flight load")
    func cancelLoad() async throws {
        let loader = ToolOutputLoader()
        var applied = false

        loader.loadIfNeeded(
            itemID: "tool-1", tool: "read", sessionId: "s1",
            fetch: { _, _ in
                try await Task.sleep(for: .seconds(10))
                return "output"
            },
            isItemVisible: { true }, isExpanded: { true },
            onApplied: { _, _ in applied = true }
        )

        #expect(loader.isLoading("tool-1"))
        loader.cancelLoad(for: "tool-1")
        #expect(!loader.isLoading("tool-1"))
        #expect(loader.canceledCount == 1)

        try await Task.sleep(for: .milliseconds(50))
        #expect(!applied)
    }

    @Test("cancelAll clears all loads")
    func cancelAll() {
        let loader = ToolOutputLoader()

        for i in 0..<3 {
            loader.loadIfNeeded(
                itemID: "tool-\(i)", tool: "read", sessionId: "s1",
                fetch: { _, _ in
                    try await Task.sleep(for: .seconds(10))
                    return ""
                },
                isItemVisible: { true }, isExpanded: { true },
                onApplied: { _, _ in }
            )
        }

        #expect(loader.loadTaskCount == 3)
        loader.cancelAll()
        #expect(loader.loadTaskCount == 0)
        #expect(loader.canceledCount == 3)
    }

    @Test("empty output increments staleDiscardCount")
    func emptyOutputDiscarded() async throws {
        let loader = ToolOutputLoader()

        loader.loadIfNeeded(
            itemID: "tool-1", tool: "bash", sessionId: "s1",
            fetch: { _, _ in "" },
            isItemVisible: { true }, isExpanded: { true },
            onApplied: { _, _ in }
        )

        try await Task.sleep(for: .milliseconds(50))
        #expect(loader.staleDiscardCount == 1)
        #expect(loader.appliedCount == 0)
    }

    @Test("fetch error finishes load without crash")
    func fetchError() async throws {
        let loader = ToolOutputLoader()
        var applied = false

        loader.loadIfNeeded(
            itemID: "tool-1", tool: "read", sessionId: "s1",
            fetch: { _, _ in throw NSError(domain: "test", code: -1) },
            isItemVisible: { true }, isExpanded: { true },
            onApplied: { _, _ in applied = true }
        )

        try await Task.sleep(for: .milliseconds(50))
        #expect(!loader.isLoading("tool-1"))
        #expect(!applied)
        #expect(loader.appliedCount == 0)
    }

    // MARK: - Retry Tests

    @Test("read tool retries on empty output")
    func readToolRetries() async throws {
        let loader = ToolOutputLoader()
        var fetchCount = 0
        var appliedOutput: String?

        let fetch: ToolOutputLoader.FetchOutput = { _, _ in
            fetchCount += 1
            if fetchCount <= 2 {
                return ""  // empty — triggers retry
            }
            return "final output"
        }

        loader.loadIfNeeded(
            itemID: "tool-1", tool: "read", sessionId: "s1",
            fetch: fetch,
            isItemVisible: { true }, isExpanded: { true },
            onApplied: { _, output in appliedOutput = output }
        )

        // Wait for initial + 2 retries (each retry has exponential delay)
        // Base delay is 0.45s, so total is roughly 0.45 + 0.72 + fetch time
        try await Task.sleep(for: .seconds(3))

        #expect(fetchCount == 3)
        #expect(appliedOutput == "final output")
        #expect(loader.appliedCount == 1)
    }

    @Test("non-read tools do not retry on empty output")
    func bashNoRetry() async throws {
        let loader = ToolOutputLoader()
        var fetchCount = 0

        loader.loadIfNeeded(
            itemID: "tool-1", tool: "bash", sessionId: "s1",
            fetch: { _, _ in
                fetchCount += 1
                return ""
            },
            isItemVisible: { true }, isExpanded: { true },
            onApplied: { _, _ in }
        )

        try await Task.sleep(for: .seconds(1))
        #expect(fetchCount == 1) // no retry
    }

    @Test("retry stops when item is no longer expanded")
    func retryStopsWhenCollapsed() async throws {
        let loader = ToolOutputLoader()
        var fetchCount = 0
        var expanded = true

        loader.loadIfNeeded(
            itemID: "tool-1", tool: "read", sessionId: "s1",
            fetch: { _, _ in
                fetchCount += 1
                return ""
            },
            isItemVisible: { true },
            isExpanded: { expanded },
            onApplied: { _, _ in }
        )

        try await Task.sleep(for: .milliseconds(100))
        expanded = false  // collapse before retry fires

        try await Task.sleep(for: .seconds(2))
        #expect(fetchCount == 1) // no retry because collapsed
    }

    // MARK: - Backoff Calculation

    @Test("retry delay respects max delay cap")
    func retryDelayCalculation() {
        // Base: 0.45, factor: 1.6
        // attempt 0: 0.45 * 1.6^0 = 0.45
        // attempt 1: 0.45 * 1.6^1 = 0.72
        // attempt 5: 0.45 * 1.6^5 = 4.72 → capped at 2.0
        let base = ToolOutputLoader.retryBaseDelay
        let factor = ToolOutputLoader.retryBackoffFactor
        let maxDelay = ToolOutputLoader.retryMaxDelay

        let delay5 = min(maxDelay, base * Foundation.pow(factor, 5.0))
        #expect(delay5 == maxDelay)

        let delay0 = min(maxDelay, base * Foundation.pow(factor, 0.0))
        #expect(delay0 == base)
    }
}
