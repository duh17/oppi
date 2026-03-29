import Foundation

extension ContinuousClock.Instant {
    /// Milliseconds elapsed since this instant.
    func elapsedMs() -> Int {
        let elapsed = ContinuousClock.now - self
        return Int(elapsed.components.seconds * 1000
            + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }
}
