@preconcurrency import AVFoundation
import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "RemoteASR")

/// Chunked audio transcription via a remote OpenAI-compatible ASR endpoint.
///
/// Receives PCM audio buffers from `AVAudioEngine`, accumulates them in a
/// thread-safe ring buffer, and periodically encodes + uploads WAV chunks
/// to the configured HTTP endpoint. Each response yields finalized text.
///
/// **Endpoint agnostic:** Targets the standard OpenAI `/v1/audio/transcriptions`
/// API. Works with any compatible server — MLX Server (Qwen3-ASR, Whisper),
/// OpenAI, or self-hosted alternatives. Model-specific tuning (repetition
/// penalty, etc.) is handled server-side.
///
/// **Thread model:**
/// - `appendAudio()` is called from the audio engine's real-time callback
///   thread. Uses `os_unfair_lock` for the shared buffer — no allocations,
///   no async, no blocking.
/// - The chunk loop runs as a detached `Task` on a background executor.
/// - Results are delivered via `AsyncStream` for the caller to consume
///   on whatever actor they prefer.
///
/// **Audio format:** Expects 16kHz mono Float32 input (the caller handles
/// resampling from the device's native format). WAV encoding converts
/// Float32 → Int16 in-memory.
final class RemoteASRTranscriber: @unchecked Sendable {

    // MARK: - Configuration

    /// All tunable parameters for a remote ASR session.
    ///
    /// Designed to pass through the standard OpenAI transcription API fields.
    /// The server handles model-specific knobs (e.g. repetition_penalty for
    /// Qwen3-ASR) — clients don't need to know the model internals.
    struct Configuration: Sendable {
        /// Base URL of the ASR server (e.g. `http://mac-studio.local:8321`).
        let endpointURL: URL

        /// Model identifier to request from the server. `"default"` lets the
        /// server pick its configured STT model.
        var model: String = "default"

        /// Optional language hint (BCP 47, e.g. `"en"`, `"zh"`).
        /// Whisper uses this; Qwen3-ASR ignores it.
        var language: String?

        /// Optional prompt/context hint. Whisper uses `initial_prompt`,
        /// VibeVoice uses `context`, Qwen3-ASR ignores it.
        var prompt: String?

        /// Sampling temperature. 0 = greedy (default).
        var temperature: Float = 0.0

        /// Seconds of audio per chunk before uploading. Default 2.0s.
        var chunkInterval: TimeInterval = 2.0

        /// Seconds of overlap prepended to each chunk to avoid mid-word cuts.
        var overlapDuration: TimeInterval = 0.5

        /// Expected input sample rate. Must match the format fed to `appendAudio`.
        var sampleRate: Int = 16_000

        /// Request timeout in seconds for each chunk upload.
        var requestTimeout: TimeInterval = 10.0

        /// Response format requested from the server.
        var responseFormat: String = "json"

        /// Optional server-specific profile hint (e.g. `dictation`).
        /// Omitted when nil to remain OpenAI-compatible.
        var sttProfile: String?

        /// Optional server-side cleanup toggle for dictation-oriented post-processing.
        /// Omitted when nil.
        var dictationCleanup: Bool?

        /// Number of trailing words to send as overlap context on each chunk.
        /// Set to 0 to disable `overlap_text`/`previous_text` fields.
        var overlapTextWordCount: Int = 20
    }

    let config: Configuration

    // MARK: - Internal State (lock-protected)

    /// Audio buffer state, protected by an allocated unfair lock.
    /// Contains the accumulated PCM samples and the overlap from the previous chunk.
    private struct AudioBufferState: Sendable {
        var sampleBuffer: [Float] = []
        var overlapSamples: [Float] = []
    }

    private struct RequestContextState: Sendable {
        var overlapText: String = ""
    }

    private let audioBuffer = OSAllocatedUnfairLock(initialState: AudioBufferState())
    private let requestContext = OSAllocatedUnfairLock(initialState: RequestContextState())

    // MARK: - Async Plumbing

