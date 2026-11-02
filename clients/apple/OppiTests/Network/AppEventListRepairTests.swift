import Testing
@testable import Oppi

/// Decision table of the app-event list repair: the follow-up budget per stream
/// window and the owner slot's epoch fence. The refreshes themselves are covered
/// end to end in `AppEventStreamClientTests`.
@Suite("App-event list repair")
@MainActor
struct AppEventListRepairTests {
    @Test func externalFailureBuysOneRepairPerWindow() {
        var repair = AppEventListRepair()
        var actions = [repair.noteExternalFailure(), repair.noteExternalFailure()]
        #expect(actions == [.startRepair, .ignored])

        repair.streamConnected()
        actions = [repair.noteExternalFailure()]
        #expect(actions == [.startRepair])

        repair.streamStopped()
        actions = [repair.noteExternalFailure()]
        #expect(actions == [.startRepair])
    }

    @Test func runningOwnerHoldsOneFailureForOneFollowUpPass() {
        var repair = AppEventListRepair()
        #expect(!repair.needsRepair(snapshotRequired: false, listsFailed: false))
        var epoch: UInt64 = 0
        repair.installOwner { ownerEpoch in
            epoch = ownerEpoch
            return Task {}
        }

        let held = repair.noteExternalFailure()
        #expect(held == .heldForOwner)
        // A held failure alone asks the next handshake to repair.
        #expect(repair.needsRepair(snapshotRequired: false, listsFailed: false))
        let firstFollowUp = repair.takeFollowUp()
        #expect(firstFollowUp)
        // The follow-up spent the window's budget: no second pass, no new repair.
        let heldAgain = repair.noteExternalFailure()
        #expect(heldAgain == .heldForOwner)
        let secondFollowUp = repair.takeFollowUp()
        #expect(!secondFollowUp)

        repair.ownerFinished(epoch: epoch)
        #expect(repair.task == nil)
        #expect(!repair.needsRepair(snapshotRequired: false, listsFailed: false))
        let afterOwner = repair.noteExternalFailure()
        #expect(afterOwner == .ignored)
    }

    @Test func staleOwnerCleanupLeavesTheNewerOwner() {
        var repair = AppEventListRepair()
        var staleEpoch: UInt64 = 0
        repair.installOwner { epoch in
            staleEpoch = epoch
            return Task {}
        }
        repair.streamStopped()
        #expect(repair.task == nil)

        repair.installOwner { _ in Task {} }
        let held = repair.noteExternalFailure()
        #expect(held == .heldForOwner)
        repair.ownerFinished(epoch: staleEpoch)

        #expect(repair.task != nil)
        let followUp = repair.takeFollowUp()
        #expect(followUp)
    }
}
