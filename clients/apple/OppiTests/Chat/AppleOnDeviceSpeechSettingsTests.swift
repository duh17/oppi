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

    @Test func sustainedAnalyzerBackpressureIsBoundedAndCannotRevive() async throws {
        let events = AsyncThrowingStream<VoiceSessionEvent, Error>.makeStream()
        let inputs = AnalyzerInputBuffer(events: events.continuation)
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: false
        ))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024))
        buffer.frameLength = 1_024
        var accepted = 0
        // Nine seconds without consumption: eight seconds are recoverable;
        // the next input fails closed, clears retained audio and ends heartbeat.
        for _ in 0..<422 {
            if inputs.enqueue(AnalyzerInput(buffer: buffer)) { accepted += 1 }
        }
        #expect(accepted >= 374 && accepted <= 375)
        var iterator = inputs.makeAsyncIterator()
        #expect(await iterator.next() == nil)
        #expect(!inputs.enqueue(AnalyzerInput(buffer: buffer)))
        events.continuation.finish() // successful analyzer completion cannot win
        var failure: Error?
        do { for try await _ in events.stream {} }
        catch { failure = error }
        #expect(VoiceInputTelemetry.metricErrorKind(for: try #require(failure)) == "capture_buffer_overflow")
        #expect(failure?.localizedDescription == "Dictation couldn’t continue. Please try again.")
    }

    @Test(arguments: ["age", "bytes", "count"])
    func independentBackpressureBoundsFailClosed(bound: String) async throws {
        let clock = AnalyzerBufferTestClock()
        let events = AsyncThrowingStream<VoiceSessionEvent, Error>.makeStream()
        // Lower only the byte budget to isolate its admission check with real
        // supported mono PCM; the default hard ceiling remains 4 MiB.
        let inputs = AnalyzerInputBuffer(
            events: events.continuation,
            byteLimit: bound == "bytes" ? 4_096 : AnalyzerInputBuffer.maxBytes,
            now: { clock.now }
        )
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 48_000,
            channels: 1, interleaved: false
        ))
        let frames: AVAudioFrameCount = bound == "bytes" ? 1_024 : 1
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        pcm.frameLength = frames
        #expect(inputs.enqueue(AnalyzerInput(buffer: pcm)))
        if bound == "age" {
            clock.advance(.seconds(8))
            #expect(!inputs.enqueue(AnalyzerInput(buffer: pcm)))
        } else {
            let acceptedTotal = bound == "bytes" ? 2 : AnalyzerInputBuffer.maxBuffers
            for _ in 1..<acceptedTotal { #expect(inputs.enqueue(AnalyzerInput(buffer: pcm))) }
            #expect(!inputs.enqueue(AnalyzerInput(buffer: pcm)))
        }
        var iterator = inputs.makeAsyncIterator()
        #expect(await iterator.next() == nil)
        var failure: Error?
        do { for try await _ in events.stream {} } catch { failure = error }
        #expect(failure is VoiceInputError)
    }

    @Test func transientPressureReportsRecoveryWithoutErrorAndDrainsOnStop() async throws {
        let diagnostics = AnalyzerPressureTestLog()
        let events = AsyncThrowingStream<VoiceSessionEvent, Error>.makeStream()
        let inputs = AnalyzerInputBuffer(events: events.continuation, diagnostic: { diagnostics.append($0) })
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false
        ))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024))
        pcm.frameLength = 1_024
        for _ in 0..<32 { #expect(inputs.enqueue(AnalyzerInput(buffer: pcm))) }
        inputs.finish()
        var count = 0
        for await _ in inputs { count += 1 }
        #expect(count == 32)
        #expect(diagnostics.records.map { $0["status"] } == ["buffering", "recovered"])
        #expect(diagnostics.records.last?["recoveries"] == "1")
        #expect(diagnostics.records.last?["peak_buffered_ms"] == "2048")
        events.continuation.finish()
        do { for try await _ in events.stream {} }
        catch { Issue.record("Transient pressure is not a capture failure: \(error)") }
    }

    @Test func stoppedInputWithStuckConsumerExpiresWithoutAnotherTapAndCancelsAnalyzerOnce() async throws {
        let clock = AnalyzerBufferTestClock()
        let failures = AnalyzerPressureTestLog()
        let events = AsyncThrowingStream<VoiceSessionEvent, Error>.makeStream()
        let inputs = AnalyzerInputBuffer(
            events: events.continuation, onFailure: { failures.append(["cancel": "analyzer"]) },
            now: { clock.now }
        )
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: false
        ))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024))
        pcm.frameLength = 1_024
        #expect(inputs.enqueue(AnalyzerInput(buffer: pcm)))
        inputs.finish() // no more tap or iterator.next() calls will arrive
        clock.advance(.milliseconds(7_999))
        #expect(inputs.checkDeadline())
        #expect(failures.records.isEmpty)
        clock.advance(.milliseconds(1))
        #expect(!inputs.checkDeadline())
        #expect(!inputs.checkDeadline())
        #expect(failures.records == [["cancel": "analyzer"]])
        events.continuation.finish()
        var failure: Error?
        do { for try await _ in events.stream {} } catch { failure = error }
        #expect(failure is VoiceInputError)
    }

    @Test func cancelWakesWaitingConsumerAndRejectsLateProducer() async throws {
        let events = AsyncThrowingStream<VoiceSessionEvent, Error>.makeStream()
        let inputs = AnalyzerInputBuffer(events: events.continuation)
        let task = Task {
            var iterator = inputs.makeAsyncIterator()
            return await iterator.next()
        }
        task.cancel()
        #expect(await task.value == nil)
        var iterator = inputs.makeAsyncIterator()
        #expect(await iterator.next() == nil)
        events.continuation.finish()
    }

    @Test func flushNilConverterYieldsNothing() async {
        let events = AsyncThrowingStream<VoiceSessionEvent, Error>.makeStream()
        let stream = AnalyzerInputBuffer(events: events.continuation)
        AudioEngineHelper.flushPendingAnalyzerInputs(
            converter: nil, targetFormat: nil, into: stream, events: events.continuation
        )
        stream.finish()

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
        let events = AsyncThrowingStream<VoiceSessionEvent, Error>.makeStream()
        let inputs = AnalyzerInputBuffer(events: events.continuation)
        AudioEngineHelper.flushPendingAnalyzerInputs(
            converter: converter, targetFormat: format,
            into: inputs, events: events.continuation
        )
        #expect(converter.flushCallCount == 1)
        // A normal analyzer completion must not mask the converter's error.
        inputs.finish()
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
        for await _ in inputs { count += 1 }
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

        let events = AsyncThrowingStream<VoiceSessionEvent, Error>.makeStream()
        let stream = AnalyzerInputBuffer(events: events.continuation)
        AudioEngineHelper.flushPendingAnalyzerInputs(
            converter: converter, targetFormat: targetFormat,
            into: stream, events: events.continuation
        )
        stream.finish()

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

        let events = AsyncThrowingStream<VoiceSessionEvent, Error>.makeStream()
        let stream = AnalyzerInputBuffer(events: events.continuation)
        AudioEngineHelper.flushPendingAnalyzerInputs(
            converter: converter, into: stream, events: events.continuation
        )
        stream.finish()

        for await _ in stream {}
    }
