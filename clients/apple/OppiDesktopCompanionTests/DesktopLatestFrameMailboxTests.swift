import Foundation
import Testing
@testable import OppiDesktopCompanion

@Suite("DesktopLatestFrameMailbox")
struct DesktopLatestFrameMailboxTests {
    @Test func slowConsumerKeepsOnlyTheLatestFrame() {
        let probe = Probe()
        let mailbox = DesktopLatestFrameMailbox<Int>(
            schedule: { work in probe.pending.append(work) },
            deliver: { value in probe.delivered.append(value) }
        )

        mailbox.offer(1)
        mailbox.offer(2)
        mailbox.offer(3)

        #expect(probe.pending.count == 1)
        #expect(probe.delivered.isEmpty)

        probe.pending.removeFirst()()

        #expect(probe.delivered == [3])
        #expect(probe.pending.isEmpty)
    }

    @Test func flushReschedulesForALaterFrame() {
        let probe = Probe()
        let mailbox = DesktopLatestFrameMailbox<Int>(
            schedule: { work in probe.pending.append(work) },
            deliver: { value in probe.delivered.append(value) }
        )

        mailbox.offer(1)
        probe.pending.removeFirst()()
        #expect(probe.delivered == [1])

        mailbox.offer(2)
        mailbox.offer(3)
        #expect(probe.pending.count == 1)
        probe.pending.removeFirst()()
        #expect(probe.delivered == [1, 3])
    }

    @Test func closeDropsPendingAndRejectsLateOffers() {
        let probe = Probe()
        let mailbox = DesktopLatestFrameMailbox<Int>(
            schedule: { work in probe.pending.append(work) },
            deliver: { value in probe.delivered.append(value) }
        )

        mailbox.offer(1)
        mailbox.close()
        mailbox.offer(2)
        #expect(probe.pending.count == 1)
        probe.pending.removeFirst()()
        #expect(probe.delivered.isEmpty)

        mailbox.offer(3)
        #expect(probe.pending.isEmpty)
        #expect(probe.delivered.isEmpty)
    }

    @Test func discardPendingDropsTheBufferedFrameWithoutClosing() {
        let probe = Probe()
        let mailbox = DesktopLatestFrameMailbox<Int>(
            schedule: { work in probe.pending.append(work) },
            deliver: { value in probe.delivered.append(value) }
        )

        mailbox.offer(1)
        mailbox.discardPending()
        probe.pending.removeFirst()()
        #expect(probe.delivered.isEmpty)

        mailbox.offer(4)
        #expect(probe.pending.count == 1)
        probe.pending.removeFirst()()
        #expect(probe.delivered == [4])
    }
}

private final class Probe: @unchecked Sendable {
    var pending: [@Sendable () -> Void] = []
    var delivered: [Int] = []
}
