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

    @Test func stalledAnalyzerBackpressureStopsCaptureHeartbeat() throws {
        let (stream, continuation) = AppleOnDeviceVoiceSession.makeAnalyzerInputStream()
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        buffer.frameLength = 1
        let input = AnalyzerInput(buffer: buffer)

        let events = AsyncThrowingStream<VoiceSessionEvent, Error>.makeStream()
        withExtendedLifetime(stream) {
            for _ in 0..<AppleOnDeviceVoiceSession.analyzerInputBufferLimit {
                #expect(AudioEngineHelper.enqueueCaptureInput(input, into: continuation, events: events.continuation))
            }
            #expect(!AudioEngineHelper.enqueueCaptureInput(input, into: continuation, events: events.continuation))
            #expect(!AudioEngineHelper.enqueueCaptureInput(input, into: continuation, events: events.continuation))
        }
    }

    @Test func flushNilConverterYieldsNothing() async {
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        AudioEngineHelper.flushPendingAnalyzerInputs(
            converter: nil,
            targetFormat: nil,
            into: continuation,
            events: AsyncThrowingStream<VoiceSessionEvent, Error>.makeStream().continuation
        )
        continuation.finish()

        var leftoverCount = 0
        for await _ in stream {
            leftoverCount += 1
        }
        #expect(leftoverCount == 0)
    }

    @Test(arguments: [false, true])
    func converterFlushFailureClosesEventsBeforeAnalyzerCanReportSuccess(reportsNSError: Bool) async throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false
        ))
        let converter = try #require(TestFailingFlushConverter(from: format, to: format))
        converter.reportsNSError = reportsNSError
        let inputs = AsyncStream<AnalyzerInput>.makeStream()
        let events = AsyncThrowingStream<VoiceSessionEvent, Error>.makeStream()
        AudioEngineHelper.flushPendingAnalyzerInputs(
            converter: converter, targetFormat: format,
            into: inputs.continuation, events: events.continuation
        )
        #expect(converter.flushCallCount == 1)
        // A normal analyzer completion must not mask the converter's error.
        inputs.continuation.finish()
        events.continuation.finish()
        var failure: Error?
        do {
            for try await _ in events.stream {}
        } catch { failure = error }
        #expect(failure != nil)
        if reportsNSError {
            #expect((failure as NSError?)?.domain == "TestConverterFlush")
            #expect((failure as NSError?)?.code == 42)
        }
        var count = 0
        for await _ in inputs.stream { count += 1 }
        #expect(count == 0, "Failed flush output is never queued as valid tail audio")
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
            into: continuation,
            events: AsyncThrowingStream<VoiceSessionEvent, Error>.makeStream().continuation
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
            into: continuation,
            events: AsyncThrowingStream<VoiceSessionEvent, Error>.makeStream().continuation
        )
        continuation.finish()

        for await _ in stream {}
    }
#endif
}

/// Inject at AVAudioConverter's actual flush boundary, not at the event queue.
final class TestFailingFlushConverter: AVAudioConverter, @unchecked Sendable {
    var reportsNSError = true
    private(set) var flushCallCount = 0

    override func convert(
        to outputBuffer: AVAudioBuffer,
        error outError: NSErrorPointer,
        withInputFrom inputBlock: @escaping AVAudioConverterInputBlock
    ) -> AVAudioConverterOutputStatus {
        flushCallCount += 1
        var status = AVAudioConverterInputStatus.haveData
        #expect(inputBlock(1, &status) == nil)
        #expect(status == .endOfStream)
        if reportsNSError {
            outError?.pointee = NSError(
                domain: "TestConverterFlush", code: 42,
                userInfo: [NSLocalizedDescriptionKey: "Injected converter flush failure"]
            )
        }
        return .error
    }
}
