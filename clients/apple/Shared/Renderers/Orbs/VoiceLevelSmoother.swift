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

    /// Pose scale for dictation orbs. A constant value holds one pose.
    static func dictationShape(_ voice: Double) -> Double {
        guard voice.isFinite else { return 0 }
        return min(max(voice, 0), 1)
    }
}

/// Turns a live mic level into speech activity.
///
/// Room tone after `rms * 25` is rarely zero, so a raw gate never means
/// "not talking." Ambient tracks that floor. Activity is only the excess,
/// so a steady open mic holds the still pose and a syllable bends it.
struct DictationSpeechDrive: Equatable, Sendable {
    private(set) var ambient: Float = 0
    private(set) var activity: Float = 0
    private var age: TimeInterval = 0

    /// How far above ambient a level must sit before the sash moves.
    static let margin: Float = 0.05
    /// Excess that reaches a full pose. A normal syllable clears this.
    static let fullExcess: Float = 0.22

    mutating func reset() {
        ambient = 0
        activity = 0
        age = 0
    }

    mutating func step(level: Float, dt: TimeInterval) -> Float {
        let level = ThinkingOrbAudio.clamp(level)
        let safeDt = dt.isFinite ? max(0, dt) : 0
        guard safeDt > 0 else { return activity }
        age += safeDt
        // Calibrate to the open-mic floor, then only follow levels that
        // fall back into that floor. A held syllable must not be absorbed.
        let inFloor = level <= ambient + Self.margin
        if age < 0.30 || inFloor {
            let tau: TimeInterval = age < 0.30 ? 0.08 : 0.30
            let alpha = Float(1 - exp(-safeDt / tau))
            ambient += (level - ambient) * alpha
        }
        let excess = max(0, level - ambient - Self.margin)
        activity = min(1, excess / Self.fullExcess)
        return activity
    }
}
