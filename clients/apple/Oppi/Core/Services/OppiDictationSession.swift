import Accelerate
@preconcurrency import AVFoundation
import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "DictationSession")

/// Voice transcription session that streams raw PCM audio over a dictation transport
/// and receives full transcript replacements from the server.
///
/// Streams raw PCM continuously — no client-side chunk timing.
/// Binary frames carry audio; dictation results arrive as `ServerMessage` text frames.
/// - `dictation_result` maps to `.replaceFinalTranscript`, forwarding the
///   backend's committed/active split when available
/// - `dictation_final` maps to a settled `.replaceFinalTranscript(..., snap: true)`
///   when needed, then completes the stream
///
/// **Optimistic recording:** Audio capture starts immediately on `start()`. A background
/// drain task blocks on `readinessTask` (WS `dictation_ready`) before forwarding audio,
/// so the UI shows `.recording` with live waveform while the network round-trip completes.
@MainActor
final class OppiDictationSession: VoiceTranscriptionSession {
    let events: AsyncThrowingStream<VoiceSessionEvent, Error>
    let audioLevels: AsyncStream<Float>

    private let transport: any DictationTransport
    /// Resolves once the server sends `dictation_ready`. Audio is buffered until then.
    private let readinessTask: Task<DictationProviderInfo?, Error>
    /// Recording-scoped message stream, routed from the active dictation transport.
    private let recordingMessages: AsyncStream<ServerMessage>
    private let eventContinuation: AsyncThrowingStream<VoiceSessionEvent, Error>.Continuation
    private let audioLevelContinuation: AsyncStream<Float>.Continuation
    private var messageListenTask: Task<Void, Never>?
    /// Drains the audio stream to the WS, waiting for readiness first.
    private var audioDrainTask: Task<Void, Never>?
    /// Feeds raw PCM chunks from the audio tap into the drain task.
    private var audioContinuation: AsyncStream<Data>.Continuation?
    /// Pending audio stream, transferred to the drain task on start.
    private var pendingAudioStream: AsyncStream<Data>?
    private var audioEngine: AVAudioEngine?
    private var audioLevelTask: Task<Void, Never>?
    private var hasCapturedAudio = false
    /// Actual route/formats observed after this engine started, not a requested preference.
    private var captureMetadata: [String: String]?
    private var stopped = false
    private struct TranscriptUpdate: Equatable {
        let text: String
        let snap: Bool
        let committedText: String?
        let activeText: String?
    }

    /// Last transcript replacement yielded to the UI. Includes settle state and
    /// the backend committed/active split so same-text updates still propagate
    /// when their semantic split changes.
    private var lastTranscriptUpdate: TranscriptUpdate?

    init(
        transport: any DictationTransport,
        readinessTask: Task<DictationProviderInfo?, Error>,
        messages: AsyncStream<ServerMessage>
    ) {
        self.transport = transport
        self.readinessTask = readinessTask
        self.recordingMessages = messages

        let (events, eventContinuation) = AsyncThrowingStream.makeStream(of: VoiceSessionEvent.self)
        self.events = events
        self.eventContinuation = eventContinuation

        let (audioLevels, audioLevelContinuation) = AsyncStream.makeStream(of: Float.self)
        self.audioLevels = audioLevels
        self.audioLevelContinuation = audioLevelContinuation
    }

