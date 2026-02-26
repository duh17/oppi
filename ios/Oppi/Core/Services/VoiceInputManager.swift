import Accelerate
@preconcurrency import AVFoundation
import Foundation
import OSLog
import Speech

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "VoiceInput")

/// On-device speech-to-text using Apple's SpeechAnalyzer API (iOS 26+).
///
/// Streams live audio from the microphone through `SpeechAnalyzer` and
/// `SpeechTranscriber`, returning transcribed text in real time.
///
/// Results are either **volatile** (immediate rough guesses that update
/// as more context arrives) or **finalized** (accurate, won't change).
/// The manager accumulates finalized text and replaces the volatile
/// portion on each update, exposing a combined `currentTranscript`.
///
/// **Key design: transcribers are never reused.** A `SpeechTranscriber`
/// becomes invalid after its analyzer is finalized. We create a fresh
/// transcriber + analyzer pair for each recording session. Pre-warming
/// only checks model availability and caches the audio format.
///
/// Audio engine setup is extracted to a `nonisolated` helper to avoid
/// MainActor isolation violations in the audio tap callback.
@MainActor @Observable
final class VoiceInputManager {

    // MARK: - Types

    enum State: Equatable, Sendable {
        case idle
        case preparingModel
        case recording
        case processing
        case error(String)
    }

    // MARK: - Published State

    private(set) var state: State = .idle
    private(set) var finalizedTranscript = ""
    private(set) var volatileTranscript = ""
    private(set) var audioLevel: Float = 0

    var currentTranscript: String {
        (finalizedTranscript + volatileTranscript)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isRecording: Bool { state == .recording }
    var isProcessing: Bool { state == .processing }
    var isPreparing: Bool { state == .preparingModel }

    // MARK: - Private

    /// Per-session resources — created fresh, torn down after each session.
    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var audioEngine: AVAudioEngine?
    private var resultsTask: Task<Void, Never>?

    /// Cached across sessions — model availability and preferred audio format.
    /// Set during prewarm or first recording. Never invalidated.
    private var modelReady = false
    private var cachedFormat: AVAudioFormat?

    /// In-flight prewarm task. startRecording awaits this instead of racing.
    private var prewarmTask: Task<AVAudioFormat?, Error>?

    /// Operation lock — prevents overlapping async operations.
    /// Guards against edge cases where state changes haven't propagated
    /// to the UI yet (SwiftUI re-render lag) and a second tap sneaks through.
    private var operationInFlight = false

    // MARK: - Init

    init() {}

    // MARK: - Pre-warm

    /// Check model availability and cache audio format in the background.
    /// Call from ChatView's .task {} so the first mic tap is fast.
    /// Does NOT create or retain a SpeechTranscriber (they can't be reused).
    /// Safe to call multiple times — no-ops after first success.
    func prewarm() async {
        guard !modelReady, prewarmTask == nil, state == .idle else { return }

        let task = Task {
            try await Self.warmModel()
        }
        prewarmTask = task

        do {
            let format = try await task.value
            cachedFormat = format
            modelReady = true
            logger.info("Pre-warmed voice model (format: \(String(describing: format)))")
        } catch {
            // Non-fatal — will retry on first mic tap
            logger.warning("Pre-warm failed: \(error.localizedDescription)")
        }
        prewarmTask = nil
    }

    // MARK: - Availability

    /// Whether SpeechTranscriber supports the current locale.
    static func isAvailable() async -> Bool {
        let supported = await SpeechTranscriber.supportedLocales
        return supported.contains {
            $0.identifier(.bcp47) == Locale.current.identifier(.bcp47)
        }
    }

    /// Whether the ML model is already installed for a locale.
    static func isModelInstalled(for locale: Locale) async -> Bool {
        let installed = await SpeechTranscriber.installedLocales
        return installed.contains {
            $0.identifier(.bcp47) == locale.identifier(.bcp47)
        }
    }

    /// All locales with downloadable models.
    static func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }

    // MARK: - Permissions

    /// Check current permission status without prompting.
    static var hasPermissions: Bool {
        let mic = AVAudioApplication.shared.recordPermission == .granted
        let speech = SFSpeechRecognizer.authorizationStatus() == .authorized
        return mic && speech
    }

    /// Request mic + speech permissions. Returns true if both granted.
    func requestPermissions() async -> Bool {
        let mic = await Self.requestMicPermission()
        guard mic else {
            logger.warning("Microphone permission denied")
            return false
        }
        let speech = await Self.requestSpeechPermission()
        guard speech else {
            logger.warning("Speech recognition permission denied")
            return false
        }
        return true
    }

