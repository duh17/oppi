import Foundation

/// Elapsed-time attack/release smoother for a VoiceInputManager-compatible level.
///
/// Loudness after smoothing drives deformation amplitude, never animation speed.
/// Coefficients are functions of `dt`, so 30 Hz and 60 Hz agree after the same
/// elapsed time.
struct VoiceLevelSmoother: Equatable, Sendable {
    var attackSeconds: TimeInterval
    var releaseSeconds: TimeInterval
    var noiseFloor: Float
    /// Mild knee so peaks don't slam; quiet speech stays clearly above zero.
    var compression: Float
    private(set) var current: Float = 0

    static let attackDefault: TimeInterval = 0.100
    static let releaseDefault: TimeInterval = 0.300

    init(
        attackSeconds: TimeInterval = Self.attackDefault,
        releaseSeconds: TimeInterval = Self.releaseDefault,
        noiseFloor: Float = 0.03,
        compression: Float = 0.28
    ) {
        self.attackSeconds = max(0.001, attackSeconds)
        self.releaseSeconds = max(0.001, releaseSeconds)
        self.noiseFloor = max(0, noiseFloor)
        self.compression = max(0, compression)
    }

    mutating func reset() {
        current = 0
    }

    mutating func step(raw: Float, dt: TimeInterval) -> Float {
        let clamped = ThinkingOrbAudio.clamp(raw)
        let gated = clamped < noiseFloor ? 0 : clamped
        let target = gated / (1 + compression * gated)
        let safeDt = dt.isFinite ? max(0, dt) : 0
        if safeDt == 0 {
            return ThinkingOrbAudio.clamp(current)
        }
        let tau = target >= current ? attackSeconds : releaseSeconds
        let alpha = Float(1 - exp(-safeDt / tau))
        current += (target - current) * alpha
        current = ThinkingOrbAudio.clamp(current)
        return current
    }
}

enum ThinkingOrbAudio {
    static func clamp(_ raw: Float) -> Float {
        guard raw.isFinite else { return 0 }
        return min(max(raw, 0), 1)
    }
}
