import Accelerate
@preconcurrency import AVFoundation
import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "DictationSession")

/// Readiness shares the PCM drain's ordering lane; only that drain sends audio.
enum DictationAudioInput: Sendable {
    case pcm(Data)
    case ready(DictationProviderInfo?)
}

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
/// drain task retains PCM losslessly until `readinessTask` (WS `dictation_ready`) resolves,
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
    /// Consumes immediately, retaining pre-ready PCM before sending on the WS.
    private var audioDrainTask: Task<Void, Never>?
    private var audioReadinessTask: Task<Void, Never>?
    /// Both tap PCM and readiness enter the same serial drain.
    private var audioContinuation: AsyncStream<DictationAudioInput>.Continuation?
    private var pendingAudioStream: AsyncStream<DictationAudioInput>?
    /// 16 seconds of 16kHz mono Int16, covering the provider's 10s ready timeout
    /// plus scheduling slack. Crossing either queue bound fails the whole take.
    nonisolated static let preReadyPCMByteLimit = 512 * 1024
    private var audioEngine: AVAudioEngine?
    private var audioLevelTask: Task<Void, Never>?
    private var hasCapturedAudio = false
    /// Actual route/formats observed after this engine started, not a requested preference.
    private var captureMetadata: [String: String]?
    private var stopped = false
    private var readinessResolved = false
    private var terminalError: Error?
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

        // Capture/converter failures can originate on the audio thread. Events
        // remain the first terminal publisher; wake Stop's receive-side wait too.
        eventContinuation.onTermination = { [weak self] termination in
            guard case .finished(let error) = termination, let error else { return }
            Task { @MainActor [weak self] in self?.failSession(error) }
        }
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

        // Consume tap audio immediately; readiness gates sending, not capture.
        startAudioDrainTask()

        return VoiceSessionStartTimings(
            analyzerStartMs: analyzerStartMs,
            audioStartMs: audioStartMs
        )
    }

    func rebuildAudioCapture() async throws {
        guard !stopped, audioContinuation != nil else {
            throw VoiceInputError.audioCaptureUnavailable
        }
        stopAudioEngine()
        try await startAudioCapture(replacingStream: false)
        if let audioEngine {
            captureMetadata = DictationAudioEngineHelper.captureMetadata(engine: audioEngine)
            ClientLog.info("VoiceInput", "Dictation audio engine rebuilt", metadata: captureMetadata ?? [:])
        }
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        defer { cleanup() }

        stopAudioEngine()
        // Readiness closes the drain after its marker when Stop arrives first.
        // A terminal failure can also close it immediately, without waiting for
        // a readiness task or receive stream that can no longer deliver a final.
        if readinessResolved || audioReadinessTask == nil || terminalError != nil {
            audioContinuation?.finish()
        }
        await audioDrainTask?.value
        audioDrainTask = nil
        guard terminalError == nil else { return }

        // Only a healthy take can request and await a final transcript.
        do {
            try await transport.sendDictation(.dictationStop)
            logger.info("Sent dictation_stop, waiting for final")
        } catch {
            logger.error("Failed to send dictation_stop: \(error.localizedDescription, privacy: .public)")
            failSession(Self.surfacedDisconnectError(for: error))
        }

        // Failure cancels this listener, but Stop remains the sole cleanup owner.
        await messageListenTask?.value
    }

    func cancel() async {
        guard !stopped else { return }
        stopped = true

        stopAudioEngine()
        audioContinuation?.finish()
        audioContinuation = nil

        // Cancel background setup and drain — no audio to flush on cancel
        readinessTask.cancel()
        audioReadinessTask?.cancel()
        audioReadinessTask = nil
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
    private func startAudioCapture(replacingStream: Bool = true) async throws {
        try await DictationAudioEngineHelper.startWithFirstAudio(
            start: { try self.startCaptureAttempt(replacingStream: replacingStream) },
            hasAudio: { self.hasCapturedAudio },
            isRunning: { self.audioEngine?.isRunning == true },
            stop: {
                self.stopAudioEngine()
                guard replacingStream else { return }
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

    private func startCaptureAttempt(replacingStream: Bool) throws {
        hasCapturedAudio = false
        if replacingStream || audioContinuation == nil {
            let (audioStream, audioContinuation) = Self.makeAudioInputStream()
            self.audioContinuation = audioContinuation
            self.pendingAudioStream = audioStream
        }
        guard let audioContinuation else {
            throw VoiceInputError.internalError("Dictation audio stream missing")
        }

        let (engine, levelStream) = try DictationAudioEngineHelper.startEngine(
            audioContinuation: audioContinuation,
            events: eventContinuation
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

    nonisolated private static func makeAudioInputStream() -> (
        stream: AsyncStream<DictationAudioInput>,
        continuation: AsyncStream<DictationAudioInput>.Continuation
    ) {
        AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(DictationAudioEngineHelper.pcmBufferLimit))
    }

    /// Read PCM immediately so waiting for dictation_ready cannot look like a
    /// dead microphone. A bounded pre-ready backlog retains the beginning of the
    /// take; overflow is a terminal error, never a transient missing heartbeat.
    private func startAudioDrainTask() {
        guard let audioStream = pendingAudioStream, let audioContinuation else { return }
        pendingAudioStream = nil

        let transport = self.transport
        let readinessTask = self.readinessTask
        let eventContinuation = self.eventContinuation
        let captureMetadata = self.captureMetadata

        audioReadinessTask = Task { [weak self] in
            do {
                let info = try await readinessTask.value
                try Task.checkCancellation()
                guard let self else { return }
                readinessResolved = true
                _ = AudioEngineHelper.enqueueCaptureInput(
                    DictationAudioInput.ready(info), into: audioContinuation, events: eventContinuation
                )
                if stopped { audioContinuation.finish() }
            } catch is CancellationError {
                audioContinuation.finish()
            } catch {
                logger.error("Dictation setup failed: \(error.localizedDescription, privacy: .public)")
                self?.failSession(error)
            }
        }

        audioDrainTask = Task { [weak self] in
            var ready = false
            var preReadyChunks: [Data] = []
            var preReadyBytes = 0
            var loggedFirstAudio = false

            @MainActor func send(_ chunk: Data) async throws {
                try Task.checkCancellation()
                try await transport.sendDictationAudio(chunk)
                if !loggedFirstAudio, !chunk.isEmpty, var metadata = captureMetadata {
                    loggedFirstAudio = true
                    metadata["pcm_bytes"] = String(chunk.count)
                    // The route snapshot belongs to this capture even if upload was delayed.
                    ClientLog.info("VoiceInput", "Dictation first PCM chunk sent", metadata: metadata)
                }
            }

            do {
                for await input in audioStream {
                    try Task.checkCancellation()
                    switch input {
                    case .ready(let info):
                        ready = true
                        if let info {
                            eventContinuation.yield(.providerMetricTags([
                                "stt_backend": info.sttProvider,
                                "model": info.sttModel,
                            ]))
                        }
                        for chunk in preReadyChunks { try await send(chunk) }
                        preReadyChunks.removeAll()
                        preReadyBytes = 0
                    case .pcm(let chunk):
                        if ready {
                            try await send(chunk)
                        } else {
                            guard chunk.count <= Self.preReadyPCMByteLimit - preReadyBytes else {
                                throw AudioEngineHelper.captureOverflowError
                            }
                            preReadyChunks.append(chunk)
                            preReadyBytes += chunk.count
                        }
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                logger.error("Dictation audio drain failed: \(error.localizedDescription, privacy: .public)")
                self?.failSession(Self.surfacedDisconnectError(for: error))
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
                        failSession(VoiceInputError.internalError("Server error: \(error)"))
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
            self.failSession(Self.disconnectError())
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

    private func failSession(_ error: Error) {
        guard terminalError == nil else { return }
        terminalError = error
        eventContinuation.finish(throwing: error)
        audioContinuation?.finish()
        readinessTask.cancel()
        audioReadinessTask?.cancel()
        audioDrainTask?.cancel()
        messageListenTask?.cancel()
        // Do not clean up here or call cancel(): Stop may already own teardown.
        // Cancelling its impossible waits lets that same owner release hardware.
    }

    private func cleanup() {
        audioReadinessTask?.cancel()
        audioReadinessTask = nil
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
        _installPCMInputForTesting()
        guard let audioContinuation else { return }
        let events = eventContinuation
        let feeder = Task { [weak self] in
            for await chunk in stream {
                guard AudioEngineHelper.enqueueCaptureInput(
                    DictationAudioInput.pcm(chunk), into: audioContinuation, events: events
                ) else { return }
            }
            await self?.audioReadinessTask?.value
            audioContinuation.finish()
        }
        audioContinuation.onTermination = { _ in feeder.cancel() }
    }

    // periphery:ignore - uses the production queue and enqueue boundary, without microphone hardware
    func _installPCMInputForTesting() {
        let pair = Self.makeAudioInputStream()
        audioContinuation = pair.continuation
        pendingAudioStream = pair.stream
    }

    // periphery:ignore - exercises tap delivery and its heartbeat
    func _enqueuePCMForTesting(_ data: Data) -> Bool {
        guard let audioContinuation else { return false }
        return AudioEngineHelper.enqueueCaptureInput(
            DictationAudioInput.pcm(data), into: audioContinuation, events: eventContinuation
        )
    }

    // periphery:ignore - production tap conversion and terminal publisher, without microphone hardware
    func _feedCaptureBufferForTesting(
        _ buffer: AVAudioPCMBuffer, converter: AVAudioConverter,
        allocateBuffer: (AVAudioFormat, AVAudioFrameCount) -> AVAudioPCMBuffer?
    ) -> Bool {
        guard let audioContinuation else { return false }
        return DictationAudioEngineHelper.feedCaptureBuffer(
            buffer, converter: converter, inputFormat: converter.inputFormat, targetFormat: converter.outputFormat,
            into: audioContinuation, events: eventContinuation, allocateBuffer: allocateBuffer
        ) != nil
    }

    // periphery:ignore - deterministic drain barrier
    func _waitForAudioDrainForTesting() async {
        await audioReadinessTask?.value
        audioContinuation?.finish()
        await audioDrainTask?.value
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
    static let pcmBufferLimit = 32
    /// Fallback wait if first PCM is not latched after yielding MainActor.
    /// 50ms buckets sat on the 350ms warm dictation setup SLO.
    static let firstAudioPollInterval: Duration = .milliseconds(10)
    static let firstAudioPollAttempts = 100

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
                // engine.start() blocks MainActor; the RT tap can queue first
                // PCM before the level latch runs. Yield so already-delivered
                // audio can complete without a poll bucket.
                if hasAudio() { return }
                await Task.yield()
                for _ in 0..<firstAudioPollAttempts {
                    try Task.checkCancellation()
                    guard !isCancelled() else { throw CancellationError() }
                    guard isRunning() else { break }
                    if hasAudio() { return }
                    try await sleep(firstAudioPollInterval)
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
        audioContinuation: AsyncStream<DictationAudioInput>.Continuation,
        events: AsyncThrowingStream<VoiceSessionEvent, Error>.Continuation
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
            guard let outputBuffer = feedCaptureBuffer(
                buffer, converter: converter, inputFormat: inputFormat, targetFormat: targetFormat,
                into: audioContinuation, events: events
            ) else { return }

            if let channelData = outputBuffer.floatChannelData?[0] {
                let frameLength = UInt(outputBuffer.frameLength)
                var rms: Float = 0
                vDSP_rmsqv(channelData, 1, &rms, frameLength)
                let level = min(1.0, rms * 25.0)
                levelContinuation.yield(level)
            }
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

    /// Returns only successfully queued PCM for the tap's delivery heartbeat.
    static func feedCaptureBuffer(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter?,
        inputFormat: AVAudioFormat,
        targetFormat: AVAudioFormat,
        into audioContinuation: AsyncStream<DictationAudioInput>.Continuation,
        events: AsyncThrowingStream<VoiceSessionEvent, Error>.Continuation,
        allocateBuffer: (AVAudioFormat, AVAudioFrameCount) -> AVAudioPCMBuffer? = {
            AVAudioPCMBuffer(pcmFormat: $0, frameCapacity: $1)
        }
    ) -> AVAudioPCMBuffer? {
        do {
            let outputBuffer: AVAudioPCMBuffer
            if let converter {
                guard let converted = try AudioEngineHelper.convertCaptureBuffer(
                    buffer, converter: converter, inputFormat: inputFormat,
                    targetFormat: targetFormat, allocateBuffer: allocateBuffer
                ) else { return nil }
                outputBuffer = converted
            } else {
                outputBuffer = buffer
            }
            guard outputBuffer.frameLength > 0 else { return nil }
            let pcmData = OppiDictationSession.convertToInt16PCM(buffer: outputBuffer)
            guard !pcmData.isEmpty else {
                throw VoiceInputError.internalError("Microphone PCM data unavailable")
            }
            // A queued PCM chunk is real capture, including before readiness.
            guard AudioEngineHelper.enqueueCaptureInput(
                DictationAudioInput.pcm(pcmData), into: audioContinuation, events: events
            ) else { return nil }
            return outputBuffer
        } catch {
            AudioEngineHelper.failCaptureConversion(error, into: audioContinuation, events: events)
            return nil
        }
    }

    /// Port types only: never upload Bluetooth names or hardware identifiers.
    static func sessionRouteMetadata() -> [String: String] {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        return [
            "category": session.category.rawValue,
            "mode": session.mode.rawValue,
            "session_hz": String(session.sampleRate),
            "input_ports": session.currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: ","),
            "output_ports": session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ","),
        ]
        #else
        return [:]
        #endif
    }

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


