import CoreVideo
import Foundation

/// Newest NV12 pixel buffer wins. Encode reads the latest buffer; it never queues frames.
final class DesktopLiveViewPixelMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var closed = false

    func offer(_ buffer: CVPixelBuffer) {
        lock.lock()
        if !closed {
            latest = buffer
        }
        lock.unlock()
    }

    func peek() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return closed ? nil : latest
    }

    func close() {
        lock.lock()
        latest = nil
        closed = true
        lock.unlock()
    }

    func reset() {
        lock.lock()
        latest = nil
        closed = false
        lock.unlock()
    }
}
