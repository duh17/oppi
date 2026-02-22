import Foundation
import Testing
@testable import Oppi

@MainActor
@Suite("ChatTimelineToolOutputLoader")
struct ChatTimelineToolOutputLoaderTests {

    @Test func completionDispositionMapping() {
        #expect(
            ChatTimelineToolOutputLoader.completionDisposition(
                output: "ok",
                isTaskCancelled: false,
                activeSessionID: "session-a",
                currentSessionID: "session-a",
                itemExists: true
            ) == .apply
        )

        #expect(
            ChatTimelineToolOutputLoader.completionDisposition(
                output: "ok",
                isTaskCancelled: true,
                activeSessionID: "session-a",
                currentSessionID: "session-a",
                itemExists: true
            ) == .canceled
        )

        #expect(
            ChatTimelineToolOutputLoader.completionDisposition(
                output: "ok",
                isTaskCancelled: false,
                activeSessionID: "session-a",
                currentSessionID: "session-b",
                itemExists: true
            ) == .staleSession
        )

        #expect(
            ChatTimelineToolOutputLoader.completionDisposition(
                output: "ok",
                isTaskCancelled: false,
                activeSessionID: "session-a",
                currentSessionID: "session-a",
                itemExists: false
            ) == .missingItem
        )

        #expect(
            ChatTimelineToolOutputLoader.completionDisposition(
                output: "",
                isTaskCancelled: false,
                activeSessionID: "session-a",
                currentSessionID: "session-a",
                itemExists: true
            ) == .emptyOutput
        )
    }

    @Test func loadAppliesOutputAndReconfigures() async {
        let loader = ChatTimelineToolOutputLoader()
        var appliedOutput: String?
        var reconfigureCount = 0

        let request = makeRequest(
            tool: "bash",
            fetchToolOutput: { _, _ in "full output" },
            applyOutput: { output in
                appliedOutput = output
            },
            reconfigureItem: {
                reconfigureCount += 1
            }
        )

        loader.loadIfNeeded(request)

        #expect(await waitForCondition(timeoutMs: 1_000) {
            await MainActor.run {
                appliedOutput == "full output"
                    && reconfigureCount == 1
                    && loader.taskCountForTesting == 0
            }
        })
        #expect(loader.appliedCountForTesting == 1)
        #expect(loader.staleDiscardCountForTesting == 0)
    }

    @Test func staleSessionDoesNotApplyOutput() async {
        let loader = ChatTimelineToolOutputLoader()
        var applied = false

        let request = makeRequest(
            activeSessionID: "session-a",
            currentSessionID: { "session-b" },
            fetchToolOutput: { _, _ in "should-not-apply" },
            applyOutput: { _ in
                applied = true
            }
        )

        loader.loadIfNeeded(request)

        #expect(await waitForCondition(timeoutMs: 1_000) {
            await MainActor.run { loader.taskCountForTesting == 0 }
        })

        #expect(!applied)
        #expect(loader.appliedCountForTesting == 0)
        #expect(loader.staleDiscardCountForTesting == 1)
    }

    @Test func readToolEmptyOutputRetriesAndAppliesSecondAttempt() async {
        actor Attempts {
            var value = 0

            func next() -> Int {
                value += 1
                return value
            }

            func current() -> Int {
                value
            }
        }

        let loader = ChatTimelineToolOutputLoader()
        let attempts = Attempts()
        var appliedOutput: String?

        let request = makeRequest(
            tool: "read",
            fetchToolOutput: { _, _ in
                let attempt = await attempts.next()
                if attempt == 1 {
                    return ""
                }
                return "retry output"
            },
            applyOutput: { output in
                appliedOutput = output
            }
        )

        loader.loadIfNeeded(request)

        #expect(await waitForCondition(timeoutMs: 3_500) {
            await MainActor.run { appliedOutput == "retry output" }
        })

        #expect(await attempts.current() >= 2)
        #expect(loader.appliedCountForTesting == 1)
        #expect(loader.staleDiscardCountForTesting >= 1)
    }

    @Test func nonReadEmptyOutputDoesNotRetry() async {
        actor Attempts {
            var value = 0
            func bump() {
                value += 1
            }

            func current() -> Int {
                value
            }
        }

        let loader = ChatTimelineToolOutputLoader()
        let attempts = Attempts()

        let request = makeRequest(
            tool: "bash",
            fetchToolOutput: { _, _ in
                await attempts.bump()
                return ""
            }
        )

        loader.loadIfNeeded(request)

        #expect(await waitForCondition(timeoutMs: 1_000) {
            await MainActor.run { loader.taskCountForTesting == 0 }
        })

        try? await Task.sleep(for: .milliseconds(700))

        #expect(await attempts.current() == 1)
        #expect(loader.appliedCountForTesting == 0)
        #expect(loader.staleDiscardCountForTesting == 1)
    }

    @Test func cancelLoadTasksCancelsInFlightRequest() async {
        actor Probe {
            var started = 0
            var canceled = 0

            func markStarted() {
                started += 1
            }

            func markCanceled() {
                canceled += 1
            }

            func snapshot() -> (started: Int, canceled: Int) {
                (started, canceled)
            }
        }

        let loader = ChatTimelineToolOutputLoader()
        let probe = Probe()

        let request = makeRequest(
            itemID: "tool-cancel",
            tool: "bash",
            fetchToolOutput: { _, _ in
                await probe.markStarted()
                do {
                    try await Task.sleep(for: .seconds(5))
                    return "late"
                } catch is CancellationError {
                    await probe.markCanceled()
                    throw CancellationError()
                }
            }
        )

        loader.loadIfNeeded(request)

        #expect(await waitForCondition(timeoutMs: 600) {
            await MainActor.run {
                loader.isLoading("tool-cancel")
                    && loader.taskCountForTesting == 1
            }
        })

        loader.cancelLoadTasks(for: ["tool-cancel"])

        #expect(await waitForCondition(timeoutMs: 1_000) {
            let counts = await probe.snapshot()
            let done = await MainActor.run {
                loader.taskCountForTesting == 0
                    && !loader.isLoading("tool-cancel")
            }
            return counts.canceled == 1 && done
        })

        #expect(loader.canceledCountForTesting >= 1)
    }
}

private func makeRequest(
    itemID: String = "tool-1",
    tool: String = "read",
    attempt: Int = 0,
    hasExistingOutput: @escaping () -> Bool = { false },
    activeSessionID: String = "session-a",
    currentSessionID: @escaping () -> String = { "session-a" },
    itemExists: @escaping () -> Bool = { true },
    isItemExpanded: @escaping () -> Bool = { true },
    fetchToolOutput: @escaping ChatTimelineToolOutputLoader.FetchToolOutput = { _, _ in "output" },
    applyOutput: @escaping (_ output: String) -> Void = { _ in },
    reconfigureItem: @escaping () -> Void = {}
) -> ChatTimelineToolOutputLoader.LoadRequest {
    ChatTimelineToolOutputLoader.LoadRequest(
        itemID: itemID,
        tool: tool,
        outputByteCount: 0,
        attempt: attempt,
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

private func waitForCondition(
    timeoutMs: Int = 1_000,
    pollMs: Int = 20,
    _ predicate: @Sendable () async -> Bool
) async -> Bool {
    let attempts = max(1, timeoutMs / max(1, pollMs))
    for _ in 0..<attempts {
        if await predicate() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(pollMs))
    }
    return await predicate()
}
