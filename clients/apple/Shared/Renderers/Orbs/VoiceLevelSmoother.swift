import Foundation

/// Native-tap measurements. Only the first five lanes contain frequency bands.
struct VoiceSpectrumFrame: Equatable, Sendable {
    var level: Float = 0
    var bands: SIMD8<Float> = .zero
    /// Sum of positive band-energy changes, in dB per analysis frame.
    var flux: Float = 0

    static let zero = VoiceSpectrumFrame()
}

/// Per-band elapsed-time smoothing; no scalar speech gate couples the bands.
struct VoiceSpectrumSmoother: Sendable {
    private(set) var current = VoiceSpectrumFrame.zero
    private var level = VoiceLevelSmoother()

    mutating func reset() {
        current = .zero
        level.reset()
    }

    mutating func step(raw: VoiceSpectrumFrame, dt: TimeInterval) -> VoiceSpectrumFrame {
        let safeDt = dt.isFinite ? max(0, dt) : 0
        var target = SIMD8<Float>.zero
        for k in 0..<5 { target[k] = OrbAudio.clamp(raw.bands[k]) }
        let attack = Float(1 - exp(-safeDt / 0.040))
        let release = Float(1 - exp(-safeDt / 0.180))
        let alpha = SIMD8<Float>(repeating: release).replacing(
            with: SIMD8<Float>(repeating: attack), where: target .>= current.bands
        )
        current.bands += (target - current.bands) * alpha
        let flux = raw.flux.isFinite ? max(0, raw.flux) : 0
        current.flux += (flux - current.flux) * (flux >= current.flux ? attack : release)
        current.level = level.step(raw: raw.level, dt: safeDt)
        return current
    }
}

/// Elapsed-time attack/release smoother for the legacy RMS level.
///
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
    static let noiseFloorDefault: Float = 0.03

    init(
        attackSeconds: TimeInterval = Self.attackDefault,
        releaseSeconds: TimeInterval = Self.releaseDefault,
        noiseFloor: Float = Self.noiseFloorDefault,
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
        let clamped = OrbAudio.clamp(raw)
        let gated = clamped < noiseFloor ? 0 : clamped
        let target = gated / (1 + compression * gated)
        let safeDt = dt.isFinite ? max(0, dt) : 0
        if safeDt == 0 {
            return OrbAudio.clamp(current)
        }
        let tau = target >= current ? attackSeconds : releaseSeconds
        let alpha = Float(1 - exp(-safeDt / tau))
        current += (target - current) * alpha
        current = OrbAudio.clamp(current)
        return current
    }
}

enum OrbAudio {
    static func clamp(_ raw: Float) -> Float {
        guard raw.isFinite else { return 0 }
        return min(max(raw, 0), 1)
    }
}
