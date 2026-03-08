import Foundation
import Testing
@testable import Oppi

@Suite("VoiceInputSessionMonitor")
@MainActor
struct VoiceInputSessionMonitorTests {
    @Test func bindForwardsAudioLevelsAndEvents() async {
        let session = TestVoiceSession()
        let monitor = VoiceInputSessionMonitor()

        var receivedLevels: [Float] = []
        var receivedEvents: [VoiceSessionEvent] = []
        var firstTranscript: (Int, String)?

        monitor.bind(
            session: session,
            recordingStartTime: .now,
            onAudioLevel: { receivedLevels.append($0) },
            onEvent: { receivedEvents.append($0) },
            onFirstTranscript: { latencyMs, resultType in
                firstTranscript = (latencyMs, resultType)
            },
            onError: { error in
                Issue.record("Unexpected monitor error: \(error)")
            }
        )

        session.yieldAudioLevel(0.25)
        session.yieldEvent(.remoteChunkTelemetry(.init(
            status: .success,
            isFinal: false,
            sampleCount: 12,
            audioDurationMs: 34,
            wavBytes: 56,
            uploadDurationMs: 78,
            textLength: 0,
            errorCategory: nil,
            tags: [:]
        )))
        session.yieldEvent(.partialTranscript("hel"))
        session.yieldEvent(.appendFinalTranscript("hello"))

        #expect(await waitForMainActorCondition { receivedLevels.count == 1 })
        #expect(await waitForMainActorCondition { receivedEvents.count == 3 })
        #expect(eventText(receivedEvents[1], expecting: .partialTranscript) == "hel")
        #expect(eventText(receivedEvents[2], expecting: .appendFinalTranscript) == "hello")
        #expect(firstTranscript?.1 == "volatile")
        #expect((firstTranscript?.0 ?? -1) >= 0)
    }

    @Test func firstTranscriptCallbackOnlyFiresOnce() async {
        let session = TestVoiceSession()
        let monitor = VoiceInputSessionMonitor()
        var callbacks: [(Int, String)] = []

        monitor.bind(
            session: session,
            recordingStartTime: .now,
            onAudioLevel: { _ in },
            onEvent: { _ in },
            onFirstTranscript: { latencyMs, resultType in
                callbacks.append((latencyMs, resultType))
            },
            onError: { error in
                Issue.record("Unexpected monitor error: \(error)")
            }
        )

        session.yieldEvent(.remoteChunkTelemetry(.init(
            status: .success,
            isFinal: false,
            sampleCount: 10,
            audioDurationMs: 10,
            wavBytes: 10,
            uploadDurationMs: 10,
            textLength: nil,
            errorCategory: nil,
            tags: [:]
        )))
        session.yieldEvent(.replaceFinalTranscript("one"))
        session.yieldEvent(.partialTranscript("two"))

        #expect(await waitForMainActorCondition { callbacks.count == 1 })
        #expect(callbacks[0].1 == "final")
    }

    @Test func stopAwaitsSessionStopAndStopsForwarding() async {
        let session = TestVoiceSession()
        let monitor = VoiceInputSessionMonitor()
        var receivedEvents: [VoiceSessionEvent] = []

        monitor.bind(
            session: session,
            recordingStartTime: .now,
            onAudioLevel: { _ in },
            onEvent: { receivedEvents.append($0) },
            onFirstTranscript: { _, _ in },
            onError: { error in
                Issue.record("Unexpected monitor error: \(error)")
            }
        )

        session.yieldEvent(.partialTranscript("before"))
        await Task.yield()
        await monitor.stop()
        session.yieldEvent(.partialTranscript("after"))
        await Task.yield()

        #expect(await session.stopCallCount == 1)
        #expect(receivedEvents.count == 1)
        #expect(eventText(receivedEvents[0], expecting: .partialTranscript) == "before")
    }

    @Test func cancelCancelsSessionWithoutSurfacingErrors() async {
        let session = TestVoiceSession()
        let monitor = VoiceInputSessionMonitor()
        var receivedErrors: [String] = []

        monitor.bind(
            session: session,
            recordingStartTime: .now,
            onAudioLevel: { _ in },
            onEvent: { _ in },
            onFirstTranscript: { _, _ in },
            onError: { error in
                receivedErrors.append(String(describing: error))
            }
        )

        await monitor.cancel()
        session.finishEvents(throwing: TestError.boom)
        await Task.yield()

        #expect(await session.cancelCallCount == 1)
        #expect(receivedErrors.isEmpty)
    }

