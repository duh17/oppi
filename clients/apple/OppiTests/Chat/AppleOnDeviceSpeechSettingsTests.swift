import AVFoundation
import Speech
import Testing
@testable import Oppi

@Suite("AppleOnDeviceSpeechSettings")
struct AppleOnDeviceSpeechSettingsTests {
    @Test func speechTranscriberUsesLiveProgressivePreset() {
        let preset = AppleOnDeviceSpeechSettings.speechPreset

        #expect(preset == .progressiveTranscription)
        #expect(preset.reportingOptions.contains(.volatileResults))
        #expect(preset.reportingOptions.contains(.fastResults))
    }

    @Test func dictationFallbackUsesLiveLongPreset() {
        let preset = AppleOnDeviceSpeechSettings.dictationPreset

        #expect(preset == .progressiveLongDictation)
        #expect(preset.reportingOptions.contains(.volatileResults))
        #expect(preset.transcriptionOptions.contains(.punctuation))
        #expect(!preset.contentHints.contains(.shortForm))
        #expect(!preset.reportingOptions.contains(.frequentFinalization))
    }

    @Test func analyzerKeepsModelsForTheProcessLifetime() {
        let options = AppleOnDeviceSpeechSettings.analyzerOptions

        #expect(options.modelRetention == .processLifetime)
        #expect(options.priority == .userInitiated)
    }

    @Test func flushNilConverterYieldsNothing() async {
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        AudioEngineHelper.flushPendingAnalyzerInputs(
            converter: nil,
            targetFormat: nil,
            into: continuation
        )
        continuation.finish()

        var leftoverCount = 0
        for await _ in stream {
            leftoverCount += 1
        }
        #expect(leftoverCount == 0)
    }

    @Test func flushPendingAnalyzerInputsFinishesWithoutHanging() async throws {
        if #available(iOS 27, *) {
            // iOS 27 AnalyzerInput rejects float PCM; the Speech converter covers flush there.
            return
        }
        let inputFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let targetFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let converter = try #require(AVAudioConverter(from: inputFormat, to: targetFormat))
        let inputBuffer = try #require(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 2_048))
        inputBuffer.frameLength = 2_048

        let convertedCapacity = AVAudioFrameCount(
            Double(inputBuffer.frameLength) * targetFormat.sampleRate / inputFormat.sampleRate + 64
        )
        let converted = try #require(
            AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: convertedCapacity)
        )
        var conversionError: NSError?
        converter.convert(to: converted, error: &conversionError) { _, status in
            status.pointee = .haveData
            return inputBuffer
        }
        #expect(conversionError == nil)

        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        AudioEngineHelper.flushPendingAnalyzerInputs(
            converter: converter,
            targetFormat: targetFormat,
            into: continuation
        )
        continuation.finish()

        for await _ in stream {}
    }

#if compiler(>=6.4)
    @Test func analyzerInputConverterFlushFinishesWithoutHanging() async throws {
        guard #available(iOS 27, *) else { return }

        let inputFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let targetFormat = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16_000,
                channels: 1,
                interleaved: true
            )
        )
        let converter = AnalyzerInputConverter(analyzerFormat: targetFormat)
        let inputBuffer = try #require(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 2_048))
        inputBuffer.frameLength = 2_048
        _ = try converter.convert(inputBuffer, at: nil)

        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        AudioEngineHelper.flushPendingAnalyzerInputs(
            converter: converter,
            into: continuation
        )
        continuation.finish()

        for await _ in stream {}
    }
#endif
}
