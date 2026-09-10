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
