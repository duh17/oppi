import Foundation

/// The list-repair state of one app-event stream window: the REST snapshot repair
/// that runs after a handshake (`ServerConnection.reconcileListSnapshotsAfterAppEventConnection`)
/// and the one follow-up a late external list failure may buy.
///
/// The connection owns one value and runs the refreshes; this type owns every
/// decision and the owner slot. A window starts at `streamConnected()` and ends at
/// `streamStopped()`, which cancels the owner and invalidates its cleanup.
struct AppEventListRepair {
    enum ExternalFailureAction: Equatable {
        /// A repair is running: it consumes the failure after its current pass.
        case heldForOwner
        /// This window already spent its follow-up.
        case ignored
        /// Start a repair now; the window's follow-up is spent.
        case startRepair
    }

    /// The running repair, if any. At most one per window.
    private(set) var task: Task<Void, Never>?
    private var followUpUsed = false
    private var pendingExternalFailure = false
    /// Bumped when an owner is installed or the stream tears down, so a
    /// cancelled owner's cleanup cannot clear a newer owner's slot.
    private var generation: UInt64 = 0

    /// A new connected window gets a fresh follow-up budget.
    mutating func streamConnected() {
        followUpUsed = false
        pendingExternalFailure = false
    }

    mutating func streamStopped() {
        generation &+= 1
        task?.cancel()
        task = nil
        followUpUsed = false
        pendingExternalFailure = false
    }

    /// A list refresh the user (not a repair) started failed while the stream is connected.
    mutating func noteExternalFailure() -> ExternalFailureAction {
        if task != nil {
            pendingExternalFailure = true
            return .heldForOwner
        }
        guard !followUpUsed else { return .ignored }
        followUpUsed = true
        return .startRepair
    }

    /// Whether a handshake must repair the lists. Checked before joining a
    /// running repair (known ordering issue 5c: a second call with no snapshot
    /// required and healthy lists returns at once while a repair still runs).
    func needsRepair(snapshotRequired: Bool, listsFailed: Bool) -> Bool {
        snapshotRequired || listsFailed || pendingExternalFailure
    }

    /// Install the owner before its first await, so a late external failure
    /// during its pass can hold the follow-up. `makeOwner` receives the epoch
    /// it must pass to `ownerFinished`.
    mutating func installOwner(_ makeOwner: (_ epoch: UInt64) -> Task<Void, Never>) {
        generation &+= 1
        task = makeOwner(generation)
    }

    /// The owner's cleanup: one main-actor transition, a no-op for an owner the
    /// stream already replaced.
    mutating func ownerFinished(epoch: UInt64) {
        guard generation == epoch else { return }
        pendingExternalFailure = false
        task = nil
    }

    /// After the owner's pass: whether to run the one follow-up pass for an
    /// external failure it held. Spends the budget before the pass, so failures
    /// of that pass (repair-owned) cannot reschedule.
    mutating func takeFollowUp() -> Bool {
        guard pendingExternalFailure, !followUpUsed else { return false }
        pendingExternalFailure = false
        followUpUsed = true
        return true
    }
}
