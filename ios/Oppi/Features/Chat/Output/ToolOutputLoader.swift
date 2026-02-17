import Foundation

/// Manages lazy loading of full tool output for expanded tool rows.
///
/// Handles fetch, retry with exponential backoff, cancellation on cell reuse,
/// and stale-session guards. Extracted from `ChatTimelineCollectionView.Coordinator`.
@MainActor
final class ToolOutputLoader {

    // MARK: - Configuration

    static let retryMaxAttempts = 6
    static let retryBaseDelay: TimeInterval = 0.45
    static let retryMaxDelay: TimeInterval = 2.0
    static let retryBackoffFactor: Double = 1.6

    // MARK: - Types

    enum CompletionDisposition: Equatable {
        case apply
        case canceled
        case staleSession
        case missingItem
        case emptyOutput
    }

    /// Closure that fetches full tool output from the server.
    typealias FetchOutput = (_ sessionId: String, _ toolCallId: String) async throws -> String

    /// Closure called when output is successfully fetched and should be applied.
    typealias OnOutputApplied = (_ itemID: String, _ output: String) -> Void

    // MARK: - State

    private(set) var loadingIDs: Set<String> = []
    private var tasks: [String: Task<Void, Never>] = [:]
    private var pendingRetryWork: [String: DispatchWorkItem] = [:]

    // Test counters
    private(set) var appliedCount = 0
    private(set) var staleDiscardCount = 0
    private(set) var canceledCount = 0

    var loadTaskCount: Int { tasks.count }

    func isLoading(_ itemID: String) -> Bool {
        loadingIDs.contains(itemID) || tasks[itemID] != nil
    }

    // MARK: - Load

    /// Start loading full tool output for an item.
    ///
    /// - Parameters:
    ///   - itemID: The tool call item ID (also used as toolCallId for the API).
    ///   - tool: Normalized tool name (used for retry eligibility — only `read` retries).
    ///   - sessionId: Current active session ID.
    ///   - fetch: Async closure to fetch the output.
    ///   - isItemVisible: Closure to check if the item still exists in the current snapshot.
    ///   - isExpanded: Closure to check if the item is still expanded (for retry gating).
    ///   - onApplied: Called on success with the fetched output.
    func loadIfNeeded(
        itemID: String,
        tool: String,
        sessionId: String,
        attempt: Int = 0,
        fetch: @escaping FetchOutput,
        isItemVisible: @escaping () -> Bool,
        isExpanded: @escaping () -> Bool,
        onApplied: @escaping OnOutputApplied
    ) {
        guard !isLoading(itemID) else { return }

        let task = Task { [weak self] in
            let output: String
            do {
                output = try await fetch(sessionId, itemID)
            } catch {
                self?.finishLoad(itemID: itemID)
                return
            }

            guard let self else { return }
            defer { self.finishLoad(itemID: itemID) }

            let disposition = Self.completionDisposition(
                output: output,
                isTaskCancelled: Task.isCancelled,
                isItemVisible: isItemVisible(),
                isCurrentSession: true // caller ensures sessionId matches
            )

            guard disposition == .apply else {
                switch disposition {
                case .staleSession, .missingItem, .emptyOutput:
                    self.staleDiscardCount += 1
                case .canceled, .apply:
                    break
                }

                if disposition == .emptyOutput {
                    self.scheduleRetryIfNeeded(
                        itemID: itemID,
                        tool: tool,
                        sessionId: sessionId,
                        attempt: attempt,
                        fetch: fetch,
                        isItemVisible: isItemVisible,
                        isExpanded: isExpanded,
                        onApplied: onApplied
                    )
                }
                return
            }

            self.cancelRetryWork(for: itemID)
            self.appliedCount += 1
            onApplied(itemID, output)
        }

        startLoad(itemID: itemID, task: task)
    }

    // MARK: - Retry

    private func scheduleRetryIfNeeded(
        itemID: String,
        tool: String,
        sessionId: String,
        attempt: Int,
        fetch: @escaping FetchOutput,
        isItemVisible: @escaping () -> Bool,
        isExpanded: @escaping () -> Bool,
        onApplied: @escaping OnOutputApplied
    ) {
        guard ToolCallFormatting.isReadTool(tool) else { return }
        guard attempt < Self.retryMaxAttempts else { return }
        guard isExpanded() else { return }

        cancelRetryWork(for: itemID)

        let nextAttempt = attempt + 1
        let delay = min(
            Self.retryMaxDelay,
            Self.retryBaseDelay * pow(Self.retryBackoffFactor, Double(attempt))
        )

        let retryWork = DispatchWorkItem { [weak self] in
            guard let self,
                  isItemVisible(),
                  isExpanded() else {
                return
            }

            self.loadIfNeeded(
                itemID: itemID,
                tool: tool,
                sessionId: sessionId,
                attempt: nextAttempt,
                fetch: fetch,
                isItemVisible: isItemVisible,
                isExpanded: isExpanded,
                onApplied: onApplied
            )
        }

        pendingRetryWork[itemID] = retryWork
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: retryWork)
    }

    // MARK: - Cancellation

    func cancelLoad(for itemID: String) {
        if let task = tasks.removeValue(forKey: itemID) {
            task.cancel()
            canceledCount += 1
        }
        loadingIDs.remove(itemID)
        cancelRetryWork(for: itemID)
    }

    func cancelLoads(for itemIDs: Set<String>) {
        guard !itemIDs.isEmpty else { return }
        for itemID in itemIDs {
            cancelLoad(for: itemID)
        }
    }

    func cancelAll() {
        let count = tasks.count
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        loadingIDs.removeAll()
        canceledCount += count
        cancelAllRetryWork()
    }

    // MARK: - Disposition (pure, testable)

    static func completionDisposition(
        output: String,
        isTaskCancelled: Bool,
        isItemVisible: Bool,
        isCurrentSession: Bool
    ) -> CompletionDisposition {
        if isTaskCancelled { return .canceled }
        if !isCurrentSession { return .staleSession }
        if !isItemVisible { return .missingItem }
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .emptyOutput }
        return .apply
    }

    // MARK: - Private

    private func startLoad(itemID: String, task: Task<Void, Never>) {
        loadingIDs.insert(itemID)
        tasks[itemID] = task
    }

    private func finishLoad(itemID: String) {
        loadingIDs.remove(itemID)
        tasks.removeValue(forKey: itemID)
    }

    private func cancelRetryWork(for itemID: String) {
        pendingRetryWork.removeValue(forKey: itemID)?.cancel()
    }

    private func cancelAllRetryWork() {
        for (_, work) in pendingRetryWork { work.cancel() }
        pendingRetryWork.removeAll(keepingCapacity: false)
    }
}
