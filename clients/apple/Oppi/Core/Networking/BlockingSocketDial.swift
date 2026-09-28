import Darwin
import Dispatch
import Synchronization

/// Bounds a blocking connect call (such as `tailscale_dial`, which has no
/// deadline) by a timeout and task cancellation. The call runs on a
/// background queue; whichever finishes first wins, and a socket that arrives
/// after the caller gave up is closed so its tailnet connection ends.
enum BlockingSocketDial {
    /// Throws the dial's `SSHPreflightFailure`, `.dialTimedOut`, or `CancellationError`.
    static func run(
        timeout: Duration,
        dial: @escaping @Sendable () -> Result<Int32, SSHPreflightFailure>
    ) async throws -> Int32 {
        let slot = Slot()
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard slot.install(continuation) else { return }
                DispatchQueue.global(qos: .userInitiated).async {
                    let outcome = dial()
                    if !slot.finish(outcome), case .success(let late) = outcome {
                        close(late)
                    }
                }
                let seconds = Double(timeout.components.seconds)
                    + Double(timeout.components.attoseconds) / 1e18
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                    _ = slot.finish(.failure(.dialTimedOut))
                }
            }
        } onCancel: {
            // The value is discarded: the caller sees CancellationError below.
            _ = slot.finish(.failure(.dialTimedOut))
        }
        if Task.isCancelled {
            if case .success(let conn) = result { close(conn) }
            throw CancellationError()
        }
        return try result.get()
    }

    private typealias Outcome = Result<Int32, SSHPreflightFailure>

    private final class Slot: Sendable {
        private enum State {
            case pending
            case waiting(CheckedContinuation<Outcome, Never>)
            /// Cancelled before the continuation was installed.
            case early(Outcome)
            case finished
        }

        private let state = Mutex(State.pending)

        /// Returns false when cancellation already won; the dial must not start.
        func install(_ continuation: CheckedContinuation<Outcome, Never>) -> Bool {
            let early: Outcome? = state.withLock { state in
                switch state {
                case .pending:
                    state = .waiting(continuation)
                    return nil
                case .early(let outcome):
                    state = .finished
                    return outcome
                case .waiting, .finished:
                    preconditionFailure("continuation installed twice")
                }
            }
            guard let early else { return true }
            continuation.resume(returning: early)
            return false
        }

        /// Returns false when another outcome already won.
        func finish(_ outcome: Outcome) -> Bool {
            let continuation: CheckedContinuation<Outcome, Never>?
            let delivered: Bool
            (continuation, delivered) = state.withLock { state in
                switch state {
                case .pending:
                    state = .early(outcome)
                    return (nil, true)
                case .waiting(let continuation):
                    state = .finished
                    return (continuation, true)
                case .early, .finished:
                    return (nil, false)
                }
            }
            continuation?.resume(returning: outcome)
            return delivered
        }
    }
}