#endif
}

@Suite("Apple preparation cache")
@MainActor
struct AppleOnDevicePreparationTests {
    @Test func warmActivationSkipsLocaleInventoryAndFormatWork() async throws {
        var resolutions = 0
        var preparations = 0
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false
        ))
        let provider = AppleOnDeviceVoiceProvider(engine: .modernSpeech, resolveLocale: { _, _ in
            resolutions += 1
            return Locale(identifier: "en-US")
        }, prepareModel: { _, _ in
            preparations += 1
            return format
        })
        let context = VoiceProviderContext(locale: Locale(identifier: "en-GB"), source: "test")
        let cold = try await provider.prepareSession(context: context)
        #expect(cold.pathTag == "cold")
        provider.cancelPreparation() // cancelling a completed take must retain readiness
        let warm = try await provider.prepareSession(context: context)
        #expect(warm.pathTag == "warm_cache")
        #expect(warm.audioFormat == format)
        #expect(warm.transcriptionLocale?.identifier(.bcp47) == "en-US")
        #expect(resolutions == 1 && preparations == 1)
        provider.invalidateCache()
        #expect(try await provider.prepareSession(context: context).pathTag == "cold")
        #expect(resolutions == 2 && preparations == 2)
    }

    @Test func prewarmAndLocaleSwitchUseOnlyMatchingPreparation() async throws {
        var locales: [String] = []
        let provider = AppleOnDeviceVoiceProvider(engine: .classicDictation, resolveLocale: { _, locale in
            locale
        }, prepareModel: { _, locale in
            locales.append(locale.identifier(.bcp47))
            return nil
        })
        let english = VoiceProviderContext(locale: Locale(identifier: "en-US"), source: "test")
        let chinese = VoiceProviderContext(locale: Locale(identifier: "zh-CN"), source: "test")
        try await provider.prewarm(context: english)
        #expect(try await provider.prepareSession(context: english).pathTag == "warm_cache")
        #expect(try await provider.prepareSession(context: chinese).pathTag == "cold")
        #expect(locales == ["en-US", "zh-CN"])
    }

    @Test func cancelledSameLocalePreparationCannotRetireOrPopulateItsReplacement() async throws {
        let oldGate = AsyncGate()
        let newGate = AsyncGate()
        var calls = 0
        let provider = AppleOnDeviceVoiceProvider(engine: .modernSpeech, resolveLocale: { _, locale in locale },
            prepareModel: { _, _ in
                calls += 1
                if calls == 1 { await oldGate.wait() } else { await newGate.wait() }
                return nil // simulate a Speech operation that ignores cancellation
            })
        let context = VoiceProviderContext(locale: Locale(identifier: "en-US"), source: "test")
        let old = Task { try await provider.prepareSession(context: context) }
        #expect(await waitForMainActorCondition { calls == 1 })
        provider.cancelPreparation()
        let replacement = Task { try await provider.prepareSession(context: context) }
        #expect(await waitForMainActorCondition { calls == 2 })
        await oldGate.open()
        await #expect(throws: CancellationError.self) { try await old.value }
        #expect(!provider._testModelReady)
        await newGate.open()
        #expect(try await replacement.value.pathTag == "cold")
        #expect(try await provider.prepareSession(context: context).pathTag == "warm_cache")
        #expect(calls == 2)
    }
}

final class AnalyzerBufferTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    var now: ContinuousClock.Instant { lock.withLock { instant } }
    func advance(_ duration: Duration) { lock.withLock { instant = instant.advanced(by: duration) } }
}

private final class AnalyzerPressureTestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [[String: String]] = []
    var records: [[String: String]] { lock.withLock { entries } }
    func append(_ entry: [String: String]) { lock.withLock { entries.append(entry) } }
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
