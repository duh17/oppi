import QuartzCore

/// Counts display-link frames and hitches while something scrolls. A frame that
/// lands more than half a frame late is a hitch; the hitch time ratio is the
/// lateness summed over the scroll time. Feed it every tick's timestamps.
struct FrameHitchCounter {
    private var lastTimestamp: CFTimeInterval = 0
    private(set) var frames = 0
    private(set) var hitches = 0
    private(set) var worstFrameMilliseconds = 0.0
    /// Time between the first and the last counted frame.
    private(set) var elapsedMilliseconds = 0.0
    private var hitchMilliseconds = 0.0

    /// Hitch time over scroll time, 0 before any frame.
    var hitchRatio: Double {
        elapsedMilliseconds > 0 ? hitchMilliseconds / elapsedMilliseconds : 0
    }

    /// Counts the frame that landed at `timestamp`. The first tick after
    /// `forgetLastFrame` only starts the clock: the link may have been paused.
    mutating func tick(timestamp: CFTimeInterval, targetTimestamp: CFTimeInterval) {
        defer { lastTimestamp = timestamp }
        guard lastTimestamp > 0 else { return }
        let interval = (timestamp - lastTimestamp) * 1_000
        let expected = max(1, (targetTimestamp - timestamp) * 1_000)
        frames += 1
        elapsedMilliseconds += interval
        worstFrameMilliseconds = max(worstFrameMilliseconds, interval)
        if interval > expected * 1.5 {
            hitches += 1
            hitchMilliseconds += interval - expected
        }
    }

    /// Zeroes the counts, keeping the last frame's time.
    mutating func resetCounts() {
        self = Self(lastTimestamp: lastTimestamp)
    }

    /// The next tick starts the clock again (a link that was off).
    mutating func forgetLastFrame() {
        lastTimestamp = 0
    }

    init(lastTimestamp: CFTimeInterval = 0) {
        self.lastTimestamp = lastTimestamp
    }
}