    func start() async throws -> VoiceSessionStartTimings {
        let analyzerStart = ContinuousClock.now

        // Start listening for server messages
        startMessageListener()
        let analyzerStartMs = analyzerStart.elapsedMs()

        // Start audio engine with conversion to 16kHz mono
        let audioStart = ContinuousClock.now
        try await startAudioCapture()
        let audioStartMs = audioStart.elapsedMs()

        // Begin draining audio to WS in background (blocks on readinessTask first)
        startAudioDrainTask()

        return VoiceSessionStartTimings(
            analyzerStartMs: analyzerStartMs,
            audioStartMs: audioStartMs
        )
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true

        stopAudioEngine()
        // Close the audio stream so the drain task's for-await loop exits naturally
        audioContinuation?.finish()
        audioContinuation = nil

        // Wait for the drain task to flush all buffered audio before signalling stop.
        // This ensures no audio is lost if the WS was still connecting.
        await audioDrainTask?.value
        audioDrainTask = nil

        // Send stop, wait for final transcript
        do {
            try await transport.sendDictation(.dictationStop)
            logger.info("Sent dictation_stop, waiting for final")
        } catch {
            logger.error("Failed to send dictation_stop: \(error.localizedDescription, privacy: .public)")
        }

        // Wait for the message listener to finish (it completes on dictation_final or error)
        await messageListenTask?.value
        cleanup()
    }

    func cancel() async {
        guard !stopped else { return }
        stopped = true

        stopAudioEngine()
        audioContinuation?.finish()
        audioContinuation = nil

        // Cancel background setup and drain — no audio to flush on cancel
        readinessTask.cancel()
        audioDrainTask?.cancel()
        audioDrainTask = nil

        do {
            try await transport.sendDictation(.dictationCancel)
        } catch {
            logger.debug("Failed to send dictation_cancel: \(error.localizedDescription, privacy: .public)")
        }

        messageListenTask?.cancel()
        messageListenTask = nil
        cleanup()
    }

    // MARK: - Audio Capture

    /// Start the audio engine via a non-actor helper.
    /// The `installTap` closure MUST NOT inherit @MainActor isolation —
    /// it runs on the real-time audio thread and libdispatch will crash
    /// with `EXC_BREAKPOINT: Block was expected to execute on queue
    /// [com.apple.main-thread]` if the closure carries MainActor context.
    ///
    /// PCM chunks are yielded into `pendingAudioStream` via `audioContinuation`.
    /// `AsyncStream.Continuation.yield()` is thread-safe and safe to call
    /// directly from the RT audio thread without dispatch indirection.
    private func startAudioCapture() async throws {
        try await DictationAudioEngineHelper.startWithFirstAudio(
            start: { try self.startCaptureAttempt() },
            hasAudio: { self.hasCapturedAudio },
            isRunning: { self.audioEngine?.isRunning == true },
            stop: {
                self.stopAudioEngine()
                self.audioContinuation?.finish()
                self.audioContinuation = nil
                self.pendingAudioStream = nil
            },
            isCancelled: { self.stopped }
        )
        if let audioEngine {
            captureMetadata = DictationAudioEngineHelper.captureMetadata(engine: audioEngine)
            ClientLog.info("VoiceInput", "Dictation audio engine started", metadata: captureMetadata ?? [:])
        }
        logger.info("Audio capture delivering PCM (16kHz, 16-bit, mono)")
    }

    private func startCaptureAttempt() throws {
        hasCapturedAudio = false
        let (audioStream, audioContinuation) = AsyncStream<Data>.makeStream()
        self.audioContinuation = audioContinuation
        self.pendingAudioStream = audioStream

        let (engine, levelStream) = try DictationAudioEngineHelper.startEngine(
            audioContinuation: audioContinuation
        )
        self.audioEngine = engine

        // Drain level stream in the background (inherits MainActor from class)
        audioLevelTask = Task { [weak self] in
            for await level in levelStream {
                guard !Task.isCancelled else { return }
                self?.hasCapturedAudio = true
                self?.audioLevelContinuation.yield(level)
            }
        }

    }

