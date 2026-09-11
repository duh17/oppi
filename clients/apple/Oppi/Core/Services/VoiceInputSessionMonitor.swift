import Foundation

@MainActor
final class VoiceInputSessionMonitor {
    private var activeSession: (any VoiceTranscriptionSession)?
    private var resultsTask: Task<Void, Never>?
    private var audioLevelTask: Task<Void, Never>?
    // Session.cancel() may return immediately on its second call even while the
    // first is draining hardware. Every retiring caller must await that drain.
    private var cancellations: [ObjectIdentifier: Task<Void, Never>] = [:]

    func bind(
        session: any VoiceTranscriptionSession,
        recordingStartTime: ContinuousClock.Instant,
        onAudioLevel: @escaping @MainActor (Float) -> Void,
        onEvent: @escaping @MainActor (VoiceSessionEvent) -> Void,
        onFirstTranscript: @escaping @MainActor (_ latencyMs: Int, _ resultType: String) -> Void,
        onError: @escaping @MainActor (Error) -> Void
    ) {
        activeSession = session

        audioLevelTask?.cancel()
        audioLevelTask = Task {
            for await level in session.audioLevels {
                guard !Task.isCancelled else { break }
                onAudioLevel(level)
            }
        }

        resultsTask?.cancel()
        resultsTask = Task {
            var firstTranscriptRecorded = false

            do {
                for try await event in session.events {
                    guard !Task.isCancelled else { break }

                    if !firstTranscriptRecorded,
                       let resultType = Self.firstTranscriptResultType(for: event) {
                        firstTranscriptRecorded = true
                        onFirstTranscript(recordingStartTime.elapsedMs(), resultType)
                    }

                    onEvent(event)
                }
            } catch {
                if !Task.isCancelled {
                    onError(error)
                }
            }
        }
    }

    func rebuildAudioCapture() async throws {
        guard let session = activeSession else {
            throw VoiceInputError.audioCaptureUnavailable
        }
        try await session.rebuildAudioCapture()
    }

    func stop() async {
        let retiringSession = activeSession
        let retiringResultsTask = resultsTask
        let retiringAudioLevelTask = audioLevelTask
        guard let retiringSession else { return }

        await retiringSession.stop()
        await retiringResultsTask?.value
        retiringAudioLevelTask?.cancel()
        clearIfCurrent(session: retiringSession)
    }

    func cancel() async {
        let retiringSession = activeSession
        let retiringResultsTask = resultsTask
        let retiringAudioLevelTask = audioLevelTask

        retiringResultsTask?.cancel()
        if let retiringSession {
            await cancellationTask(for: retiringSession).value
        }
        retiringAudioLevelTask?.cancel()
        clearIfCurrent(session: retiringSession)
    }

    /// Drop only the bind we captured. A newer `bind()` during `stop()`/`cancel()`
    /// always assigns `activeSession` first, so identity is the generation check
    /// for the session and both forwarding tasks.
    private func clearIfCurrent(session: (any VoiceTranscriptionSession)?) {
        guard activeSession === session else { return }
        activeSession = nil
        resultsTask = nil
        audioLevelTask = nil
    }

    func teardown() {
        let session = activeSession
        activeSession = nil
        resultsTask?.cancel()
        resultsTask = nil
        audioLevelTask?.cancel()
        audioLevelTask = nil
        guard let session else { return }
        _ = cancellationTask(for: session)
    }

    private func cancellationTask(for session: any VoiceTranscriptionSession) -> Task<Void, Never> {
        let id = ObjectIdentifier(session)
        if let task = cancellations[id] { return task }
        let task = Task { @MainActor in
            await session.cancel()
            cancellations[id] = nil
        }
        cancellations[id] = task
        return task
    }

    nonisolated private static func firstTranscriptResultType(for event: VoiceSessionEvent) -> String? {
        switch event {
        case .partialTranscript:
            return "volatile"
        case .appendFinalTranscript:
            return "final"
        case .replaceFinalTranscript(_, let snap, _, _):
            return snap ? "final" : "preview"
        case .remoteChunkTelemetry, .providerMetricTags:
            return nil
        }
    }


}
