import AVFoundation
import Foundation
import Speech
import Testing
@testable import Oppi

@Suite("On-device first-PCM startup")
@MainActor
struct AppleOnDeviceCaptureStartupTests {
    private func makeSession() -> AppleOnDeviceVoiceSession {
        AppleOnDeviceVoiceSession(
            transcriber: .dictation(DictationTranscriber(locale: Locale(identifier: "en-US"), preset: .progressiveLongDictation)),
            preferredAudioFormat: nil,
            contextualStrings: []
        )
    }

    @Test func runningEngineWithoutPCMNeverReportsReady() async {
        let session = makeSession()
        var captures: [FakeOnDeviceCapture] = []
        await #expect(throws: VoiceInputError.self) {
            try await session.startAudioCapture(makeCapture: {
                let capture = FakeOnDeviceCapture()
                captures.append(capture)
                return capture
            }, sleep: { _ in })
        }
        #expect(captures.count == 2)
        #expect(captures.allSatisfy { $0.stopCount == 1 })
        #expect(captures.allSatisfy { $0.finishCount == 0 })
        await session.cancel()
    }

    @Test func readinessWaitsForLiveSilentPCM() async throws {
        let session = makeSession()
        let capture = FakeOnDeviceCapture()
        var waits = 0
        try await session.startAudioCapture(makeCapture: { capture }, sleep: { _ in
            waits += 1
            capture.continuation.yield(0) // Silence is live audio, not a missing tap.
            await Task.yield()
        })
        #expect(waits > 0)
        #expect(capture.stopCount == 0)
        await session.cancel()
        #expect(capture.finishCount == 1)
    }

    @Test func stoppedEngineRetriesWithoutClosingAnalyzerInput() async throws {
        let session = makeSession()
        let stopped = FakeOnDeviceCapture(isRunning: false)
        let live = FakeOnDeviceCapture()
        var starts = 0
        try await session.startAudioCapture(makeCapture: {
            starts += 1
            return starts == 1 ? stopped : live
        }, sleep: { _ in
            live.continuation.yield(0.2)
            await Task.yield()
        })
        #expect(starts == 2)
        #expect(stopped.stopCount == 1)
        #expect(stopped.finishCount == 0)
        await session.cancel()
        #expect(live.finishCount == 1)
    }

    @Test func rebuildAudioCaptureRestartsEngineWithoutFinishingSession() async throws {
        let session = makeSession()
        let first = FakeOnDeviceCapture()
        try await session.startAudioCapture(makeCapture: { first }, sleep: { _ in
            first.continuation.yield(0.1)
            await Task.yield()
        })
        // rebuildAudioCapture uses AudioEngineHelper, which needs a real input.
        // Prove the session refuses rebuild after cancel rather than staying live.
        await session.cancel()
        await #expect(throws: VoiceInputError.self) {
            try await session.rebuildAudioCapture()
        }
        #expect(first.finishCount == 1)
    }

    @Test func stopDuringRebuildBackoffClosesAnalyzerInputAndDoesNotRetry() async throws {
        let session = makeSession()
        let analyzerInput = session._testInstallAnalyzerInputStream()
        let stopped = FakeOnDeviceCapture(isRunning: false)
        var starts = 0

        await #expect(throws: CancellationError.self) {
            try await session.startAudioCapture(makeCapture: {
                starts += 1
                return stopped
            }, sleep: { _ in
                await session.stop()
            })
        }

        #expect(starts == 1)
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        buffer.frameLength = 1
        withExtendedLifetime(analyzerInput.stream) {
            if case .terminated = analyzerInput.continuation.yield(AnalyzerInput(buffer: buffer)) {} else {
                Issue.record("Stop during rebuild backoff left analyzer input open")
            }
        }
    }

    @Test func transientAnalyzerOverflowFailsTakeEvenWhenConsumptionResumes() async throws {
        let session = makeSession()
        let input = session._testInstallAnalyzerInputStream()
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false
        ))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        buffer.frameLength = 1
        for _ in 0..<AppleOnDeviceVoiceSession.analyzerInputBufferLimit {
            #expect(session._testEnqueueAnalyzerInput(AnalyzerInput(buffer: buffer)))
        }
        #expect(!session._testEnqueueAnalyzerInput(AnalyzerInput(buffer: buffer)))
        var iterator = input.stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(!session._testEnqueueAnalyzerInput(AnalyzerInput(buffer: buffer)))
        await session.cancel()
        var failure: Error?
        do {
            for try await _ in session.events {}
        } catch { failure = error }
        #expect(failure?.localizedDescription == "Dictation audio buffer overflow. Please try again.")
    }

    @Test(arguments: TestOrdinaryConversionFailure.allCases, [false, true])
    func ordinaryConversionFailureCannotRecoverOrBecomeSuccessfulStop(
        failureKind: TestOrdinaryConversionFailure, feedAfterFailure: Bool
    ) async throws {
        let session = makeSession()
        let input = session._testInstallAnalyzerInputStream()
        let source = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let target = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false
        ))
        let converter = try #require(TestOrdinaryConverter(from: source, to: target))
        converter.failure = failureKind
        var failAllocation = failureKind == .allocation
        let feed = try session._testMakeLegacyFeed(converter: converter) { format, capacity in
            failAllocation ? nil : AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)
        }
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 128))
        buffer.frameLength = 128
        #expect(!feed.feed(buffer, at: nil))
        // A healthy next buffer must never revive a take with missing speech.
        converter.failure = nil
        failAllocation = false
        if feedAfterFailure { #expect(!feed.feed(buffer, at: nil)) }
        await session.stop()
        session._testFinishAnalyzerResults()
        var failure: Error?
        do { for try await _ in session.events {} }
        catch { failure = error }
        #expect(failure != nil, "Stop cannot turn dropped ordinary audio into a successful take")
        if failureKind == .nsError {
            #expect((failure as NSError?)?.domain == "TestOrdinaryConverter")
        }
        var delivered = 0
        for await _ in input.stream { delivered += 1 }
        #expect(delivered == 0)
    }

    @Test func bufferedConversionWithoutOutputCanDeliverTheNextBuffer() async throws {
        let session = makeSession()
        let input = session._testInstallAnalyzerInputStream()
        let source = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let target = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false
        ))
        let converter = try #require(TestOrdinaryConverter(from: source, to: target))
        converter.buffered = true
        let feed = try session._testMakeLegacyFeed(converter: converter) {
            AVAudioPCMBuffer(pcmFormat: $0, frameCapacity: $1)
        }
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 128))
        buffer.frameLength = 128
        #expect(!feed.feed(buffer, at: nil))
        converter.buffered = false
        #expect(feed.feed(buffer, at: nil))
        await session.stop()
        session._testFinishAnalyzerResults()
        do { for try await _ in session.events {} }
        catch { Issue.record("Buffered/no-output is not a converter failure: \(error)") }
        var delivered = 0
        for await _ in input.stream { delivered += 1 }
        #expect(delivered == 1)
    }

    @Test func cancelDuringReadinessCannotReportSuccessOrRestart() async {
        let session = makeSession()
        let capture = FakeOnDeviceCapture()
        var starts = 0
        await #expect(throws: CancellationError.self) {
            try await session.startAudioCapture(makeCapture: {
                starts += 1
                return capture
            }, sleep: { _ in await session.cancel() })
        }
        #expect(starts == 1)
        #expect(capture.finishCount == 1)
    }
}

