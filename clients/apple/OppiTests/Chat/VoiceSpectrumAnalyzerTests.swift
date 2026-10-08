import AVFoundation
import Foundation
import Testing
@testable import Oppi

@Suite("VoiceSpectrumAnalyzer")
struct VoiceSpectrumAnalyzerTests {
    @Test func immediateSpeechRespondsWithoutASilentPrimingWindow() throws {
        for rate in [44_100.0, 48_000.0] {
            for (hz, amplitude, band) in [(150.0, 0.01, 0), (5_000.0, 0.03, 4)] {
                let analyzer = try VoiceSpectrumAnalyzer()
                let speech = try buffer(rate: rate) { Float(amplitude * sin(2 * .pi * hz * $0 / rate)) }
                let first = analyzer.analyze(speech)
                #expect(first.bands[band] > 0.8, "Immediate speech at \(rate) Hz must move the orb")
                var sustained = first
                for _ in 0..<20 { sustained = analyzer.analyze(speech) }
                #expect(sustained.bands[band] > 0.8)
                #expect(analyzer.analyze(try buffer(rate: rate) { _ in 0 }).bands == .zero)
            }
        }
    }

    @Test func subQuietFloorToneStaysStillAtStartupAndAfterTwoSeconds() throws {
        for rate in [44_100.0, 48_000.0] {
            for primed in [false, true] {
                let analyzer = try VoiceSpectrumAnalyzer()
                if primed { _ = analyzer.analyze(try buffer(rate: rate) { _ in 0 }) }
                let tone = try buffer(rate: rate) { Float(0.001 * sin(2 * .pi * 150 * $0 / rate)) }
                for index in 0..<110 {
                    let frame = analyzer.analyze(tone)
                    #expect(frame.level > 0 && frame.level < 0.03)
                    #expect(frame.bands == .zero)
                    #expect(frame.flux == 0)
                    if index == 0 || index == 109 {
                        print("quiet tone rate=\(rate) primed=\(primed) window=\(index) level=\(frame.level) band0=\(frame.bands[0]) flux=\(frame.flux)")
                    }
                }
            }
        }
    }

    @Test func subQuietFloorColoredNoiseStaysStillAtStartupAndAfterTwoSeconds() throws {
        for rate in [44_100.0, 48_000.0] {
            let analyzer = try VoiceSpectrumAnalyzer()
            var random: UInt64 = 0x123456789
            var filtered: Float = 0
            for index in 0..<110 {
                let noise = try buffer(rate: rate) { _ in
                    random = random &* 6_364_136_223_846_793_005 &+ 1
                    let white = Float(random >> 40) / Float(1 << 24) - 0.5
                    filtered += 0.04 * (white - filtered)
                    return filtered * 0.01
                }
                // Fixed RMS below the absolute quiet floor, with a low-pass
                // spectrum that still has contrast against the high bands.
                let scale: Float = 0.025 / rmsLevel(noise)
                let channel = try #require(noise.floatChannelData?[0])
                for i in 0..<Int(noise.frameLength) { channel[i] *= scale }
                let frame = analyzer.analyze(noise)
                #expect(abs(frame.level - 0.025) < 1e-5)
                #expect(frame.bands == .zero)
                #expect(frame.flux == 0)
                if index == 0 || index == 109 {
                    print("quiet colored noise rate=\(rate) window=\(index) level=\(frame.level) band0=\(frame.bands[0]) flux=\(frame.flux)")
                }
            }
        }
    }

    @Test func silenceAfterToneClearsSpectralOutputEvenBeforeNextFFTWindow() throws {
        for count in [256, 1_024] {
            let analyzer = try VoiceSpectrumAnalyzer()
            let tone = try buffer { Float(0.01 * sin(2 * .pi * 150 * $0 / 48_000)) }
            #expect(analyzer.analyze(tone).bands[0] > 0.8)
            for _ in 0..<8 {
                let silent = analyzer.analyze(try buffer(count: count) { _ in 0 })
                #expect(silent.level == 0)
                #expect(silent.bands == .zero)
                #expect(silent.flux == 0)
            }
            let resumed = analyzer.analyze(tone)
            #expect(resumed.bands[0] > 0.8)
            #expect(resumed.flux > 20)
        }
    }