    private var chunkTask: Task<Void, Never>?
    private var resultsContinuation: AsyncStream<TranscriptionResult>.Continuation?
    private var urlSession: URLSession?
    private var isStopping = false

    // MARK: - Types

    struct TranscriptionResult: Sendable {
        let text: String
        let isFinal: Bool
        /// Server-reported duration of the transcribed audio, if available.
        let duration: Double?
    }

    enum ChunkStatus: String, Sendable {
        case success
        case empty
        case skipped
        case cancelled
        case error
    }

    struct ChunkTelemetry: Sendable {
        let status: ChunkStatus
        let isFinal: Bool
        let sampleCount: Int
        let audioDurationMs: Int
        let wavBytes: Int
        let uploadDurationMs: Int?
        let textLength: Int?
        let errorCategory: String?
    }

    /// Optional observer for per-chunk telemetry (success + failures).
    var onChunkTelemetry: (@Sendable (ChunkTelemetry) -> Void)?

    // MARK: - Init

    init(configuration: Configuration) {
        config = configuration
    }

    // MARK: - Lifecycle

    /// Start the chunk loop. Returns a stream of transcription results.
    func start() -> AsyncStream<TranscriptionResult> {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = config.requestTimeout
        sessionConfig.timeoutIntervalForResource = config.requestTimeout + 5
        urlSession = URLSession(configuration: sessionConfig)
        isStopping = false

        let (stream, continuation) = AsyncStream<TranscriptionResult>.makeStream()
        resultsContinuation = continuation

        chunkTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.chunkLoop()
        }

