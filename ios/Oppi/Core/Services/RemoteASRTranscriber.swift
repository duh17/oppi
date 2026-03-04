import Accelerate
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
    }

    let config: Configuration

    // MARK: - Internal State (lock-protected)

    /// Audio buffer state, protected by an allocated unfair lock.
    /// Contains the accumulated PCM samples and the overlap from the previous chunk.
    private struct AudioBufferState: Sendable {
        var sampleBuffer: [Float] = []
        var overlapSamples: [Float] = []
    }

    private let audioBuffer = OSAllocatedUnfairLock(initialState: AudioBufferState())

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

        logger.info("Remote ASR started (endpoint: \(self.config.endpointURL.absoluteString), model: \(self.config.model), chunk: \(self.config.chunkInterval)s, overlap: \(self.config.overlapDuration)s)")
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
        guard chunkSamples.count >= minSamples else {
            if isFinal {
                logger.info("Final chunk too short (\(chunkSamples.count) samples), skipping")
            }
            return
        }

        let chunkDurationMs = Int(Double(chunkSamples.count) / Double(config.sampleRate) * 1000)
        logger.info("Sending chunk: \(chunkSamples.count) samples (\(chunkDurationMs)ms), final=\(isFinal)")

        // Encode to WAV
        let wavData = WAVEncoder.encode(samples: chunkSamples, sampleRate: config.sampleRate)

        // POST to endpoint
        let startTime = ContinuousClock.now
        do {
            let response = try await transcribe(wavData: wavData)
            let elapsed = ContinuousClock.now - startTime
            let ms = Int(
                elapsed.components.seconds * 1000
                    + elapsed.components.attoseconds / 1_000_000_000_000_000
            )

            let trimmed = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                logger.info("Chunk returned empty text (\(ms)ms)")
                return
            }

            logger.error("Chunk transcribed in \(ms)ms: \(trimmed.prefix(80))...")
            resultsContinuation?.yield(
                TranscriptionResult(text: trimmed, isFinal: true, duration: response.duration)
            )
        } catch is CancellationError {
            logger.info("Chunk upload cancelled")
        } catch {
            logger.error("Chunk transcription failed: \(error.localizedDescription)")
        }
    }

    // MARK: - HTTP

    private func transcribe(wavData: Data) async throws -> TranscriptionAPIResponse {
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

        // Close boundary
        body.append(Data("--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw VoiceInputError.internalError("Invalid response type")
        }
        guard httpResponse.statusCode == 200 else {
            let bodyText = String(data: data, encoding: .utf8) ?? "unknown"
            throw VoiceInputError.internalError(
                "ASR endpoint returned \(httpResponse.statusCode): \(bodyText.prefix(200))"
            )
        }

        return try JSONDecoder().decode(TranscriptionAPIResponse.self, from: data)
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

// MARK: - WAV Encoder

/// Encodes Float32 PCM samples to an in-memory WAV file (16-bit signed integer).
/// No disk I/O. The 44-byte header + raw PCM approach is the simplest format
/// that every ASR server accepts.
enum WAVEncoder {

    static func encode(samples: [Float], sampleRate: Int) -> Data {
        let numChannels: Int16 = 1
        let bitsPerSample: Int16 = 16
        let bytesPerSample = Int(bitsPerSample) / 8
        let dataSize = samples.count * bytesPerSample
        let fileSize = 36 + dataSize

        var data = Data(capacity: 44 + dataSize)

        // RIFF header
        data.append(contentsOf: "RIFF".utf8)
        data.appendLittleEndian(UInt32(fileSize))
        data.append(contentsOf: "WAVE".utf8)

        // fmt sub-chunk
        data.append(contentsOf: "fmt ".utf8)
        data.appendLittleEndian(UInt32(16))  // sub-chunk size
        data.appendLittleEndian(UInt16(1))  // PCM format
        data.appendLittleEndian(UInt16(numChannels))
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(UInt32(sampleRate * Int(numChannels) * bytesPerSample))
        data.appendLittleEndian(UInt16(numChannels * Int16(bytesPerSample)))  // block align
        data.appendLittleEndian(UInt16(bitsPerSample))

        // data sub-chunk
        data.append(contentsOf: "data".utf8)
        data.appendLittleEndian(UInt32(dataSize))

        // Convert Float32 → Int16 using vDSP for speed
        var int16Samples = [Int16](repeating: 0, count: samples.count)
        var scale = Float(Int16.max)
        samples.withUnsafeBufferPointer { srcPtr in
            int16Samples.withUnsafeMutableBufferPointer { dstPtr in
                guard let src = srcPtr.baseAddress, let dst = dstPtr.baseAddress else { return }
                var clipped = [Float](repeating: 0, count: samples.count)
                var low: Float = -1.0
                var high: Float = 1.0
                vDSP_vclip(src, 1, &low, &high, &clipped, 1, vDSP_Length(samples.count))
                vDSP_vsmul(clipped, 1, &scale, &clipped, 1, vDSP_Length(samples.count))
                vDSP_vfix16(clipped, 1, dst, 1, vDSP_Length(samples.count))
            }
        }

        // Append raw PCM bytes
        int16Samples.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            data.append(
                UnsafeBufferPointer(
                    start: UnsafeRawPointer(base).assumingMemoryBound(to: UInt8.self),
                    count: dataSize
                )
            )
        }

        return data
    }
}

// MARK: - Data Helpers

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { bytes in
            append(contentsOf: bytes)
        }
    }

    mutating func appendMultipartFile(
        boundary: String, name: String, filename: String,
        contentType: String, data fileData: Data
    ) {
        append(Data("--\(boundary)\r\n".utf8))
        append(Data(
            "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8
        ))
        append(Data("Content-Type: \(contentType)\r\n\r\n".utf8))
        append(fileData)
        append(Data("\r\n".utf8))
    }

    mutating func appendMultipartField(boundary: String, name: String, value: String) {
        append(Data("--\(boundary)\r\n".utf8))
        append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        append(Data("\(value)\r\n".utf8))
    }
}
