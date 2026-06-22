import Testing
@testable import Oppi

@Suite("Full-screen markdown async rendering")
struct FullScreenMarkdownAsyncRenderTests {
    @MainActor
    @Test("cancelling the parent render task cancels the detached build")
    func cancellingParentRenderTaskCancelsDetachedBuild() async {
        let probe = DetachedCancellationProbe()

        let parent = Task { @MainActor in
            let _: Void? = await withCancellableDetachedTask(priority: .userInitiated) {
                await probe.markStarted()
                for _ in 0..<25 where !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                if Task.isCancelled {
                    await probe.markCancelled()
                }
                return nil
            }
        }

        await probe.waitUntilStarted()
        parent.cancel()
        _ = await parent.value

        #expect(await probe.wasCancelled)
    }
}

private actor DetachedCancellationProbe {
    private var started = false
    private var cancelled = false
    private var startedContinuations: [CheckedContinuation<Void, Never>] = []

    var wasCancelled: Bool { cancelled }

    func markStarted() {
        started = true
        let continuations = startedContinuations
        startedContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func markCancelled() {
        cancelled = true
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startedContinuations.append(continuation)
        }
    }
}