    @Test func rebindCancelsPreviousTasks() async {
        let first = TestVoiceSession()
        let second = TestVoiceSession()
        let monitor = VoiceInputSessionMonitor()
        var receivedEvents: [VoiceSessionEvent] = []

        monitor.bind(
            session: first,
            recordingStartTime: .now,
            onAudioLevel: { _ in },
            onEvent: { receivedEvents.append($0) },
            onFirstTranscript: { _, _ in },
            onError: { error in
                Issue.record("Unexpected monitor error: \(error)")
            }
        )

        monitor.bind(
            session: second,
            recordingStartTime: .now,
            onAudioLevel: { _ in },
            onEvent: { receivedEvents.append($0) },
            onFirstTranscript: { _, _ in },
            onError: { error in
                Issue.record("Unexpected monitor error: \(error)")
            }
        )

        first.yieldEvent(.partialTranscript("stale"))
        second.yieldEvent(.partialTranscript("fresh"))

        #expect(await waitForMainActorCondition { receivedEvents.count == 1 })
        #expect(eventText(receivedEvents[0], expecting: .partialTranscript) == "fresh")
    }

    @Test func teardownStopsAllForwarding() async {
        let session = TestVoiceSession()
        let monitor = VoiceInputSessionMonitor()
        var receivedEvents: [VoiceSessionEvent] = []

        monitor.bind(
            session: session,
            recordingStartTime: .now,
            onAudioLevel: { _ in },
            onEvent: { receivedEvents.append($0) },
            onFirstTranscript: { _, _ in },
            onError: { error in
                Issue.record("Unexpected monitor error: \(error)")
            }
        )

        monitor.teardown()
        session.yieldEvent(.partialTranscript("should not arrive"))
        await Task.yield()

        #expect(receivedEvents.isEmpty)
    }
}

private enum TestError: Error {
    case boom
}

private enum EventKind {
    case partialTranscript
    case appendFinalTranscript
    case replaceFinalTranscript
}

private func eventText(_ event: VoiceSessionEvent, expecting kind: EventKind) -> String? {
    switch (event, kind) {
    case (.partialTranscript(let text), .partialTranscript):
        return text
    case (.appendFinalTranscript(let text), .appendFinalTranscript):
        return text
    case (.replaceFinalTranscript(let text), .replaceFinalTranscript):
        return text
    default:
        return nil
    }
}

private actor TestCounter {
    private var value = 0

    func increment() {
        value += 1
    }

    var count: Int { value }
}

@MainActor
private final class TestVoiceSession: VoiceTranscriptionSession {
    let events: AsyncThrowingStream<VoiceSessionEvent, Error>
    let audioLevels: AsyncStream<Float>

    private let eventContinuation: AsyncThrowingStream<VoiceSessionEvent, Error>.Continuation
    private let audioContinuation: AsyncStream<Float>.Continuation
    private let stopCounter = TestCounter()
    private let cancelCounter = TestCounter()

    init() {
        let eventPair = AsyncThrowingStream.makeStream(of: VoiceSessionEvent.self, throwing: Error.self)
        events = eventPair.stream
        eventContinuation = eventPair.continuation

        let audioPair = AsyncStream.makeStream(of: Float.self)
        audioLevels = audioPair.stream
        audioContinuation = audioPair.continuation
    }

    func start() async throws -> VoiceSessionStartTimings {
        .init(analyzerStartMs: 0, audioStartMs: 0)
    }

    func stop() async {
        await stopCounter.increment()
        eventContinuation.finish()
        audioContinuation.finish()
    }

    func cancel() async {
        await cancelCounter.increment()
        eventContinuation.finish()
        audioContinuation.finish()
    }

    func yieldEvent(_ event: VoiceSessionEvent) {
        eventContinuation.yield(event)
    }

    func finishEvents(throwing error: Error? = nil) {
        if let error {
            eventContinuation.finish(throwing: error)
        } else {
            eventContinuation.finish()
        }
    }

    func yieldAudioLevel(_ level: Float) {
        audioContinuation.yield(level)
    }

    var stopCallCount: Int {
        get async { await stopCounter.count }
    }

    var cancelCallCount: Int {
        get async { await cancelCounter.count }
    }
}