    /// Starts a background task that:
    /// 1. Waits for `dictation_ready` (via readinessTask)
    /// 2. Forwards all buffered + subsequent PCM chunks to the WS
    ///
    /// If WS setup fails, the event stream is finished with the error
    /// so `VoiceInputManager` transitions to `.error` state.
    private func startAudioDrainTask() {
        guard let audioStream = pendingAudioStream else { return }
        pendingAudioStream = nil

        let transport = self.transport
        let readinessTask = self.readinessTask
        let eventContinuation = self.eventContinuation
        let captureMetadata = self.captureMetadata

        audioDrainTask = Task {
            // Block until server is ready (or fails)
            do {
                let info = try await readinessTask.value
                // Emit provider metadata so VoiceInputManager can update metric tags
                // with the actual stt_backend and model (unknown at setup time).
                if let info {
                    eventContinuation.yield(.providerMetricTags([
                        "stt_backend": info.sttProvider,
                        "model": info.sttModel,
                    ]))
                }
            } catch is CancellationError {
                // Cancelled by cancel() — clean exit, no error to surface
                return
            } catch {
                logger.error("Dictation setup failed: \(error.localizedDescription, privacy: .public)")
                eventContinuation.finish(throwing: error)
                return
            }

            // Server is ready — pipe all audio (buffered + live) as binary frames.
            // Surface send failures instead of swallowing them so the manager can
            // stop recording and show a real error when the WS drops mid-dictation.
            var loggedFirstAudio = false
            for await chunk in audioStream {
                guard !Task.isCancelled else { break }
                do {
                    try await transport.sendDictationAudio(chunk)
                    if !loggedFirstAudio, !chunk.isEmpty, var metadata = captureMetadata {
                        loggedFirstAudio = true
                        metadata["pcm_bytes"] = String(chunk.count)
                        // One log per capture, outside the real-time tap. The route
                        // snapshot belongs to this engine, even if upload was delayed.
                        ClientLog.info("VoiceInput", "Dictation first PCM chunk sent", metadata: metadata)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    logger.error("Failed to send dictation audio: \(error.localizedDescription, privacy: .public)")
                    eventContinuation.finish(throwing: Self.surfacedDisconnectError(for: error))
                    return
                }
            }
        }
    }

    private func stopAudioEngine() {
        audioLevelTask?.cancel()
        audioLevelTask = nil
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
    }

    // MARK: - PCM Conversion

    /// Convert float32 PCM buffer to 16-bit signed integer PCM data (little-endian).
    nonisolated static func convertToInt16PCM(buffer: AVAudioPCMBuffer) -> Data {
        guard let floatData = buffer.floatChannelData?[0] else { return Data() }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return Data() }

        var data = Data(count: frameLength * 2)
        data.withUnsafeMutableBytes { rawBuffer in
            guard let int16Ptr = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return }
            for i in 0..<frameLength {
                // Clamp float [-1.0, 1.0] to Int16 range
                let sample = max(-1.0, min(1.0, floatData[i]))
                int16Ptr[i] = Int16(sample * Float(Int16.max))
            }
        }
        return data
    }

    // MARK: - Server Message Handling

    private func startMessageListener() {
        // Use the recording-scoped stream from OppiDictationProvider.
        // It ends when the provider finishes it (on dictation_final or transport disconnect).
        let stream = recordingMessages
        messageListenTask = Task { [weak self] in
            for await message in stream {
                guard !Task.isCancelled else { break }
                guard let self else { break }

                switch message {
                case .dictationReady:
                    logger.debug("dictation_ready received (recording started)")

                case .dictationResult(let text, let snap, let split):
                    logger.debug("Dictation result: \(text.count) chars\(snap ? " (snap)" : "")")
                    yieldTranscriptIfChanged(
                        text,
                        snap: snap,
                        committedText: split?.committedText,
                        activeText: split?.activeText
                    )

                case .dictationFinal(let text, let split):
                    logger.info("Dictation final: \(text.count) chars")
                    yieldTranscriptIfChanged(
                        text,
                        snap: true,
                        committedText: split?.committedText,
                        activeText: split?.activeText
                    )
                    eventContinuation.finish()
                    return

                case .dictationError(let error, let fatal):
                    logger.error("Dictation error (fatal=\(fatal)): \(error, privacy: .public)")
                    if fatal {
                        eventContinuation.finish(
                            throwing: VoiceInputError.internalError("Server error: \(error)")
                        )
                        return
                    }

                default:
                    break // Ignore non-dictation messages
                }
            }

            guard let self else { return }
            if Task.isCancelled {
                return
            }

            // Stream ended without dictation_final (WS dropped, provider routing ended, etc.).
            logger.error("Dictation message stream ended before final transcript")
            self.eventContinuation.finish(throwing: Self.disconnectError())
        }
    }

    private func yieldTranscriptIfChanged(
        _ text: String,
        snap: Bool = false,
        committedText: String? = nil,
        activeText: String? = nil
    ) {
        guard !text.isEmpty else { return }
        if let lastTranscriptUpdate,
           lastTranscriptUpdate.text == text,
           lastTranscriptUpdate.snap == snap,
           lastTranscriptUpdate.committedText == committedText,
           lastTranscriptUpdate.activeText == activeText {
            return
        }
        lastTranscriptUpdate = TranscriptUpdate(
            text: text,
            snap: snap,
            committedText: committedText,
            activeText: activeText
        )
        eventContinuation.yield(
            .replaceFinalTranscript(
                text,
                snap: snap,
                committedText: committedText,
                activeText: activeText
            )
        )
    }

    private nonisolated static func disconnectError() -> VoiceInputError {
        .internalError("Dictation connection lost")
    }

    private nonisolated static func surfacedDisconnectError(for error: Error) -> Error {
        if let wsError = error as? WebSocketError,
           case .notConnected = wsError {
            return disconnectError()
        }
        return error
    }

    private func cleanup() {
        audioDrainTask = nil
        audioContinuation = nil
        pendingAudioStream = nil
        messageListenTask = nil
        lastTranscriptUpdate = nil
        eventContinuation.finish()
        audioLevelContinuation.finish()
        transport.closeDictationTransport()
    }
}

