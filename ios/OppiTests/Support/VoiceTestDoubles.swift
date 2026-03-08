import Foundation
@testable import Oppi

@MainActor
final class MockVoiceInputSystemAccess: VoiceInputSystemAccessing {
    var hasPermissions = true
    var requestPermissionsResult = true
    var requestPermissionsCallCount = 0
    var activateAudioSessionCallCount = 0
    var deactivateAudioSessionCallCount = 0
    var activateAudioSessionError: Error?

    func requestPermissions() async -> Bool {
        requestPermissionsCallCount += 1
        return requestPermissionsResult
    }

    func activateAudioSession() throws {
        activateAudioSessionCallCount += 1
        if let activateAudioSessionError {
            throw activateAudioSessionError
        }
    }

    func deactivateAudioSession() {
        deactivateAudioSessionCallCount += 1
    }
}

@MainActor
final class MockVoiceProvider: VoiceTranscriptionProvider {
    let id: VoiceProviderID
    let engine: VoiceInputManager.TranscriptionEngine

    var invalidateCacheCallCount = 0
    var cancelPreparationCallCount = 0
    var prewarmCallCount = 0
    var prepareSessionCallCount = 0
    var makeSessionCallCount = 0
    var lastContext: VoiceProviderContext?
    var lastPreparation: VoiceProviderPreparation?

    var prewarmHandler: (@MainActor (VoiceProviderContext) async throws -> Void)?
    var prepareSessionHandler: (@MainActor (VoiceProviderContext) async throws -> VoiceProviderPreparation)?
    var makeSessionHandler: (@MainActor (VoiceProviderContext, VoiceProviderPreparation) throws -> any VoiceTranscriptionSession)?

    init(
        id: VoiceProviderID,
        engine: VoiceInputManager.TranscriptionEngine
    ) {
        self.id = id
        self.engine = engine
    }

    func invalidateCache() {
        invalidateCacheCallCount += 1
    }

    func cancelPreparation() {
        cancelPreparationCallCount += 1
    }

    func prewarm(context: VoiceProviderContext) async throws {
        prewarmCallCount += 1
        lastContext = context
        if let prewarmHandler {
            try await prewarmHandler(context)
        }
    }

    func prepareSession(context: VoiceProviderContext) async throws -> VoiceProviderPreparation {
        prepareSessionCallCount += 1
        lastContext = context
        if let prepareSessionHandler {
            let preparation = try await prepareSessionHandler(context)
            lastPreparation = preparation
            return preparation
        }

        let preparation = VoiceProviderPreparation(
            audioFormat: nil,
            pathTag: "mock",
            setupMetricTags: [:]
        )
        lastPreparation = preparation
        return preparation
    }

    func makeSession(
        context: VoiceProviderContext,
        preparation: VoiceProviderPreparation
    ) throws -> any VoiceTranscriptionSession {
        makeSessionCallCount += 1
        lastContext = context
        lastPreparation = preparation
        if let makeSessionHandler {
            return try makeSessionHandler(context, preparation)
        }
        return MockVoiceSession()
    }
}

@MainActor
final class MockVoiceSession: VoiceTranscriptionSession {
    let events: AsyncThrowingStream<VoiceSessionEvent, Error>
    let audioLevels: AsyncStream<Float>

    private let eventContinuation: AsyncThrowingStream<VoiceSessionEvent, Error>.Continuation
    private let audioLevelContinuation: AsyncStream<Float>.Continuation

    var startTimings = VoiceSessionStartTimings(analyzerStartMs: 11, audioStartMs: 22)
    var startError: Error?
    var startCallCount = 0
    var stopCallCount = 0
    var cancelCallCount = 0

    init() {
        let eventPair = AsyncThrowingStream.makeStream(of: VoiceSessionEvent.self, throwing: Error.self)
        events = eventPair.stream
        eventContinuation = eventPair.continuation

        let audioPair = AsyncStream.makeStream(of: Float.self)
        audioLevels = audioPair.stream
        audioLevelContinuation = audioPair.continuation
    }

    func start() async throws -> VoiceSessionStartTimings {
        startCallCount += 1
        if let startError {
            throw startError
        }
        return startTimings
    }

    func stop() async {
        stopCallCount += 1
        eventContinuation.finish()
        audioLevelContinuation.finish()
    }

    func cancel() async {
        cancelCallCount += 1
        eventContinuation.finish()
        audioLevelContinuation.finish()
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
        audioLevelContinuation.yield(level)
    }
}

actor AsyncGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = continuations
        continuations.removeAll(keepingCapacity: false)
        for continuation in pending {
            continuation.resume()
        }
    }
}

struct TestVoiceError: Error, LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
