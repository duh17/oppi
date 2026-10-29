import Foundation

extension ContinuousClock.Instant {
    /// Milliseconds elapsed since this instant.
    func elapsedMs() -> Int {
        elapsedMs(until: ContinuousClock.now)
    }

    /// Milliseconds from this instant to `end`.
    func elapsedMs(until end: ContinuousClock.Instant) -> Int {
        let elapsed = end - self
        return Int(elapsed.components.seconds * 1000
            + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }
}
