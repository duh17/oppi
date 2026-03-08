import Foundation

@MainActor
final class VoiceInputSessionMonitor {
    private var activeSession: (any VoiceTranscriptionSession)?
    private var resultsTask: Task<Void, Never>?
    private var audioLevelTask: Task<Void, Never>?

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
                        onFirstTranscript(Self.elapsedMs(since: recordingStartTime), resultType)
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

    func stop() async {
        guard let activeSession else { return }
        await activeSession.stop()
        self.activeSession = nil
        await resultsTask?.value
        resultsTask = nil
        audioLevelTask?.cancel()
        audioLevelTask = nil
    }

    func cancel() async {
        resultsTask?.cancel()
        resultsTask = nil

        if let activeSession {
            await activeSession.cancel()
            self.activeSession = nil
        }

        audioLevelTask?.cancel()
        audioLevelTask = nil
    }

    func teardown() {
        activeSession = nil
        resultsTask?.cancel()
        resultsTask = nil
        audioLevelTask?.cancel()
        audioLevelTask = nil
    }

    nonisolated private static func firstTranscriptResultType(for event: VoiceSessionEvent) -> String? {
        switch event {
        case .partialTranscript:
            return "volatile"
        case .appendFinalTranscript, .replaceFinalTranscript:
            return "final"
        case .remoteChunkTelemetry:
            return nil
        }
    }

    nonisolated private static func elapsedMs(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds * 1000
            + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }
}
