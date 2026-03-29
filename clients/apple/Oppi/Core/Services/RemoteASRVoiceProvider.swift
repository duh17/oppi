@preconcurrency import AVFoundation
import Foundation
import OSLog

private let remoteVoiceProviderLogger = Logger(
    subsystem: AppIdentifiers.subsystem,
    category: "VoiceInput"
)

@MainActor
final class RemoteASRVoiceProvider: VoiceTranscriptionProvider {
    // periphery:ignore - protocol conformance; used by VoiceProviderRegistryTests via @testable import
    nonisolated let id: VoiceProviderID = .remoteASR
    nonisolated let engine: VoiceInputManager.TranscriptionEngine = .remoteASR

    private struct ChunkProfile: Sendable {
        let chunkInterval: TimeInterval
        let overlapDuration: TimeInterval
        let requestTimeout: TimeInterval
        let profileTag: String

        var metricTags: [String: String] {
            [
                "chunk_profile": profileTag,
                "chunk_interval_ms": String(Int(chunkInterval * 1000)),
                "chunk_overlap_ms": String(Int(overlapDuration * 1000)),
                "chunk_timeout_ms": String(Int(requestTimeout * 1000)),
            ]
        }
    }

    private static let remoteChunkProfileDefault = ChunkProfile(
        chunkInterval: 1.8,
        overlapDuration: 0.5,
        requestTimeout: 10,
        profileTag: "default"
    )

    private static let remoteChunkProfileCJK = ChunkProfile(
        chunkInterval: 2.0,
        overlapDuration: 0.5,
        requestTimeout: 10,
        profileTag: "cjk"
    )

    /// Conservative dictation guidance for OpenAI-compatible STT APIs.
    private static let remoteDictationPrompt =
        "Transcribe real-time dictation for chat. Keep the original spoken language and script exactly as spoken. Never translate. Remove filler words like uh, um, ah, and oh unless clearly intentional. Keep punctuation light and natural. Do not add acknowledgements like ok/okay unless explicitly spoken."

    private static let remoteDictationSTTProfile = "dictation"
    private static let remoteDictationCleanupEnabled = true
    private static let remoteOverlapTextWordCount = 20

    func invalidateCache() {}
    func cancelPreparation() {}

    func prewarm(context: VoiceProviderContext) async throws {
        _ = context
    }

    func prepareSession(context: VoiceProviderContext) async throws -> VoiceProviderPreparation {
        guard context.remoteEndpoint != nil else {
            throw VoiceInputError.remoteEndpointNotConfigured
        }

        let profile = Self.chunkProfile(for: context.locale)
        let languageHint = Self.languageHint(for: context.locale)
        let tags = profile.metricTags.merging(
            [
                "stt_profile": Self.remoteDictationSTTProfile,
                "dictation_cleanup": Self.remoteDictationCleanupEnabled ? "1" : "0",
                "overlap_text_words": String(Self.remoteOverlapTextWordCount),
                "language_hint": languageHint ?? "auto",
            ],
            uniquingKeysWith: { current, _ in current }
        )

        return VoiceProviderPreparation(
            audioFormat: nil,
            pathTag: "remote",
            setupMetricTags: tags
        )
    }

    func makeSession(
        context: VoiceProviderContext,
        preparation: VoiceProviderPreparation
    ) throws -> any VoiceTranscriptionSession {
        guard let endpoint = context.remoteEndpoint else {
            throw VoiceInputError.remoteEndpointNotConfigured
        }

        let profile = Self.chunkProfile(for: context.locale)
        let languageHint = Self.languageHint(for: context.locale)
        let transcriber = RemoteASRTranscriber(
            configuration: .init(
                endpointURL: endpoint,
                model: "default",
                language: languageHint,
                prompt: Self.remoteDictationPrompt,
                chunkInterval: profile.chunkInterval,
                overlapDuration: profile.overlapDuration,
                requestTimeout: profile.requestTimeout,
                responseFormat: "json",
                sttProfile: Self.remoteDictationSTTProfile,
                dictationCleanup: Self.remoteDictationCleanupEnabled,
                overlapTextWordCount: Self.remoteOverlapTextWordCount
            )
        )

        var chunkTags = preparation.setupMetricTags
        if let host = endpoint.host {
            chunkTags["host"] = host
        }

        return RemoteASRVoiceSession(
            transcriber: transcriber,
            chunkMetricTags: chunkTags
        )
    }

    private static func chunkProfile(for locale: Locale) -> ChunkProfile {
        let langCode = locale.language.languageCode?.identifier ?? "en"
        switch langCode {
        case "zh", "ja", "ko":
            return remoteChunkProfileCJK
        default:
            return remoteChunkProfileDefault
        }
    }

    private static func languageHint(for _: Locale) -> String? {
        nil
    }
}

@MainActor
private final class RemoteASRVoiceSession: VoiceTranscriptionSession {
    let events: AsyncThrowingStream<VoiceSessionEvent, Error>
    let audioLevels: AsyncStream<Float>

