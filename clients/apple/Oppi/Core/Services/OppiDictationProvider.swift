@preconcurrency import AVFoundation
import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "DictationProvider")

/// Voice transcription provider that streams audio to the Oppi server.
///
/// New servers use the session-bound audio stream. Legacy servers fall back to dictation
/// over the main session WebSocket during migration.
@MainActor
final class OppiDictationProvider: VoiceTranscriptionProvider {
    nonisolated let id: VoiceProviderID = .oppiServer
    nonisolated let engine: VoiceInputManager.TranscriptionEngine = .serverDictation

    /// Per-recording message stream. Created in `prepareSession`, consumed by the session.
    private var activeRecordingMessages: AsyncStream<ServerMessage>?
    /// Continuation for feeding dictation messages into the recording stream.
    private var activeRecordingContinuation: AsyncStream<ServerMessage>.Continuation?
    /// Background task that sends `dictation_start` and awaits `dictation_ready`.
    private var activeReadinessTask: Task<DictationProviderInfo?, Error>?
    private var preparationTask: Task<Void, Never>?
    /// Task consuming the active dictation transport.
    private var dictationRouteTask: Task<Void, Never>?
    private var activeTransport: (any DictationTransport)?

    func invalidateCache() {
        activeReadinessTask?.cancel()
        activeReadinessTask = nil
        stopDictationRouting()
    }

    func cancelPreparation() {
        preparationTask?.cancel()
        preparationTask = nil
        activeReadinessTask?.cancel()
        activeReadinessTask = nil
        stopDictationRouting()
    }

    func prewarm(context _: VoiceProviderContext) async throws {
        // No warm connection: dictation opens its session audio stream on demand.
    }

    func prepareSession(context: VoiceProviderContext) async throws -> VoiceProviderPreparation {
        guard let credentials = context.serverCredentials else {
            throw VoiceInputError.serverNotConnected
        }
        guard let connection = context.serverConnection else {
            throw VoiceInputError.serverNotConnected
        }

        let transport: any DictationTransport
        let messageStream: AsyncStream<ServerMessage>
        let transportTag: String
        if let client = connection.makeDictationStreamClientForFocusedSession() {
            transport = client
            messageStream = client.connect()
            transportTag = "session_audio_stream"
        } else {
            transport = connection
            messageStream = connection.subscribeDictation()
            transportTag = "legacy_stream"
        }
        stopDictationRouting()
        activeTransport = transport

        // Subscribe to dictation messages before creating the recording stream.
        startDictationRouting(messages: messageStream)

        // Create a fresh per-recording message stream.
        let (recordingStream, recordingContinuation) = AsyncStream.makeStream(of: ServerMessage.self)
        self.activeRecordingMessages = recordingStream
        self.activeRecordingContinuation = recordingContinuation

        // Fire readiness in the background. The session awaits this task before
        // flushing buffered audio, so the UI transitions to .recording immediately
        // while the server-side ASR setup completes (~one RTT).
        let readinessTask: Task<DictationProviderInfo?, Error> = Task {
            try await transport.sendDictation(.dictationStart)

            // Wait for dictation_ready to arrive in the recording stream.
            // The message routing task yields it; we consume a copy here.
            let info = try await waitForReady(timeout: .seconds(10))
            logger.info(
                "Dictation recording ready (stt=\(info?.sttProvider ?? "unknown", privacy: .public), model=\(info?.sttModel ?? "unknown", privacy: .public))"
            )
            return info
        }
        self.activeReadinessTask = readinessTask

        return VoiceProviderPreparation(
            audioFormat: nil,
            pathTag: transportTag == "session_audio_stream" ? "dictation_audio_ws" : "dictation_ws",
            setupMetricTags: Self.metricTags(
                host: credentials.host,
                serverInfo: nil,
                transport: transportTag
            )
        )
    }