    @Test func startupRoomNoiseDoesNotBecomeSpeech() throws {
        for rate in [44_100.0, 48_000.0] {
            let analyzer = try VoiceSpectrumAnalyzer()
            var random: UInt64 = 0x123456789
            var sum = SIMD8<Float>.zero
            for index in 0..<21 {
                let noise = try buffer(rate: rate) { _ in
                    random = random &* 6_364_136_223_846_793_005 &+ 1
                    return (Float(random >> 40) / Float(1 << 24) - 0.5) * 0.08
                }
                let frame = analyzer.analyze(noise)
                if index == 0 { #expect(frame.bands.max() < 0.12) }
                sum += frame.bands
            }
            // Individual low-band noise windows fluctuate; use the same
            // mean-contrast oracle as the stationary-noise characterization.
            for k in 0..<5 { #expect(sum[k] / 21 < 0.12) }
        }
    }

    @Test func lowSineIsDominantInBandZeroAtNativeRates() throws {
        for rate in [44_100.0, 48_000.0] {
            let analyzer = try VoiceSpectrumAnalyzer()
            _ = analyzer.analyze(try buffer(rate: rate) { _ in 0 })
            let sine = try buffer(rate: rate) { Float(0.01 * sin(2 * .pi * 150 * $0 / rate)) }
            let frame = analyzer.analyze(sine)
            #expect(frame.bands[0] > 0.8)
            for k in 1..<5 { #expect(frame.bands[0] > frame.bands[k]) }
            #expect(abs(frame.level - rmsLevel(sine)) < 1e-5)
        }
    }

    @Test func highSineIsDominantInBandFourAtNativeRates() throws {
        for rate in [44_100.0, 48_000.0] {
            let analyzer = try VoiceSpectrumAnalyzer()
            _ = analyzer.analyze(try buffer(rate: rate) { _ in 0 })
            let frame = analyzer.analyze(try buffer(rate: rate) { Float(0.03 * sin(2 * .pi * 5_000 * $0 / rate)) })
            #expect(frame.bands[4] > 0.8)
            for k in 0..<4 { #expect(frame.bands[4] > frame.bands[k]) }
            #expect(frame.bands[5] == 0 && frame.bands[6] == 0 && frame.bands[7] == 0)
        }
    }

    @Test func stationaryNoiseContrastsStayNearZeroAfterTwoSeconds() throws {
        let analyzer = try VoiceSpectrumAnalyzer()
        var random: UInt64 = 0x123456789
        var sum = SIMD8<Float>.zero
        var measured = 0
        for index in 0..<140 {
            let noise = try buffer { _ in
                random = random &* 6_364_136_223_846_793_005 &+ 1
                return (Float(random >> 40) / Float(1 << 24) - 0.5) * 0.08
            }
            let frame = analyzer.analyze(noise)
            if index >= 94 { // More than two seconds at 48 kHz.
                sum += frame.bands
                measured += 1
            }
        }
        for k in 0..<5 {
            let mean = sum[k] / Float(measured)
            print("stationary noise band \(k) mean contrast=\(mean)")
            #expect(mean < 0.12)
        }
    }

    @Test func sineBurstRespondsWithinTwoTapBuffersAndFluxDecays() throws {
        let analyzer = try VoiceSpectrumAnalyzer()
        let quiet = try buffer { _ in 0 }
        for _ in 0..<10 { _ = analyzer.analyze(quiet) }
        let burst = try buffer { Float(0.02 * sin(2 * .pi * 150 * $0 / 48_000)) }
        let first = analyzer.analyze(burst)
        let second = analyzer.analyze(burst)
        #expect(max(first.bands[0], second.bands[0]) > 0.8)
        #expect(first.flux > 20)
        #expect(second.flux < 0.01)
        #expect(analyzer.analyze(quiet).bands == .zero)
    }

    @Test func bandsAboveNyquistAreZeroAndShortTapsAccumulate() throws {
        let analyzer = try VoiceSpectrumAnalyzer()
        _ = analyzer.analyze(try buffer(rate: 8_000) { _ in 0 })
        let input = try buffer(rate: 8_000) { Float(0.02 * sin(2 * .pi * 1_000 * $0 / 8_000)) }
        let frame = analyzer.analyze(input)
        #expect(frame.bands[2] > 0.5)
        #expect(frame.bands[4] == 0)

        let shortAnalyzer = try VoiceSpectrumAnalyzer()
        _ = shortAnalyzer.analyze(try buffer { _ in 0 })
        for chunk in 0..<4 {
            let short = try buffer(count: 256) { Float(0.02 * sin(2 * .pi * 150 * ($0 + Double(chunk * 256)) / 48_000)) }
            let result = shortAnalyzer.analyze(short)
            if chunk < 3 { #expect(result.bands == .zero) } else { #expect(result.bands[0] > 0.8) }
        }
    }

    @Test func floorFallsImmediatelyAndRisesNoFasterThanOneDBPerSecond() throws {
        let analyzer = try VoiceSpectrumAnalyzer()
        let quiet = try buffer { _ in 0 }
        // Above the absolute quiet gate, but still unsaturated so the
        // per-band floor's rise and immediate fall remain observable.
        let sine = try buffer { Float(0.002 * sin(2 * .pi * 150 * $0 / 48_000)) }
        _ = analyzer.analyze(quiet)
        let first = analyzer.analyze(sine)
        var last = first
        for _ in 0..<94 { last = analyzer.analyze(sine) }
        // An unsaturated contrast can fall by at most ~2 dB / 24 in two seconds.
        #expect(first.bands[0] > 0.1 && first.bands[0] < 1)
        #expect(first.bands[0] - last.bands[0] <= 2.1 / 24)
        _ = analyzer.analyze(quiet)
        let recovered = analyzer.analyze(sine)
        #expect(abs(recovered.bands[0] - first.bands[0]) < 1e-5)
    }

    private func buffer(rate: Double = 48_000, count: Int = 1_024,
                        sample: (Double) -> Float) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
        pcm.frameLength = AVAudioFrameCount(count)
        let channel = try #require(pcm.floatChannelData?[0])
        for i in 0..<count { channel[i] = sample(Double(i)) }
        return pcm
    }

    private func rmsLevel(_ pcm: AVAudioPCMBuffer) -> Float {
        guard let channel = pcm.floatChannelData?[0] else { return 0 }
        var square: Float = 0
        for i in 0..<Int(pcm.frameLength) { square += channel[i] * channel[i] }
        return min(1, sqrt(square / Float(pcm.frameLength)) * 25)
    }
}