    private let transcriber: RemoteASRTranscriber
    private let chunkMetricTags: [String: String]
    private let eventContinuation: AsyncThrowingStream<VoiceSessionEvent, Error>.Continuation
    private let audioLevelContinuation: AsyncStream<Float>.Continuation

    private var audioEngine: AVAudioEngine?
    private var resultsTask: Task<Void, Never>?
    private var audioLevelTask: Task<Void, Never>?

    init(
        transcriber: RemoteASRTranscriber,
        chunkMetricTags: [String: String]
    ) {
        self.transcriber = transcriber
        self.chunkMetricTags = chunkMetricTags

        let eventPair: (
            AsyncThrowingStream<VoiceSessionEvent, Error>,
            AsyncThrowingStream<VoiceSessionEvent, Error>.Continuation
        ) = {
            var capturedContinuation: AsyncThrowingStream<VoiceSessionEvent, Error>.Continuation?
            let stream = AsyncThrowingStream<VoiceSessionEvent, Error> {
                capturedContinuation = $0
            }
            guard let continuation = capturedContinuation else {
                preconditionFailure("Failed to create remote voice events stream")
            }
            return (stream, continuation)
        }()
        events = eventPair.0
        eventContinuation = eventPair.1

        let (audioLevels, audioLevelContinuation) = AsyncStream.makeStream(of: Float.self)
        self.audioLevels = audioLevels
        self.audioLevelContinuation = audioLevelContinuation
    }

    func start() async throws -> VoiceSessionStartTimings {
        transcriber.onChunkTelemetry = { [weak self] chunk in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.eventContinuation.yield(.remoteChunkTelemetry(self.makeChunkTelemetry(from: chunk)))
            }
        }

        let analyzerStart = ContinuousClock.now
        let resultStream = transcriber.start()
        startResultsBridge(resultStream)
        let analyzerStartMs = analyzerStart.elapsedMs()

        let audioStart = ContinuousClock.now
        let (engine, levelStream) = try RemoteAudioEngineHelper.startEngine(
            transcriber: transcriber,
            sampleRate: transcriber.config.sampleRate
        )
        audioEngine = engine
        startAudioLevelBridge(levelStream)
        let audioStartMs = audioStart.elapsedMs()

        return VoiceSessionStartTimings(
            analyzerStartMs: analyzerStartMs,
            audioStartMs: audioStartMs
        )
    }

    func stop() async {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil

        await transcriber.stop()
        await resultsTask?.value
        cleanupAfterStop()
    }

    func cancel() async {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil

        resultsTask?.cancel()
        resultsTask = nil
        audioLevelTask?.cancel()
        audioLevelTask = nil
        transcriber.cancel()
        cleanupAfterStop()
    }

    private func startResultsBridge(
        _ resultStream: AsyncStream<RemoteASRTranscriber.TranscriptionResult>
    ) {
        resultsTask?.cancel()
        resultsTask = Task {
            var mergedTranscript = ""

            for await result in resultStream {
                guard !Task.isCancelled else { break }

                let normalized = RemoteTranscriptAssembler.normalizedChunkText(result.text)
                guard !normalized.isEmpty else {
                    remoteVoiceProviderLogger.debug("Remote chunk dropped after normalization")
                    continue
                }

                mergedTranscript = RemoteTranscriptAssembler.merge(
                    existing: mergedTranscript,
                    incoming: normalized
                )
                eventContinuation.yield(.replaceFinalTranscript(mergedTranscript))
            }

            eventContinuation.finish()
        }
    }

    private func startAudioLevelBridge(_ levelStream: AsyncStream<Float>) {
        audioLevelTask?.cancel()
        audioLevelTask = Task {
            for await level in levelStream {
                guard !Task.isCancelled else { break }
                audioLevelContinuation.yield(level)
            }
            audioLevelContinuation.finish()
        }
    }

    private func cleanupAfterStop() {
        transcriber.onChunkTelemetry = nil
        resultsTask = nil
        audioLevelTask?.cancel()
        audioLevelTask = nil
        eventContinuation.finish()
        audioLevelContinuation.finish()
    }

    private func makeChunkTelemetry(
        from chunk: RemoteASRTranscriber.ChunkTelemetry
    ) -> VoiceRemoteChunkTelemetry {
        VoiceRemoteChunkTelemetry(
            status: Self.chunkStatus(from: chunk.status),
            isFinal: chunk.isFinal,
            sampleCount: chunk.sampleCount,
            audioDurationMs: chunk.audioDurationMs,
            wavBytes: chunk.wavBytes,
            uploadDurationMs: chunk.uploadDurationMs,
            textLength: chunk.textLength,
            errorCategory: chunk.errorCategory,
            tags: chunkMetricTags
        )
    }

    private static func chunkStatus(
        from status: RemoteASRTranscriber.ChunkStatus
    ) -> VoiceRemoteChunkStatus {
        switch status {
        case .success: .success
        case .empty: .empty
        case .skipped: .skipped
        case .cancelled: .cancelled
        case .error: .error
        }
    }


}
