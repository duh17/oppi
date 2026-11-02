import Foundation

/// The write machinery under one `WorkspaceFileEditSession`: at most one write
/// in flight, the person's save queued behind it, and the offline-retry and
/// verify timers. It reports what happened and decides nothing: the session
/// alone sets status, and its `send` stays the one Auto-Save gate.
///
/// Every write carries a token and the epoch it started in. `cancelAll()` moves
/// the epoch, so a late answer, retry, or verify read from before it is dropped
/// and can never mark newer edits saved.
@MainActor
final class WorkspaceFileWriteQueue {
    struct Write {
        let generation: Int
        let bytes: Data
        let origin: WorkspaceFileEditSession.WriteOrigin
    }

    /// A person's save that arrived while a write was in flight. One write runs
    /// at a time, so their bytes wait and go next as `.confirmed`, whatever
    /// origin the flight had.
    struct QueuedSave {
        let generation: Int
        let bytes: Data
    }

    enum Event {
        /// The write in flight answered.
        case written(Write, WorkspaceFileWriteOutcome)
        /// The offline retry delay for `Write` elapsed.
        case retryDue(Write)
        /// The read that checks whether a write with a lost answer landed.
        case verified(Write, WorkspaceFileReadOutcome)
    }

    private struct Flight {
        let token: UUID
        let write: Write
    }

    /// Delivered on the main actor. A write's answer is dropped unless its token
    /// matches the write in flight; a retry or verify report is dropped unless
    /// its epoch is current. `cancelAll()` invalidates both.
    var onEvent: ((Event) -> Void)?
    private(set) var epoch = 0
    private var queuedSave: QueuedSave?
    private var flight: Flight?
    private var flightTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private let identity: WorkspaceFileEditIdentity
    private let transport: WorkspaceFileEditTransport
    private let retryDelay: Duration

    init(identity: WorkspaceFileEditIdentity, transport: WorkspaceFileEditTransport, retryDelay: Duration) {
        self.identity = identity
        self.transport = transport
        self.retryDelay = retryDelay
    }

    var inFlight: Write? { flight?.write }
    var isWriting: Bool { flight != nil }

    /// Starts `write`; a pending retry or verify is dropped. Callers pass only
    /// writes the session's gate allowed, and only while nothing is in flight.
    func start(_ write: Write, condition: WorkspaceFileWriteCondition) {
        timerTask?.cancel()
        timerTask = nil
        let started = Flight(token: UUID(), write: write)
        flight = started
        let transport = transport
        let identity = identity
        flightTask = Task { [weak self] in
            let outcome = await transport.write(identity, write.bytes, condition)
            self?.finish(started, outcome)
        }
    }

    private func finish(_ finished: Flight, _ outcome: WorkspaceFileWriteOutcome) {
        guard flight?.token == finished.token else { return }
        flight = nil
        flightTask = nil
        onEvent?(.written(finished.write, outcome))
    }

    /// Waits for the current write (and any follow-up it starts) to finish.
    func waitForInFlightWrite() async {
        while let task = flightTask {
            await task.value
        }
    }

    func queueSave(_ save: QueuedSave) { queuedSave = save }

    func dropQueuedSave() { queuedSave = nil }

    func takeQueuedSave() -> QueuedSave? {
        defer { queuedSave = nil }
        return queuedSave
    }

    /// Reports `.retryDue` after the retry delay, unless cancelled first.
    func scheduleRetry(_ write: Write) {
        timerTask?.cancel()
        let delay = retryDelay
        let startEpoch = epoch
        timerTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.epoch == startEpoch else { return }
            self.timerTask = nil
            self.onEvent?(.retryDue(write))
        }
    }

    /// Reads disk to learn whether `write` landed, now or after the retry delay.
    func verify(_ write: Write, afterRetryDelay: Bool) {
        timerTask?.cancel()
        let delay: Duration? = afterRetryDelay ? retryDelay : nil
        let startEpoch = epoch
        let transport = transport
        let identity = identity
        timerTask = Task { [weak self] in
            if let delay {
                try? await Task.sleep(for: delay)
                if Task.isCancelled { return }
            }
            let outcome = await transport.read(identity)
            guard let self, !Task.isCancelled, self.epoch == startEpoch else { return }
            self.timerTask = nil
            self.onEvent?(.verified(write, outcome))
        }
    }

    /// Drops everything: the write in flight (its answer is ignored), the queued
    /// save, and any retry or verify. Moves the epoch.
    func cancelAll() {
        epoch &+= 1
        timerTask?.cancel()
        timerTask = nil
        flight = nil
        flightTask = nil
        queuedSave = nil
    }
}