enum TestOrdinaryConversionFailure: CaseIterable, Sendable {
    case nsError, errorStatus, allocation
}

/// Inject failures at the ordinary AVAudioConverter call, including `.error`
/// without NSError and an NSError even when the status/output look successful.
final class TestOrdinaryConverter: AVAudioConverter, @unchecked Sendable {
    var failure: TestOrdinaryConversionFailure?
    var buffered = false

    override func convert(
        to outputBuffer: AVAudioBuffer,
        error outError: NSErrorPointer,
        withInputFrom inputBlock: @escaping AVAudioConverterInputBlock
    ) -> AVAudioConverterOutputStatus {
        var status = AVAudioConverterInputStatus.noDataNow
        _ = inputBlock(128, &status)
        #expect(status == .haveData)
        (outputBuffer as? AVAudioPCMBuffer)?.frameLength = buffered ? 0 : 1
        if failure == .nsError {
            outError?.pointee = NSError(domain: "TestOrdinaryConverter", code: 42)
        }
        if failure == .errorStatus { return .error }
        return buffered ? .inputRanDry : .haveData
    }
}

private final class FakeOnDeviceCapture: OnDeviceAudioCapture {
    let audioLevels: AsyncStream<Float>
    let continuation: AsyncStream<Float>.Continuation
    var isRunning: Bool
    var stopCount = 0
    var finishCount = 0

    init(isRunning: Bool = true) {
        self.isRunning = isRunning
        (audioLevels, continuation) = AsyncStream.makeStream(of: Float.self)
    }

    func stop() {
        stopCount += 1
        isRunning = false
        continuation.finish()
    }

    func stopAndFinishInput(flush: Bool) {
        stop()
        finishCount += 1
    }
}
