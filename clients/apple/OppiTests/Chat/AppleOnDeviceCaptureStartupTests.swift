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

    @Test func queueFailureBeforeStopStillCancelsStalledAnalyzerAndReleasesCapture() async throws {
        let session = makeSession()
        let inputs = session._testInstallAnalyzerInputStream()
        let delayed = DelayedAppleSessionEvents(session)
        let finalizer = AsyncGate()
        let releaseCancellation = AsyncGate()
        var finalizations = 0
        var cancellations = 0
        session._testFinalizeAnalyzer = {
            finalizations += 1
            await finalizer.wait() // Speech never finishes unless it is cancelled.
        }
        session._testCancelAnalyzer = {
            cancellations += 1
            await releaseCancellation.wait()
            await finalizer.open()
        }
        let provider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        provider.makeSessionHandler = { _, _ in delayed }
        let access = MockVoiceInputSystemAccess()
        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [provider]), systemAccess: access
        )
        manager.setEngineMode(.onDevice)
        var draft = "earlier draft"
        var rollbacks = 0
        try await manager.startRecording(keyboardLanguage: "en-US", source: "test", onCaptureFailure: {
            draft = "earlier draft"
            rollbacks += 1
        })
        draft += " incomplete take"
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: false
        ))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024))
        pcm.frameLength = 1_024
        var accepted = 0
        for _ in 0..<422 { if inputs.enqueue(AnalyzerInput(buffer: pcm)) { accepted += 1 } }
        #expect(accepted >= 374 && accepted <= 375)
        // The queue's one-shot MainActor callback MUST finish before Stop.
        // Only event delivery is withheld; cancellation ownership is real.
        #expect(await waitForMainActorCondition { session._testInputFailureHandled })
        #expect(manager.isRecording && manager.captureFailure == nil)
        #expect(cancellations == 0, "Recording cancellation still belongs to the manager")
        #expect(!inputs.checkDeadline(), "The failed queue has no deadline left to rescue Stop")

        var returned = false
        let stop = Task {
            let text = await manager.stopRecording()
            returned = true
            return text
        }
        #expect(await waitForMainActorCondition { finalizations + cancellations > 0 })
        #expect(manager.state == .processing)
        await delayed.deliverError.open()
        #expect(await waitForMainActorCondition { manager.captureFailure != nil })
        #expect(manager.ownsCaptureAudioSession, "Stop must retain ownership until cancellation finishes")
        #expect(access.deactivateAudioSessionCallCount == 0)
        #expect(delayed.cancelCalls == 0, "The processing error consumer must not compete with Stop")
        #expect(draft == "earlier draft" && rollbacks == 1)
        await releaseCancellation.open()
        let didReturn = await waitForMainActorCondition { returned }
        print("Stop handoff evidence: terminal_error=\(manager.captureFailure != nil) analyzer_cancellations=\(cancellations) stop_returned=\(didReturn) capture_owned=\(manager.ownsCaptureAudioSession)")
        #expect(cancellations == 1)
        #expect(didReturn, "An already-fired input failure must cancel, not strand ordinary finalization")
        #expect(!manager.ownsCaptureAudioSession)
        // Red-run cleanup is deliberately AFTER the liveness assertions; it
        // cannot make a stranded Stop look green or hang the test runner.
        if !didReturn { await finalizer.open() }
        #expect(await stop.value == "")
        #expect(access.deactivateAudioSessionCallCount == 1)
        #expect(!manager._testOperationInFlight)
        await session.stop()
        await session.cancel()
        #expect(cancellations == 1, "Late Stop/cancel cannot cancel the analyzer twice")
        let retry = MockVoiceSession()
        provider.makeSessionHandler = { _, _ in retry }
        try await manager.startRecording(keyboardLanguage: "en-US", source: "retry")
        #expect(manager.isRecording && manager.captureFailure == nil)
        await manager.cancelRecording()
    }

    @Test func queueFailureWhileStopAwaitsResultsRetainsCaptureUntilCancellationCompletes() async throws {
        let session = makeSession()
        let inputs = session._testInstallAnalyzerInputStream()
        _ = try makeQueuedPCM(inputs)
        let delayed = DelayedAppleSessionEvents(session)
        let deliverCallback = AsyncGate()
        let releaseResults = AsyncGate()
        let releaseCancellation = AsyncGate()
        var cancellations = 0
        var cancellationCompleted = false
        session._testBeforeInputFailure = { await deliverCallback.wait() }
        session._testFinalizeAnalyzer = {
            // Input closure lets ordinary finalization return, while MainActor
            // has not yet delivered the queue's separately scheduled callback.
            inputs.fail(VoiceInputError.captureBufferOverflow)
        }
        session._testCancelAnalyzer = {
            cancellations += 1
            await releaseCancellation.wait()
            cancellationCompleted = true
        }
        session._testInstallResultsTask(Task { await releaseResults.wait() })
        let provider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        provider.makeSessionHandler = { _, _ in delayed }
        let access = MockVoiceInputSystemAccess()
        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [provider]), systemAccess: access
        )
        manager.setEngineMode(.onDevice)
        try await manager.startRecording(keyboardLanguage: "en-US", source: "test")
        var returned = false
        let stop = Task { let text = await manager.stopRecording(); returned = true; return text }
        #expect(await waitForMainActorCondition { session._testStopPhase == .waitingForResults })
        #expect(cancellations == 0 && !session._testInputFailureHandled)
        #expect(manager.state == .processing && manager.ownsCaptureAudioSession)
        await delayed.deliverError.open()
        #expect(await waitForMainActorCondition { manager.captureFailure != nil })
        // Only now can cancellation be published: v2 Stop already passed its
        // initially empty cancellation check and is suspended on real resultsTask.
        await deliverCallback.open()
        #expect(await waitForMainActorCondition { cancellations == 1 })
        await releaseResults.open()
        #expect(await waitForMainActorCondition {
            session._testStopPhase == .finishedResults || session._testStopPhase == .cleanedUp
        })
        // These phases are observed on MainActor. v2 has no suspension between
        // finishing results and cleanup; v3 must instead suspend on cancellation.
        let cleanedUpEarly = session._testStopPhase == .cleanedUp
        if cleanedUpEarly { #expect(await waitForMainActorCondition { returned }) }
        print("Stop results evidence: cancellations=\(cancellations) cancellation_completed=\(cancellationCompleted) cleaned_up=\(cleanedUpEarly) stop_returned=\(returned) capture_owned=\(manager.ownsCaptureAudioSession)")
        #expect(!cleanedUpEarly, "Session cleanup must join cancellation started during the results wait")
        #expect(!returned && manager.ownsCaptureAudioSession)
        #expect(access.deactivateAudioSessionCallCount == 0 && manager._testOperationInFlight)
        #expect(!cancellationCompleted && cancellations == 1 && delayed.cancelCalls == 0)
        inputs.fail(VoiceInputError.captureBufferOverflow)
        await session.stop()
        await session.cancel()
        #expect(cancellations == 1)
        // Always release the gate AFTER ownership assertions, including on red.
        await releaseCancellation.open()
        #expect(await waitForMainActorCondition { returned && session._testInputFailureHandled })
        #expect(await stop.value == "")
        #expect(cancellationCompleted && cancellations == 1)
        #expect(!manager.ownsCaptureAudioSession && !manager._testOperationInFlight)
        #expect(access.deactivateAudioSessionCallCount == 1)
        await session.stop()
        await session.cancel()
        #expect(cancellations == 1)
    }

    @Test func queueFailureCallbackAfterCompletedStopCannotStartLateCancellation() async throws {
        let session = makeSession()
        let inputs = session._testInstallAnalyzerInputStream()
        _ = try makeQueuedPCM(inputs)
        let deliverCallback = AsyncGate()
        var cancellations = 0
        session._testBeforeInputFailure = { await deliverCallback.wait() }
        session._testFinalizeAnalyzer = { inputs.fail(VoiceInputError.captureBufferOverflow) }
        session._testCancelAnalyzer = { cancellations += 1 }
        session._testInstallResultsTask(Task {})
        await session.stop()
        #expect(session._testStopPhase == .cleanedUp)
        #expect(cancellations == 0 && !session._testInputFailureHandled)
        // MainActor closes isFinalizing synchronously after the last nil join.
        // A callback not yet delivered must not create new work after cleanup.
        await deliverCallback.open()
        #expect(await waitForMainActorCondition { session._testInputFailureHandled })
        await session.stop()
        await session.cancel()
        #expect(cancellations == 0)
        var failure: Error?
        do { for try await _ in session.events {} } catch { failure = error }
        #expect(failure is VoiceInputError, "Late callback delivery must not erase the failed take")
    }

    @Test(arguments: [false, true])
    func queueDeadlineDuringStopWaitsForExactlyOneCancellation(finalizerReturnsFirst: Bool) async throws {
        let session = makeSession()
        let clock = AnalyzerBufferTestClock()
        let inputs = session._testInstallAnalyzerInputStream(now: { clock.now })
        let pcm = try makeQueuedPCM(inputs)
        let finalizer = AsyncGate()
        let releaseCancellation = AsyncGate()
        var finalizing = false
        var finalized = false
        var cancellations = 0
        session._testFinalizeAnalyzer = {
            finalizing = true
            await finalizer.wait()
            finalized = true
        }
        session._testCancelAnalyzer = {
            cancellations += 1
            if finalizerReturnsFirst { await finalizer.open() }
            await releaseCancellation.wait()
            await finalizer.open()
        }
        var returned = false
        let stop = Task { await session.stop(); returned = true }
        #expect(await waitForMainActorCondition { finalizing })
        // No producer/dequeue calls after Stop. Drive the actual oldest-input
        // deadline while ordinary Speech finalization is already suspended.
        clock.advance(.seconds(8))
        #expect(!inputs.checkDeadline())
        #expect(await waitForMainActorCondition { cancellations == 1 })
        if finalizerReturnsFirst {
            #expect(await waitForMainActorCondition { finalized })
        }
        #expect(!returned, "Finalization returning cannot release an unfinished cancellation")
        #expect(!inputs.checkDeadline())
        #expect(!inputs.enqueue(AnalyzerInput(buffer: pcm)))
        inputs.fail(VoiceInputError.captureBufferOverflow) // duplicate failure stays one-shot
        await session.cancel()
        await session.stop()
        #expect(cancellations == 1)
        await releaseCancellation.open()
        let didReturn = await waitForMainActorCondition { returned }
        #expect(didReturn)
        if !didReturn { await finalizer.open() }
        await stop.value
        #expect(cancellations == 1)
        #expect(await waitForMainActorCondition { session._testInputFailureHandled })
        var failure: Error?
        do { for try await _ in session.events {} } catch { failure = error }
        #expect(failure is VoiceInputError)
    }

    @Test(arguments: [false, true])
    func recordingQueueFailureKeepsManagerCancellationOwnership(callbackBeforeError: Bool) async throws {
        let session = makeSession()
        let inputs = session._testInstallAnalyzerInputStream()
        let delayed = DelayedAppleSessionEvents(session)
        let releaseCancellation = AsyncGate()
        var cancellations = 0
        var finalizations = 0
        session._testCancelAnalyzer = { cancellations += 1; await releaseCancellation.wait() }
        session._testFinalizeAnalyzer = { finalizations += 1 }
        let provider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        provider.makeSessionHandler = { _, _ in delayed }
        let access = MockVoiceInputSystemAccess()
        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [provider]), systemAccess: access
        )
        manager.setEngineMode(.onDevice)
        try await manager.startRecording(keyboardLanguage: "en-US", source: "test")
        inputs.fail(VoiceInputError.captureBufferOverflow)
        if callbackBeforeError {
            #expect(await waitForMainActorCondition { session._testInputFailureHandled })
            #expect(cancellations == 0 && manager.isRecording)
        } else {
            // Retire recording before the queued MainActor failure callback can
            // run. Its late arrival must not start a second analyzer cancellation.
            let release = Task {
                #expect(await waitForMainActorCondition { cancellations == 1 })
                await delayed.deliverError.open()
                await releaseCancellation.open()
            }
            await manager.cancelRecording()
            await release.value
        }
        await delayed.deliverError.open()
        #expect(await waitForMainActorCondition { cancellations == 1 })
        if callbackBeforeError {
            #expect(manager.captureFailure != nil)
            #expect(manager.ownsCaptureAudioSession)
            #expect(await manager.stopRecording() == "")
            await manager.cancelRecording()
            #expect(cancellations == 1)
            await releaseCancellation.open()
        }
        #expect(await waitForMainActorCondition { !manager.ownsCaptureAudioSession })
        #expect(await waitForMainActorCondition { session._testInputFailureHandled })
        #expect(delayed.cancelCalls == 1 && cancellations == 1 && finalizations == 0)
        #expect(access.deactivateAudioSessionCallCount == 1)
    }

    @Test func ordinaryStopDrainsQueuedAudioWithoutCancellingAnalyzer() async throws {
        let session = makeSession()
        let inputs = session._testInstallAnalyzerInputStream()
        _ = try makeQueuedPCM(inputs)
        var drained = 0
        var cancellations = 0
        session._testFinalizeAnalyzer = {
            for await _ in inputs { drained += 1 }
            session._testFinishAnalyzerResults()
        }
        session._testCancelAnalyzer = { cancellations += 1 }
        await session.stop()
        await session.cancel()
        #expect(drained == 1 && cancellations == 0)
        #expect(!inputs.checkDeadline())
        do { for try await _ in session.events {} }
        catch { Issue.record("Ordinary Stop must remain successful: \(error)") }
    }

    private func makeQueuedPCM(_ inputs: AnalyzerInputBuffer) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: false
        ))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024))
        pcm.frameLength = 1_024
        #expect(inputs.enqueue(AnalyzerInput(buffer: pcm)))
        return pcm
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
        #expect(!analyzerInput.enqueue(AnalyzerInput(buffer: buffer)),
                "Stop during rebuild backoff must close analyzer input")
    }

    @Test(arguments: [16_000.0, 24_000.0, 48_000.0])
    func transientAnalyzerBackpressurePreservesEveryBufferWhenConsumptionResumes(sampleRate: Double) async throws {
        let session = makeSession()
        let input = session._testInstallAnalyzerInputStream()
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: false
        ))
        // 2–6 seconds of tap-sized PCM. At 48kHz the old bound fails at 171ms.
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024))
        buffer.frameLength = 1_024
        var accepted = 0
        for index in 0..<96 {
            buffer.int16ChannelData?[0][0] = Int16(index)
            if session._testEnqueueAnalyzerInput(AnalyzerInput(buffer: buffer)) { accepted += 1 }
        }
        #expect(accepted == 96)
        var iterator = input.makeAsyncIterator()
        var received: [Int16] = []
        // Drain only the accepted count so the old implementation fails, not hangs.
        for _ in 0..<accepted {
            if let next = await iterator.next() {
                let pcm = next.buffer
                withExtendedLifetime(pcm) {
                    if let samples = pcm.int16ChannelData { received.append(samples[0][0]) }
                }
            }
        }
        #expect(received == (0..<96).map(Int16.init), "Queued PCM must own its bytes, not a recycled tap buffer")
        #expect(session._testEnqueueAnalyzerInput(AnalyzerInput(buffer: buffer)))
        await session.stop()
        session._testFinishAnalyzerResults()
        do { for try await _ in session.events {} }
        catch { Issue.record("Recovered pressure must not fail the take: \(error)") }
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
        for await _ in input { delivered += 1 }
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
        for await _ in input { delivered += 1 }
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