    /// Wait for `dictation_ready` from the server by monitoring the dictation subscription.
    /// Uses a continuation that the routing task resolves when it sees `.dictationReady`.
    private var readyContinuation: CheckedContinuation<DictationProviderInfo?, Error>?
    private var readyTimeoutTask: Task<Void, Never>?

    private func waitForReady(timeout: Duration) async throws -> DictationProviderInfo? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<DictationProviderInfo?, Error>) in
            readyContinuation = continuation

            readyTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self, let cont = self.readyContinuation else { return }
                self.readyContinuation = nil
                cont.resume(throwing: VoiceInputError.remoteRequestTimedOut)
            }
        }
    }

    /// Start a task that consumes dictation messages from the active transport
    /// and forwards them to the per-recording stream + resolves readiness.
    private func startDictationRouting(messages: AsyncStream<ServerMessage>) {
        dictationRouteTask = Task { [weak self] in
            for await message in messages {
                guard let self else { break }

                // Resolve readiness if waiting
                if case .dictationReady(let provider) = message {
                    readyTimeoutTask?.cancel()
                    readyTimeoutTask = nil
                    if let cont = readyContinuation {
                        readyContinuation = nil
                        cont.resume(returning: provider)
                    }
                }

                // Resolve readiness on fatal error too
                if case .dictationError(_, let fatal) = message, fatal {
                    readyTimeoutTask?.cancel()
                    readyTimeoutTask = nil
                    if let cont = readyContinuation {
                        readyContinuation = nil
                        let errorMsg: String
                        if case .dictationError(let e, _) = message { errorMsg = e } else { errorMsg = "Unknown" }
                        cont.resume(throwing: VoiceInputError.internalError("Server: \(errorMsg)"))
                    }
                }

                // Forward to recording stream
                activeRecordingContinuation?.yield(message)

                // dictation_final ends this recording's stream
                if case .dictationFinal = message {
                    activeRecordingContinuation?.finish()
                    activeRecordingContinuation = nil
                    activeRecordingMessages = nil
                }
            }
        }
    }

    private func stopDictationRouting() {
        dictationRouteTask?.cancel()
        dictationRouteTask = nil
        activeRecordingContinuation?.finish()
        activeRecordingContinuation = nil
        activeRecordingMessages = nil
        readyTimeoutTask?.cancel()
        readyTimeoutTask = nil
        activeTransport?.closeDictationTransport()
        activeTransport = nil
        if let cont = readyContinuation {
            readyContinuation = nil
            cont.resume(throwing: VoiceInputError.internalError("Dictation routing stopped"))
        }
    }

    // MARK: - Metric Tags

    private static func metricTags(
        host: String,
        serverInfo: DictationProviderInfo?,
        transport: String
    ) -> [String: String] {
        [
            "dictation_mode": "server",
            "host": host,
            "provider_id": "oppi_server_dictation",
            "provider_kind": "local_server",
            "stt_backend": serverInfo?.sttProvider ?? "unknown",
            "model": serverInfo?.sttModel ?? "unknown",
            "transport": transport,
            "live_preview": "1",
        ]
    }

    func makeSession(
        context: VoiceProviderContext,
        preparation _: VoiceProviderPreparation
    ) throws -> any VoiceTranscriptionSession {
        guard context.serverConnection != nil else {
            throw VoiceInputError.serverNotConnected
        }
        guard let readinessTask = activeReadinessTask else {
            throw VoiceInputError.internalError("Dictation readiness task not prepared")
        }
        guard let recordingMessages = activeRecordingMessages else {
            throw VoiceInputError.internalError("Dictation recording messages not prepared")
        }
        guard let transport = activeTransport else {
            throw VoiceInputError.internalError("Dictation transport not prepared")
        }
        // Clear per-recording state — session now owns these.
        activeReadinessTask = nil
        activeRecordingMessages = nil
        activeTransport = nil
        return OppiDictationSession(
            transport: transport,
            readinessTask: readinessTask,
            messages: recordingMessages
        )
    }
}