#if DEBUG
extension OppiDictationSession {
    // periphery:ignore - used by OppiDictationProviderTests via @testable import
    func _startMessageListenerForTesting() {
        startMessageListener()
    }

    // periphery:ignore - used by OppiDictationProviderTests via @testable import
    func _setPendingAudioStreamForTesting(_ stream: AsyncStream<Data>) {
        pendingAudioStream = stream
    }

    // periphery:ignore - used by OppiDictationProviderTests via @testable import
    func _startAudioDrainTaskForTesting() {
        startAudioDrainTask()
    }
}
#endif

// MARK: - Non-actor audio engine helper

/// Starts the AVAudioEngine + installTap outside any actor context.
/// The installTap closure runs on the real-time audio thread.
/// If it inherits @MainActor (from OppiDictationSession), libdispatch
/// crashes with EXC_BREAKPOINT. This plain enum has no actor isolation.
///
/// PCM chunks are yielded into `audioContinuation` directly from the RT thread.
/// `AsyncStream.Continuation.yield()` is thread-safe and does not create Tasks,
/// so it is safe to call from the real-time audio callback.
enum DictationAudioEngineHelper {
    @MainActor
    static func startWithFirstAudio(
        start: () throws -> Void,
        hasAudio: () -> Bool,
        isRunning: () -> Bool,
        stop: () -> Void,
        isCancelled: () -> Bool,
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws {
        // A hardware format change can stop AVAudioEngine during start(),
        // without start() throwing. Require a running engine AND real tap audio.
        // Rebuild once on the same route, outside any configuration-change
        // notification callback (Apple warns against teardown in that callback).
        for attempt in 0..<2 {
            try Task.checkCancellation()
            guard !isCancelled() else { throw CancellationError() }
            do {
                try start()
                for _ in 0..<20 {
                    try Task.checkCancellation()
                    guard !isCancelled() else { throw CancellationError() }
                    guard isRunning() else { break }
                    if hasAudio() { return }
                    try await sleep(.milliseconds(50))
                }
                throw VoiceInputError.audioCaptureUnavailable
            } catch {
                let wasRunning = isRunning()
                stop()
                if error is CancellationError || isCancelled() { throw CancellationError() }
                guard attempt == 0 else { throw error }
                ClientLog.warning("VoiceInput", "Rebuilding capture after missing first audio or engine start failure", metadata: [
                    "engine_running": String(wasRunning),
                    "error_domain": (error as NSError).domain,
                    "error_code": String((error as NSError).code),
                ])
                try await sleep(.milliseconds(250))
            }
        }
    }

    static func startEngine(
        audioContinuation: AsyncStream<Data>.Continuation
    ) throws -> (AVAudioEngine, AsyncStream<Float>) {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        try AudioEngineHelper.validateInputFormat(inputFormat)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw VoiceInputError.internalError("Cannot create 16kHz mono format")
        }

        let converter: AVAudioConverter?
        if inputFormat != targetFormat {
            guard let audioConverter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                throw VoiceInputError.internalError("Cannot create dictation audio converter")
            }
            converter = audioConverter
        } else {
            converter = nil
        }