        logger.info("Remote ASR started (endpoint: \(self.config.endpointURL.absoluteString), model: \(self.config.model), profile: \(self.config.sttProfile ?? "none"), chunk: \(self.config.chunkInterval)s, overlap: \(self.config.overlapDuration)s)")
        return stream
    }

    /// Stop recording: flush remaining audio as a final chunk, then close the stream.
    func stop() async {
        isStopping = true
        chunkTask?.cancel()
        chunkTask = nil

        // Flush any remaining audio
        await sendCurrentChunk(isFinal: true)

        resetSessionState()
        logger.info("Remote ASR stopped")
    }

    /// Cancel immediately — discard everything, no final flush.
    func cancel() {
        isStopping = true
        chunkTask?.cancel()
        chunkTask = nil

        resetSessionState()
        logger.info("Remote ASR cancelled")
    }

    private func resetSessionState() {
        resultsContinuation?.finish()
        resultsContinuation = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil

        audioBuffer.withLock { state in
            state.sampleBuffer.removeAll()
            state.overlapSamples.removeAll()
        }
        requestContext.withLock { state in
            state.overlapText = ""
        }
    }

    // MARK: - Audio Input

    /// Append PCM audio from the engine tap. Called on the real-time audio thread.
    /// The buffer must be mono Float32 at `config.sampleRate`.
    func appendAudio(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }

        let samples = Array(UnsafeBufferPointer(start: channelData, count: count))
        audioBuffer.withLock { state in
            state.sampleBuffer.append(contentsOf: samples)
        }
    }

    // MARK: - Chunk Loop

    private func chunkLoop() async {
        let intervalNs = UInt64(config.chunkInterval * 1_000_000_000)

        while !Task.isCancelled && !isStopping {
            try? await Task.sleep(nanoseconds: intervalNs)
            guard !Task.isCancelled && !isStopping else { break }
            await sendCurrentChunk(isFinal: false)
        }
    }

    private func sendCurrentChunk(isFinal: Bool) async {
        let overlapCount = Int(config.overlapDuration * Double(config.sampleRate))

        // Drain buffer under lock
        let (currentSamples, previousOverlap) = audioBuffer.withLock { state -> ([Float], [Float]) in
            let samples = state.sampleBuffer
            state.sampleBuffer.removeAll(keepingCapacity: true)
            let overlap = state.overlapSamples

            if !isFinal, samples.count > overlapCount {
                state.overlapSamples = Array(samples.suffix(overlapCount))
            } else {
                state.overlapSamples = []
            }

            return (samples, overlap)
        }

        // Build chunk: overlap from previous + current samples
        var chunkSamples: [Float] = []
        chunkSamples.reserveCapacity(previousOverlap.count + currentSamples.count)
        chunkSamples.append(contentsOf: previousOverlap)
        chunkSamples.append(contentsOf: currentSamples)

        // Skip empty or too-short chunks (< 0.1s)
        let minSamples = config.sampleRate / 10
        let chunkDurationMs = Int(Double(chunkSamples.count) / Double(config.sampleRate) * 1000)

        guard chunkSamples.count >= minSamples else {
            if isFinal {
                logger.info("Final chunk too short (\(chunkSamples.count) samples), skipping")
            }
            onChunkTelemetry?(
                ChunkTelemetry(
                    status: .skipped,
                    isFinal: isFinal,
                    sampleCount: chunkSamples.count,
                    audioDurationMs: chunkDurationMs,
                    wavBytes: 0,
                    uploadDurationMs: nil,
                    textLength: nil,
                    errorCategory: nil
                )
            )
            return
        }

        logger.info("Sending chunk: \(chunkSamples.count) samples (\(chunkDurationMs)ms), final=\(isFinal)")

        // Encode to WAV
        let wavData = WAVEncoder.encode(samples: chunkSamples, sampleRate: config.sampleRate)

        let overlapText = requestContext.withLock { state in
            state.overlapText.isEmpty ? nil : state.overlapText
        }

        // POST to endpoint
        let startTime = ContinuousClock.now
        do {
            let response = try await transcribe(wavData: wavData, overlapText: overlapText)
            let ms = startTime.elapsedMs()

            let trimmed = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                logger.info("Chunk returned empty text (\(ms)ms)")
                onChunkTelemetry?(
                    ChunkTelemetry(
                        status: .empty,
                        isFinal: isFinal,
                        sampleCount: chunkSamples.count,
                        audioDurationMs: chunkDurationMs,
                        wavBytes: wavData.count,
                        uploadDurationMs: ms,
                        textLength: 0,
                        errorCategory: nil
                    )
                )
                return
            }

            updateOverlapTextContext(with: trimmed)

            logger.info("Chunk transcribed in \(ms)ms: \(trimmed.prefix(80))...")
            onChunkTelemetry?(
                ChunkTelemetry(
                    status: .success,
                    isFinal: isFinal,
                    sampleCount: chunkSamples.count,
                    audioDurationMs: chunkDurationMs,
                    wavBytes: wavData.count,
                    uploadDurationMs: ms,
                    textLength: trimmed.count,
                    errorCategory: nil
                )
            )
            resultsContinuation?.yield(
                TranscriptionResult(text: trimmed, isFinal: true, duration: response.duration)
            )
        } catch is CancellationError {
            logger.info("Chunk upload cancelled")
            onChunkTelemetry?(
                ChunkTelemetry(
                    status: .cancelled,
                    isFinal: isFinal,
                    sampleCount: chunkSamples.count,
                    audioDurationMs: chunkDurationMs,
                    wavBytes: wavData.count,
                    uploadDurationMs: nil,
                    textLength: nil,
                    errorCategory: nil
                )
            )
        } catch {
            logger.error("Chunk transcription failed: \(error.localizedDescription)")
            onChunkTelemetry?(
                ChunkTelemetry(
                    status: .error,
                    isFinal: isFinal,
                    sampleCount: chunkSamples.count,
                    audioDurationMs: chunkDurationMs,
                    wavBytes: wavData.count,
                    uploadDurationMs: nil,
                    textLength: nil,
                    errorCategory: Self.errorCategory(for: error)
                )
            )
        }
    }

    private func updateOverlapTextContext(with text: String) {
        let maxWords = max(0, config.overlapTextWordCount)
        guard maxWords > 0 else { return }

        let incomingWords = Self.contextWords(from: text)
        guard !incomingWords.isEmpty else { return }

        requestContext.withLock { state in
            var combined = Self.contextWords(from: state.overlapText)
            combined.append(contentsOf: incomingWords)
            if combined.count > maxWords {
                combined = Array(combined.suffix(maxWords))
            }
            state.overlapText = combined.joined(separator: " ")
        }
    }

    private static func contextWords(from text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func errorCategory(for error: Error) -> String {
        if let voiceError = error as? VoiceInputError {
            return voiceError.telemetryCategory
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return "timeout"
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost:
                return "network"
            case .cancelled:
                return "cancelled"
            default:
                return "url_error"
            }
        }

        if error is DecodingError {
            return "decode"
        }

        return "other"
    }

    // MARK: - HTTP

    private func transcribe(wavData: Data, overlapText: String?) async throws -> TranscriptionAPIResponse {
        guard let session = urlSession else {
            throw VoiceInputError.internalError("URLSession not available")
        }

        let url = config.endpointURL.appendingPathComponent("v1/audio/transcriptions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )

        var body = Data()

        // Required: audio file
        body.appendMultipartFile(
            boundary: boundary, name: "file", filename: "audio.wav",
            contentType: "audio/wav", data: wavData
        )

        // Model
        body.appendMultipartField(boundary: boundary, name: "model", value: config.model)

        // Response format
        body.appendMultipartField(
            boundary: boundary, name: "response_format", value: config.responseFormat
        )

        // Optional: language hint
        if let language = config.language {
            body.appendMultipartField(boundary: boundary, name: "language", value: language)
        }

        // Optional: prompt/context
        if let prompt = config.prompt {
            body.appendMultipartField(boundary: boundary, name: "prompt", value: prompt)
        }

        // Temperature (only send if non-zero — 0 is server default)
        if config.temperature > 0 {
            body.appendMultipartField(
                boundary: boundary, name: "temperature",
                value: String(format: "%.2f", config.temperature)
            )
        }

        // Optional: server-specific dictation controls.
        if let profile = config.sttProfile?.trimmingCharacters(in: .whitespacesAndNewlines),
           !profile.isEmpty {
            body.appendMultipartField(boundary: boundary, name: "stt_profile", value: profile)
        }

        if let dictationCleanup = config.dictationCleanup {
            body.appendMultipartField(
                boundary: boundary,
                name: "dictation_cleanup",
                value: dictationCleanup ? "true" : "false"
            )
        }

        if let overlapText = overlapText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !overlapText.isEmpty {
            body.appendMultipartField(boundary: boundary, name: "overlap_text", value: overlapText)
            // Backward-compatible alias accepted by older local server builds.
            body.appendMultipartField(boundary: boundary, name: "previous_text", value: overlapText)
        }

        // Close boundary
        body.append(Data("--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            switch urlError.code {
            case .timedOut:
                throw VoiceInputError.remoteRequestTimedOut
            case .cancelled:
                throw CancellationError()
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost:
                throw VoiceInputError.remoteNetwork(urlError.localizedDescription)
            default:
                throw VoiceInputError.remoteNetwork(urlError.localizedDescription)
            }
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw VoiceInputError.remoteInvalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            let bodyText = String(data: data, encoding: .utf8) ?? "unknown"
            logger.error("ASR endpoint returned \(httpResponse.statusCode): \(bodyText.prefix(200))")
            throw VoiceInputError.remoteBadResponseStatus(httpResponse.statusCode)
        }

        do {
            return try JSONDecoder().decode(TranscriptionAPIResponse.self, from: data)
        } catch {
            throw VoiceInputError.remoteDecodeFailed
        }
    }

    /// OpenAI-compatible transcription response.
    /// Matches the fields from `/v1/audio/transcriptions`.
    private struct TranscriptionAPIResponse: Decodable {
        let text: String
        let language: String?
        let duration: Double?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            text = try container.decode(String.self, forKey: .text)
            language = try container.decodeIfPresent(String.self, forKey: .language)
            duration = try container.decodeIfPresent(Double.self, forKey: .duration)
        }

        private enum CodingKeys: String, CodingKey {
            case text, language, duration
        }
    }
}