    nonisolated private static func requestMicPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
    }

    nonisolated private static func requestSpeechPermission() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    // MARK: - Recording

    /// Start recording and streaming transcription.
    /// Creates a fresh SpeechTranscriber + SpeechAnalyzer pair each time.
    func startRecording() async throws {
        guard state == .idle else {
            logger.warning("Cannot start: state is \(String(describing: self.state))")
            return
        }
        guard !operationInFlight else {
            logger.warning("Cannot start: operation already in flight")
            return
        }
        operationInFlight = true
        defer { operationInFlight = false }

        finalizedTranscript = ""
        volatileTranscript = ""

        // Check permissions — only prompt if not yet determined
        if !Self.hasPermissions {
            guard await requestPermissions() else {
                state = .error("Microphone or speech permission denied")
                scheduleErrorReset()
                return
            }
        }

        state = .preparingModel
        let startTime = ContinuousClock.now

        do {
            // Phase 1: ensure model is ready (join prewarm or do cold check)
            if let inflight = prewarmTask {
                logger.info("Voice setup: awaiting in-flight prewarm")
                let format = try await inflight.value
                cachedFormat = format
                modelReady = true
                prewarmTask = nil
                let ms = elapsedMs(since: startTime)
                logger.error("Voice setup: joined prewarm in \(ms)ms")
            } else if !modelReady {
                let format = try await Self.warmModel()
                cachedFormat = format
                modelReady = true
                let ms = elapsedMs(since: startTime)
                logger.error("Voice setup: cold model check in \(ms)ms")
            } else {
                logger.error("Voice setup: model ready (0ms)")
            }

            // Phase 2: fresh transcriber + analyzer for this session
            let locale = Locale.current
            let newTranscriber = SpeechTranscriber(
                locale: locale,
                preset: .progressiveTranscription
            )
            transcriber = newTranscriber
            logger.info("Voice setup: created fresh transcriber")

            // Use cached format, or compute if missing
            let format: AVAudioFormat?
            if let cached = cachedFormat {
                format = cached
            } else {
                format = await SpeechAnalyzer.bestAvailableAudioFormat(
                    compatibleWith: [newTranscriber]
                )
                cachedFormat = format
            }

            // Phase 3: start analyzer session
            let newAnalyzer = SpeechAnalyzer(modules: [newTranscriber])
            analyzer = newAnalyzer

            let (sequence, builder) = AsyncStream.makeStream(of: AnalyzerInput.self)
            inputBuilder = builder

            try await newAnalyzer.start(inputSequence: sequence)
            startResultsHandler(transcriber: newTranscriber)
            logger.info("Voice setup: analyzer session started")

            // Phase 4: audio engine
            try setupAudioSession()
            try await startAudioEngine(format: format)

            let totalMs = elapsedMs(since: startTime)
            logger.error("Voice setup: recording started in \(totalMs)ms total")
            state = .recording
        } catch {
            logger.error("Voice setup failed: \(error.localizedDescription)")
            teardownSession()
            state = .error(error.localizedDescription)
            scheduleErrorReset()
            throw error
        }
    }

    /// Stop recording. Finalizes transcription and waits for last results.
    func stopRecording() async {
        guard state == .recording else {
            logger.warning("Cannot stop: state is \(String(describing: self.state))")
            return
        }
        guard !operationInFlight else {
            logger.warning("Cannot stop: operation already in flight")
            return
        }
        operationInFlight = true
        defer { operationInFlight = false }

        state = .processing
        logger.info("Stopping recording")

        // Stop audio input first
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        inputBuilder?.finish()

        // Finalize — tells the analyzer to flush remaining results
        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            logger.error("Error finalizing: \(error.localizedDescription)")
        }

        // Wait for the results stream to drain (terminates when analyzer finishes)
        await resultsTask?.value
        resultsTask = nil

        deactivateAudioSession()
        teardownSession()
        state = .idle
        logger.info("Stopped. Transcript: \(self.currentTranscript.prefix(80))...")
    }

    /// Cancel recording without finalizing. Discards all text.
    func cancelRecording() async {
        guard state == .recording || state == .preparingModel else {
            logger.warning("Cannot cancel: state is \(String(describing: self.state))")
            return
        }
        // Don't check operationInFlight — cancel must always work
        logger.info("Cancelling recording")

        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        inputBuilder?.finish()

        resultsTask?.cancel()
        resultsTask = nil

        await analyzer?.cancelAndFinishNow()

        deactivateAudioSession()
        teardownSession()

        finalizedTranscript = ""
        volatileTranscript = ""
        operationInFlight = false
        state = .idle
    }

    // MARK: - Setup

    /// Check model availability and get preferred audio format.
    /// Creates a temporary transcriber to probe — does not retain it.
    nonisolated private static func warmModel() async throws -> AVAudioFormat? {
        let locale = Locale.current

        // Probe transcriber — used only for model check + format query, then discarded
        let probe = SpeechTranscriber(
            locale: locale,
            preset: .progressiveTranscription
        )

        // Ensure model is downloaded
        let installed = await SpeechTranscriber.installedLocales
        if !installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            logger.info("Downloading speech model for \(locale.identifier)")
            if let request = try await AssetInventory.assetInstallationRequest(
                supporting: [probe]
            ) {
                try await request.downloadAndInstall()
                logger.info("Model download complete")
            }
        } else {
            logger.info("Model already installed for \(locale.identifier)")
        }

        // Get preferred audio format
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [probe]
        )
        logger.info("Analyzer format: \(String(describing: format))")
        return format
    }

    private func setupAudioSession() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: [.defaultToSpeaker]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func deactivateAudioSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        #endif
    }

    private func startAudioEngine(format: AVAudioFormat?) async throws {
        guard let inputBuilder else {
            throw VoiceInputError.internalError("Input builder not initialized")
        }

        // Start engine using nonisolated helper (audio tap runs off MainActor)
        let (engine, levelStream) = try AudioEngineHelper.startEngine(
            inputBuilder: inputBuilder,
            targetFormat: format
        )
        audioEngine = engine

        // Monitor audio levels for waveform
        Task {
            for await level in levelStream {
                self.audioLevel = level
            }
        }
    }

    private func startResultsHandler(transcriber: SpeechTranscriber) {
        let recordingStartTime = ContinuousClock.now
        var firstResultReceived = false

        resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    guard !Task.isCancelled else { break }
                    let now = ContinuousClock.now

                    // Measure time-to-first-result
                    if !firstResultReceived {
                        firstResultReceived = true
                        let elapsed = now - recordingStartTime
                        let ms = Int(elapsed.components.seconds * 1000
                            + elapsed.components.attoseconds / 1_000_000_000_000_000)
                        logger.error("Voice latency: first result in \(ms)ms (type: \(result.isFinal ? "final" : "volatile"))")
                    }

                    // AttributedString -> plain String
                    let text = String(result.text.characters)

                    if result.isFinal {
                        self.finalizedTranscript += text
                        self.volatileTranscript = ""
                        logger.debug("Finalized: \(text)")
                    } else {
                        self.volatileTranscript = text
                        logger.debug("Volatile: \(text)")
                    }
                }
            } catch {
                if !Task.isCancelled {
                    logger.error("Results stream error: \(error.localizedDescription)")
                    self.state = .error("Transcription failed")
                    self.scheduleErrorReset()
                }
            }
        }
    }

    // MARK: - Cleanup

    /// Tear down all per-session resources. Transcriber is never reused —
    /// it becomes invalid after the analyzer is finalized.
    private func teardownSession() {
        transcriber = nil
        analyzer = nil
        inputBuilder = nil
        audioLevel = 0
    }

    private func scheduleErrorReset() {
        Task {
            try? await Task.sleep(for: .seconds(3))
            if case .error = state {
                state = .idle
            }
        }
    }

    // MARK: - Helpers

    private func elapsedMs(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds * 1000
            + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }
}

