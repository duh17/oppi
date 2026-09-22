import Accelerate
@preconcurrency import AVFoundation
import Foundation

/// All storage and FFT setup are owned before installTap. The tap is the only
/// serial caller; no actor hop, allocation, or lock occurs in this analyzer.
final class VoiceSpectrumAnalyzer: @unchecked Sendable {
    private static let count = 1_024
    private let setup: FFTSetup
    private let window: UnsafeMutablePointer<Float>
    private let samples: UnsafeMutablePointer<Float>
    private let real: UnsafeMutablePointer<Float>
    private let imaginary: UnsafeMutablePointer<Float>
    private let power: UnsafeMutablePointer<Float>
    private var filled = 0
    private var sampleRate = 0.0
    private var floor = SIMD8<Float>.zero
    private var previousDB = SIMD8<Float>.zero
    private var hasFloor = false
    private var latest = VoiceSpectrumFrame.zero

    init() throws {
        guard let setup = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2)) else {
            throw VoiceInputError.internalError("Cannot allocate voice spectrum FFT")
        }
        self.setup = setup
        window = .allocate(capacity: Self.count)
        samples = .allocate(capacity: Self.count)
        real = .allocate(capacity: Self.count / 2)
        imaginary = .allocate(capacity: Self.count / 2)
        power = .allocate(capacity: Self.count / 2)
        vDSP_hann_window(window, vDSP_Length(Self.count), Int32(vDSP_HANN_NORM))
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        window.deallocate()
        samples.deallocate()
        real.deallocate()
        imaginary.deallocate()
        power.deallocate()
    }

    /// Accumulates arbitrary tap lengths into fixed 1024-sample native-rate
    /// windows. Route rebuilds get a new analyzer; a format change resets history.
    func analyze(_ buffer: AVAudioPCMBuffer) -> VoiceSpectrumFrame {
        let rate = buffer.format.sampleRate
        guard rate.isFinite, rate > 0, buffer.frameLength > 0,
              let channel = buffer.floatChannelData?[0] else { return .zero }
        if sampleRate != rate {
            sampleRate = rate
            filled = 0
            hasFloor = false
            latest = .zero
        }
        var rms: Float = 0
        vDSP_rmsqv(channel, vDSP_Stride(buffer.stride), &rms, vDSP_Length(buffer.frameLength))
        var onset: Float = 0
        for index in 0..<Int(buffer.frameLength) {
            samples[filled] = channel[index * buffer.stride]
            filled += 1
            if filled == Self.count {
                analyzeWindow()
                onset = max(onset, latest.flux)
                filled = 0
            }
        }
        latest.level = OrbAudio.clamp(rms * 25)
        latest.flux = onset
        // Spectral contrast can amplify a quiet tone above its per-band floor.
        // Apply the legacy absolute quiet floor only to the emitted frame;
        // keep FFT/floor history intact, including across partial tap windows.
        var output = latest
        if output.level < VoiceLevelSmoother.noiseFloorDefault {
            output.bands = .zero
            output.flux = 0
        }
        return output
    }

    private func analyzeWindow() {
        let n = Self.count
        vDSP_vmul(samples, 1, window, 1, samples, 1, vDSP_Length(n))
        var split = DSPSplitComplex(realp: real, imagp: imaginary)
        samples.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
        }
        vDSP_fft_zrip(setup, &split, 1, 10, FFTDirection(FFT_FORWARD))
        // Packed DC/Nyquist is excluded; band bins start above DC.
        vDSP_zvmags(&split, 1, power, 1, vDSP_Length(n / 2))
        let edges = SIMD8<Double>(80, 250, 600, 1_500, 4_000, 8_000, 0, 0)
        let binHz = sampleRate / Double(n)
        let normalization = Float(1.0 / Double(4 * n * n))
        var bandDB = SIMD8<Float>(repeating: .nan)
        var startupFloor = Float.infinity
        for k in 0..<5 {
            guard edges[k] < sampleRate / 2 else { continue }
            let lo = max(1, Int(ceil(edges[k] / binHz)))
            let hi = min(n / 2, Int(ceil(min(edges[k + 1], sampleRate / 2) / binHz)))
            guard hi > lo else { continue }
            var energy: Float = 0
            vDSP_sve(power + lo, 1, &energy, vDSP_Length(hi - lo))
            // Numerical floor prevents FFT roundoff from becoming a visual band.
            let db = 10 * log10(max(1e-9, energy * normalization / Float(hi - lo)))
            bandDB[k] = db
            startupFloor = min(startupFloor, db)
        }
        var bands = SIMD8<Float>.zero
        var flux: Float = 0
        for k in 0..<5 {
            let db = bandDB[k]
            guard db.isFinite else { continue }
            if !hasFloor {
                // A take can start mid-speech. Seed from the quietest available
                // band's per-bin energy, not each band's possible speech peak.
                // Broadband room noise seeds its own level; the 6 dB gate and
                // subsequent per-band floor tracking remain unchanged.
                floor[k] = startupFloor
                previousDB[k] = db
            }
            floor[k] = min(db, floor[k] + Float(Double(n) / sampleRate))
            // 6 dB clears the floor's lag so room noise stays still.
            // Shape gain, not a shorter span, carries the visible reaction.
            bands[k] = OrbAudio.clamp((db - floor[k] - 6) / 24)
            flux += max(0, db - previousDB[k])
            previousDB[k] = db
        }
        hasFloor = true
        latest.bands = bands
        latest.flux = flux
    }
}
