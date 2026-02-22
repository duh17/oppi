import Foundation

/// Isolated collaborator for loading expanded tool output + retry scheduling.
///
/// Keeps task/retry bookkeeping out of `ChatTimelineCollectionHost.Controller`
/// while preserving the same externally observed behavior.
@MainActor
final class ExpandedToolOutputLoader {
    typealias FetchToolOutput = (_ sessionId: String, _ toolCallId: String) async throws -> String

    struct LoadRequest {
        let itemID: String
        let tool: String
        let outputByteCount: Int
        let attempt: Int
        let hasExistingOutput: () -> Bool
        let activeSessionID: String
        let currentSessionID: () -> String
        let itemExists: () -> Bool
        let isItemExpanded: () -> Bool
        let fetchToolOutput: FetchToolOutput
        let applyOutput: (_ output: String) -> Void
        let reconfigureItem: () -> Void

        func retrying(attempt nextAttempt: Int) -> Self {
            Self(
                itemID: itemID,
                tool: tool,
                outputByteCount: outputByteCount,
                attempt: nextAttempt,
                hasExistingOutput: hasExistingOutput,
                activeSessionID: activeSessionID,
                currentSessionID: currentSessionID,
                itemExists: itemExists,
                isItemExpanded: isItemExpanded,
                fetchToolOutput: fetchToolOutput,
                applyOutput: applyOutput,
                reconfigureItem: reconfigureItem
            )
        }
    }

    enum CompletionDisposition: Equatable {
        case apply
        case canceled
        case staleSession
        case missingItem
        case emptyOutput
    }

    var fetchOverrideForTesting: FetchToolOutput?

    private(set) var canceledCountForTesting = 0
    private(set) var staleDiscardCountForTesting = 0
    private(set) var appliedCountForTesting = 0

    var taskCountForTesting: Int {
        loadState.taskCount
    }

    var loadingIDsForTesting: Set<String> {
        loadState.loadingIDs
    }

    private var loadState = LoadState()
    private var pendingRetryWorkByID: [String: DispatchWorkItem] = [:]

    private static let retryMaxAttempts = 6
    private static let retryBaseDelay: TimeInterval = 0.45
    private static let retryMaxDelay: TimeInterval = 2.0

    func isLoading(_ itemID: String) -> Bool {
        loadState.isLoading(itemID)
    }

    func loadIfNeeded(_ request: LoadRequest) {
        guard !request.hasExistingOutput(),
              !loadState.isLoading(request.itemID) else {
            return
        }

        let task = Task { [weak self, request] in
            let output: String
            do {
                output = try await request.fetchToolOutput(request.activeSessionID, request.itemID)
            } catch {
                await MainActor.run {
                    self?.loadState.finish(itemID: request.itemID)
                }
                return
            }

            await MainActor.run {
                guard let self else { return }
                defer {
                    self.loadState.finish(itemID: request.itemID)
                }

                let disposition = Self.completionDisposition(
                    output: output,
                    isTaskCancelled: Task.isCancelled,
                    activeSessionID: request.activeSessionID,
                    currentSessionID: request.currentSessionID(),
                    itemExists: request.itemExists()
                )

                guard disposition == .apply else {
                    switch disposition {
                    case .staleSession, .missingItem, .emptyOutput:
                        self.staleDiscardCountForTesting += 1
                    case .canceled, .apply:
                        break
                    }

                    if disposition == .emptyOutput {
                        self.scheduleRetryIfNeeded(for: request)
                    }

                    return
                }

                self.cancelRetryWork(for: request.itemID)
                request.applyOutput(output)
                self.appliedCountForTesting += 1
                request.reconfigureItem()
            }
        }

        loadState.start(itemID: request.itemID, task: task)
    }

    func cancelRetryWork(for itemID: String) {
        pendingRetryWorkByID.removeValue(forKey: itemID)?.cancel()
    }

    func cancelAllRetryWork() {
        for work in pendingRetryWorkByID.values {
            work.cancel()
        }
        pendingRetryWorkByID.removeAll(keepingCapacity: false)
    }

    func cancelLoadTasks(for itemIDs: Set<String>) {
        let canceled = loadState.cancel(for: itemIDs)
        canceledCountForTesting += canceled

        for itemID in itemIDs {
            cancelRetryWork(for: itemID)
        }
    }

    func cancelAllWork() {
        let canceled = loadState.cancelAll()
        canceledCountForTesting += canceled
        cancelAllRetryWork()
    }

    static func completionDisposition(
        output: String,
        isTaskCancelled: Bool,
        activeSessionID: String,
        currentSessionID: String,
        itemExists: Bool
    ) -> CompletionDisposition {
        if isTaskCancelled {
            return .canceled
        }
        if activeSessionID != currentSessionID {
            return .staleSession
        }
        if !itemExists {
            return .missingItem
        }
        if output.isEmpty {
            return .emptyOutput
        }
        return .apply
    }

    private func scheduleRetryIfNeeded(for request: LoadRequest) {
        guard ToolCallFormatting.isReadTool(request.tool) else { return }
        guard request.attempt < Self.retryMaxAttempts else { return }
        guard request.isItemExpanded() else { return }

        cancelRetryWork(for: request.itemID)

        let nextAttempt = request.attempt + 1
        let delay = min(
            Self.retryMaxDelay,
            Self.retryBaseDelay * pow(1.6, Double(request.attempt))
        )

        let retryRequest = request.retrying(attempt: nextAttempt)
        let retryWork = DispatchWorkItem { [weak self] in
            guard let self,
                  retryRequest.isItemExpanded(),
                  retryRequest.itemExists() else {
                return
            }

            self.loadIfNeeded(retryRequest)
        }

        pendingRetryWorkByID[request.itemID] = retryWork
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: retryWork)
    }
}

typealias ChatTimelineToolOutputLoader = ExpandedToolOutputLoader

private struct LoadState {
    var loadingIDs: Set<String> = []
    var tasks: [String: Task<Void, Never>] = [:]

    var taskCount: Int {
        tasks.count
    }

    func isLoading(_ itemID: String) -> Bool {
        loadingIDs.contains(itemID) || tasks[itemID] != nil
    }

    mutating func start(itemID: String, task: Task<Void, Never>) {
        loadingIDs.insert(itemID)
        tasks[itemID] = task
    }

    mutating func finish(itemID: String) {
        loadingIDs.remove(itemID)
        tasks.removeValue(forKey: itemID)
    }

    mutating func cancel(for itemIDs: Set<String>) -> Int {
        guard !itemIDs.isEmpty else { return 0 }

        var canceled = 0
        for itemID in itemIDs {
            if let task = tasks.removeValue(forKey: itemID) {
                task.cancel()
                canceled += 1
            }
            loadingIDs.remove(itemID)
        }

        return canceled
    }

    mutating func cancelAll() -> Int {
        let canceled = tasks.count
        for task in tasks.values {
            task.cancel()
        }
        tasks.removeAll()
        loadingIDs.removeAll()
        return canceled
    }
}
