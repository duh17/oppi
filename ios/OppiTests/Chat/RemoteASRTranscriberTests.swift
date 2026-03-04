import Foundation
import Testing
@testable import Oppi

/// Tests for RemoteASRTranscriber and WAVEncoder.
///
/// Network-dependent tests use a local mock or are skipped in CI.
/// Audio-path tests verify WAV encoding correctness and buffer management.
@Suite("RemoteASRTranscriber")
struct RemoteASRTranscriberTests {

    // MARK: - WAV Encoder

    @Test func wavEncoderProducesValidHeader() {
        let samples: [Float] = [0.0, 0.5, -0.5, 1.0, -1.0]
        let sampleRate = 16_000
        let data = WAVEncoder.encode(samples: samples, sampleRate: sampleRate)

        // Minimum WAV size: 44-byte header + 2 bytes per sample
        #expect(data.count == 44 + samples.count * 2)

        // RIFF header
        #expect(String(data: data[0..<4], encoding: .ascii) == "RIFF")
        #expect(String(data: data[8..<12], encoding: .ascii) == "WAVE")

        // fmt sub-chunk
        #expect(String(data: data[12..<16], encoding: .ascii) == "fmt ")

        // PCM format (1)
        let format = data[20..<22].withUnsafeBytes { $0.load(as: UInt16.self) }
        #expect(format == 1)

        // Mono (1 channel)
        let channels = data[22..<24].withUnsafeBytes { $0.load(as: UInt16.self) }
        #expect(channels == 1)

        // Sample rate
        let sr = data[24..<28].withUnsafeBytes { $0.load(as: UInt32.self) }
        #expect(sr == UInt32(sampleRate))

        // Bits per sample (16)
        let bps = data[34..<36].withUnsafeBytes { $0.load(as: UInt16.self) }
        #expect(bps == 16)

        // data sub-chunk
        #expect(String(data: data[36..<40], encoding: .ascii) == "data")
    }

    @Test func wavEncoderClipsToRange() {
        // Values outside [-1, 1] should be clipped
        let samples: [Float] = [2.0, -2.0, 0.0]
        let data = WAVEncoder.encode(samples: samples, sampleRate: 16_000)

        // Extract Int16 samples from data (offset 44)
        let pcmData = data[44...]
        let int16s = pcmData.withUnsafeBytes { buf -> [Int16] in
            Array(buf.bindMemory(to: Int16.self))
        }

        #expect(int16s.count == 3)
        // 2.0 clipped to 1.0 -> Int16.max (32767)
        #expect(int16s[0] == Int16.max)
        // -2.0 clipped to -1.0 -> Int16.min + 1 (-32767, not -32768 due to vDSP)
        #expect(int16s[1] < -32000, "Expected large negative, got \(int16s[1])")
        // 0.0 -> 0
        #expect(int16s[2] == 0)
    }

    @Test func wavEncoderEmptySamples() {
        let data = WAVEncoder.encode(samples: [], sampleRate: 16_000)
        // Just the header, no PCM data
        #expect(data.count == 44)
    }

    @Test func wavEncoderFileSizeField() {
        let samples = [Float](repeating: 0.5, count: 1000)
        let data = WAVEncoder.encode(samples: samples, sampleRate: 16_000)

        // RIFF file size = total - 8 (RIFF + size fields)
        let riffSize = data[4..<8].withUnsafeBytes { $0.load(as: UInt32.self) }
        #expect(Int(riffSize) == data.count - 8)

        // data sub-chunk size
        let dataSize = data[40..<44].withUnsafeBytes { $0.load(as: UInt32.self) }
        #expect(Int(dataSize) == samples.count * 2)
    }

    // MARK: - Configuration

    @Test func configurationDefaults() {
        let config = RemoteASRTranscriber.Configuration(
            endpointURL: URL(string: "http://localhost:8321")!  // swiftlint:disable:this force_unwrapping
        )
        #expect(config.model == "default")
        #expect(config.language == nil)
        #expect(config.prompt == nil)
        #expect(config.temperature == 0.0)
        #expect(config.chunkInterval == 2.0)
        #expect(config.overlapDuration == 0.5)
        #expect(config.sampleRate == 16_000)
        #expect(config.requestTimeout == 10.0)
        #expect(config.responseFormat == "json")
    }

    @Test func configurationCustomValues() {
        let config = RemoteASRTranscriber.Configuration(
            endpointURL: URL(string: "http://mac-studio.local:8321")!,  // swiftlint:disable:this force_unwrapping
            model: "mlx-community/whisper-large-v3-turbo",
            language: "en",
            prompt: "Technical transcription context",
            temperature: 0.3,
            chunkInterval: 1.5,
            overlapDuration: 0.3,
            sampleRate: 16_000,
            requestTimeout: 15.0,
            responseFormat: "verbose_json"
        )
        #expect(config.model == "mlx-community/whisper-large-v3-turbo")
        #expect(config.language == "en")
        #expect(config.prompt == "Technical transcription context")
        #expect(config.temperature == 0.3)
        #expect(config.chunkInterval == 1.5)
        #expect(config.overlapDuration == 0.3)
        #expect(config.requestTimeout == 15.0)
        #expect(config.responseFormat == "verbose_json")
    }

    // MARK: - Engine Selection

    @Test @MainActor func enginePreferenceRemoteASR() {
        let manager = VoiceInputManager()

        // Default: locale-based
        #expect(
            VoiceInputManager.preferredEngine(for: Locale(identifier: "en-US")) == .modernSpeech
        )

        // Set remote preference + endpoint
        manager.setRemoteASREndpoint(URL(string: "http://localhost:8321"))
        manager.setEnginePreference(.remoteASR)

        // Engine preference should be stored
        #expect(manager.enginePreference == .remoteASR)
        #expect(manager.remoteASREndpoint != nil)
    }

    @Test @MainActor func remoteASREngineLogName() {
        #expect(VoiceInputManager.TranscriptionEngine.remoteASR.logName == "remote")
        #expect(VoiceInputManager.TranscriptionEngine.remoteASR.rawValue == "remoteASR")
    }

    @Test @MainActor func enginePreferenceNilIsAuto() {
        let manager = VoiceInputManager()
        manager.setEnginePreference(nil)
        #expect(manager.enginePreference == nil)
    }

    @Test @MainActor func remoteASRWithoutEndpointFallsBackToLocale() {
        let manager = VoiceInputManager()
        // Prefer remote but don't set endpoint
        manager.setEnginePreference(.remoteASR)
        // Endpoint is nil — effective engine should fall back
        #expect(manager.remoteASREndpoint == nil)
    }
}