/// Delays only the real session's error delivery, never its queue callback or
/// Stop/cancel logic. Hardware startup is the sole lifecycle replacement.
@MainActor
private final class DelayedAppleSessionEvents: VoiceTranscriptionSession {
    let session: AppleOnDeviceVoiceSession
    let events: AsyncThrowingStream<VoiceSessionEvent, Error>
    var audioLevels: AsyncStream<Float> { session.audioLevels }
    let deliverError = AsyncGate()
    private(set) var cancelCalls = 0

    init(_ session: AppleOnDeviceVoiceSession) {
        self.session = session
        let pair = AsyncThrowingStream<VoiceSessionEvent, Error>.makeStream()
        events = pair.stream
        Task { [deliverError] in
            do {
                for try await event in session.events { pair.continuation.yield(event) }
                pair.continuation.finish()
            } catch {
                await deliverError.wait()
                pair.continuation.finish(throwing: error)
            }
        }
    }

    func start() async throws -> VoiceSessionStartTimings {
        let capture = FakeOnDeviceCapture()
        try await session.startAudioCapture(makeCapture: { capture }, sleep: { _ in
            capture.continuation.yield(0)
            await Task.yield()
        })
        return VoiceSessionStartTimings(analyzerStartMs: 0, audioStartMs: 0)
    }
    func rebuildAudioCapture() async throws { try await session.rebuildAudioCapture() }
    func stop() async { await session.stop() }
    func cancel() async { cancelCalls += 1; await session.cancel() }
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