// MARK: - Testing Support

#if DEBUG
extension VoiceInputManager {
    /// Expose state for testing state machine guards.
    var _testState: State {
        get { state }
        set { state = newValue }
    }

    /// Expose operation lock for testing.
    var _testOperationInFlight: Bool {
        get { operationInFlight }
        set { operationInFlight = newValue }
    }

    /// Expose model readiness for testing.
    var _testModelReady: Bool {
        get { modelReady }
        set { modelReady = newValue }
    }
}
#endif

// MARK: - Errors

enum VoiceInputError: LocalizedError {
    case localeNotSupported(String)
    case internalError(String)

    var errorDescription: String? {
        switch self {
        case .localeNotSupported(let locale):
            "Speech recognition not supported for \(locale)"
        case .internalError(let message):
            message
        }
    }
}

// MARK: - Audio Engine Helper

/// Nonisolated helper for audio engine setup.
/// The audio tap callback runs on the audio thread — accessing
/// @MainActor-isolated properties from it is a Swift 6 error.
private enum AudioEngineHelper {
    static func startEngine(
        inputBuilder: AsyncStream<AnalyzerInput>.Continuation,
        targetFormat: AVAudioFormat?
    ) throws -> (AVAudioEngine, AsyncStream<Float>) {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Create format converter if mic format differs from analyzer format
        let converter: AVAudioConverter?
        if let targetFormat, inputFormat != targetFormat {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        } else {
            converter = nil
        }

        // Audio level stream for waveform visualization
        let (levelStream, levelContinuation) = AsyncStream<Float>.makeStream()

        // Smaller buffer = lower latency. 1024 frames at 48kHz ≈ 21ms per chunk.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            // Calculate RMS audio level using Accelerate (SIMD, single call)
            if let channelData = buffer.floatChannelData?[0] {
                let frameLength = UInt(buffer.frameLength)
                var rms: Float = 0
                vDSP_rmsqv(channelData, 1, &rms, frameLength)
                let level = min(1.0, rms * 25.0)
                levelContinuation.yield(level)
            }

            // Convert buffer to analyzer format if needed
            let outputBuffer: AVAudioPCMBuffer
            if let converter, let targetFormat {
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

            inputBuilder.yield(AnalyzerInput(buffer: outputBuffer))
        }

        engine.prepare()
        try engine.start()

        return (engine, levelStream)
    }
}
