import Foundation
@testable import Oppi
import Testing

/// `RefreshCoalescer`, the one-read-at-a-time rule `ServerConnection` refreshes `/server/info`
/// with: the server's switch here is a Bool, and one read can be held at a gate.
@Suite("Refresh coalescer")
@MainActor
struct RefreshCoalescerTests {
    /// A server whose answer is one switch, and an app that refreshes from it. `holdNext` stalls
    /// the next read at `gate`; that read answers what the switch was when it came.
    @MainActor
    private final class Harness {
        let coalescer = RefreshCoalescer<Bool>()
        let gate = SettingsGate()
        var serverOn = true
        var reads = 0
        var holdNext = false
        /// What the app holds, and every answer it applied.
        var held: Bool?
        var applied: [Bool] = []

        func refresh() async {
            await coalescer.refresh(
                read: { [unowned self] in await read() },
                apply: { [unowned self] value in
                    applied.append(value)
                    held = value
                },
                failed: { Issue.record($0) }
            )
        }

        private func read() async -> Bool {
            reads += 1
            let answer = serverOn
            if holdNext {
                holdNext = false
                await gate.wait()
            }
            return answer
        }
    }

    @Test("A read a local save overtook is not applied, and a refresh asked for meanwhile reads once more")
    func overlappingRefreshesEndOnTheServersLatest() async {
        let harness = Harness()
        await harness.refresh()
        #expect(harness.held == true)

        // A save from this device lands while the next read is out.
        harness.holdNext = true
        let first = Task { await harness.refresh() }
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { harness.reads == 2 })
        harness.serverOn = false
        harness.coalescer.noteLocalChange()
        harness.held = false
        // The server's event for that save asks for a refresh while the read still runs.
        let joined = Task { await harness.refresh() }
        await Task.yield()
        await harness.gate.open()
        await first.value
        await joined.value

        // The held read answered on; it was never applied, and one more read (asked for twice:
        // by the save and by the event) brought the server's answer.
        #expect(harness.reads == 3)
        #expect(harness.applied == [true, false])
        #expect(harness.held == false)
    }
}