        let (levelStream, levelContinuation) = AsyncStream<Float>.makeStream()

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            let outputBuffer: AVAudioPCMBuffer
            if let converter {
                let frameCapacity = AVAudioFrameCount(
                    Double(buffer.frameLength) * targetFormat.sampleRate / inputFormat.sampleRate
                )
                guard let converted = AVAudioPCMBuffer(
                    pcmFormat: targetFormat,
                    frameCapacity: frameCapacity
                ) else { return }

                var error: NSError?
                converter.convert(to: converted, error: &error) { _, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }
                if error != nil { return }
                outputBuffer = converted
            } else {
                outputBuffer = buffer
            }

            guard outputBuffer.frameLength > 0 else { return }
            // Audio level — AsyncStream.Continuation.yield() is thread-safe
            if let channelData = outputBuffer.floatChannelData?[0] {
                let frameLength = UInt(outputBuffer.frameLength)
                var rms: Float = 0
                vDSP_rmsqv(channelData, 1, &rms, frameLength)
                let level = min(1.0, rms * 25.0)
                levelContinuation.yield(level)
            }

            // Yield PCM chunk to the audio stream — the drain task forwards
            // to WS once dictation_ready is received
            let pcmData = OppiDictationSession.convertToInt16PCM(buffer: outputBuffer)
            guard !pcmData.isEmpty else { return }
            audioContinuation.yield(pcmData)
        }

        engine.prepare()
        ClientLog.info("VoiceInput", "Dictation audio engine starting", metadata: captureMetadata(engine: engine))
        do {
            try engine.start()
        } catch {
            var metadata = captureMetadata(engine: engine)
            metadata["error_domain"] = (error as NSError).domain
            metadata["error_code"] = String((error as NSError).code)
            ClientLog.error("VoiceInput", "Dictation audio engine start failed", metadata: metadata)
            // The session doesn't own this engine until we return. Tear down
            // partial capture here so a fallback can acquire the microphone.
            inputNode.removeTap(onBus: 0)
            engine.stop()
            levelContinuation.finish()
            throw error
        }
        return (engine, levelStream)
    }

    /// Port types only: never upload Bluetooth names or hardware identifiers.
    static func captureMetadata(engine: AVAudioEngine) -> [String: String] {
        let input = engine.inputNode.inputFormat(forBus: 0)
        // Do not access outputNode for diagnostics: it is created on demand
        // and can change this input-only graph. Read session output state instead.
        var metadata = [
            "input_hz": String(input.sampleRate),
            "input_channels": String(input.channelCount),
            "engine_running": String(engine.isRunning),
        ]
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        metadata["category"] = session.category.rawValue
        metadata["mode"] = session.mode.rawValue
        metadata["session_hz"] = String(session.sampleRate)
        metadata["session_output_channels"] = String(session.outputNumberOfChannels)
        metadata["input_ports"] = session.currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: ",")
        metadata["output_ports"] = session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        #endif
        return metadata
    }
}


