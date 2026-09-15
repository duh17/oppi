import CoreGraphics
import Foundation

/// Transfers a `CGImage` off the capture queue. The image is treated as exclusively owned.
struct TransferredCGImage: @unchecked Sendable {
    let image: CGImage
}

/// Drops-old mailbox: at most one pending frame and one scheduled delivery.
/// Schedule work on the delivery executor (MainActor for preview). Do not hop per frame.
final class DesktopLatestFrameMailbox<Frame>: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: Frame?
    private var scheduled = false
    private var closed = false
    private let schedule: @Sendable (@escaping @Sendable () -> Void) -> Void
    private let deliver: @Sendable (Frame) -> Void

    init(
        schedule: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void,
        deliver: @escaping @Sendable (Frame) -> Void
    ) {
        self.schedule = schedule
        self.deliver = deliver
    }

    func offer(_ frame: Frame) {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        latest = frame
        let needsSchedule = !scheduled
        if needsSchedule {
            scheduled = true
        }
        lock.unlock()
        if needsSchedule {
            schedule { [weak self] in
                self?.flush()
            }
        }
    }

    /// Drop a pending frame without closing. An in-flight flush becomes a no-op.
    func discardPending() {
        lock.lock()
        latest = nil
        lock.unlock()
    }

    /// Discard pending frames and reject later offers. In-flight flush becomes a no-op.
    func close() {
        lock.lock()
        latest = nil
        closed = true
        lock.unlock()
    }

    private func flush() {
        lock.lock()
        let frame = latest
        latest = nil
        scheduled = false
        let isClosed = closed
        lock.unlock()
        if isClosed { return }
        if let frame {
            deliver(frame)
        }
    }
}
