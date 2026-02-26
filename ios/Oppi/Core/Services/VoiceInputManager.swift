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

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var analyzerFormat: AVAudioFormat?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var audioEngine: AVAudioEngine?
    private var resultsTask: Task<Void, Never>?

    /// Whether the transcriber pipeline has been pre-warmed (model checked,
    /// transcriber + analyzer created). Avoids repeating on every mic tap.
    private var isPrewarmed = false

    // MARK: - Init

    init() {}

    // MARK: - Pre-warm

    /// Pre-create the transcriber and analyzer so the first mic tap is fast.
    /// Call from ChatView's .task {} to warm up in the background.
    /// Safe to call multiple times — no-ops after first success.
    func prewarm() async {
        guard !isPrewarmed, state == .idle else { return }
        do {
            try await setupTranscriber()
            isPrewarmed = true
            logger.info("Pre-warmed voice input pipeline")
        } catch {
            // Non-fatal — will retry on first mic tap
            logger.warning("Pre-warm failed: \(error.localizedDescription)")
        }
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
    /// Uses the device locale. The model handles mixed languages natively.
    func startRecording() async throws {
        guard state == .idle else {
            logger.warning("Cannot start: state is \(String(describing: self.state))")
            return
        }

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
            // Phase 1: transcriber + model (skipped if pre-warmed)
            if !isPrewarmed {
                try await setupTranscriber()
                isPrewarmed = true
                let setupMs = Int((ContinuousClock.now - startTime).components.seconds * 1000
                    + (ContinuousClock.now - startTime).components.attoseconds / 1_000_000_000_000_000)
                logger.error("Voice setup: transcriber in \(setupMs)ms")
            } else {
                logger.error("Voice setup: pre-warmed (0ms)")
            }
            // Phase 2: analyzer session (fresh each recording)
            try await startAnalyzerSession()
            try setupAudioSession()
            try await startAudioEngine()
            let totalMs = Int((ContinuousClock.now - startTime).components.seconds * 1000
                + (ContinuousClock.now - startTime).components.attoseconds / 1_000_000_000_000_000)
            logger.error("Voice setup: recording started in \(totalMs)ms total")
            state = .recording
        } catch {
            state = .error(error.localizedDescription)
            scheduleErrorReset()
            throw error
        }
    }

    /// Stop recording. Finalizes transcription and waits for last results.
    func stopRecording() async {
        guard state == .recording else { return }
        state = .processing
        logger.info("Stopping recording")

        // Stop audio input
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

        // Wait for the results stream to drain (it terminates when analyzer finishes)
        await resultsTask?.value
        resultsTask = nil

        deactivateAudioSession()
        cleanup()
        state = .idle
        logger.info("Stopped. Transcript: \(self.currentTranscript.prefix(80))...")
    }

    /// Cancel recording without finalizing. Discards all text.
    func cancelRecording() async {
        logger.info("Cancelling recording")

        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        inputBuilder?.finish()

        resultsTask?.cancel()
        resultsTask = nil

        await analyzer?.cancelAndFinishNow()

        deactivateAudioSession()
        cleanup()

        finalizedTranscript = ""
        volatileTranscript = ""
        state = .idle
    }

    // MARK: - Setup

    /// Phase 1: Create transcriber, check model, get format. Can be pre-warmed.
    private func setupTranscriber() async throws {
        // Use device locale — the model handles mixed languages natively
        let locale = Locale.current

        // Use Apple's optimized preset for real-time streaming with volatile results.
        // This likely enables internal latency optimizations vs manual options.
        let newTranscriber = SpeechTranscriber(
            locale: locale,
            preset: .progressiveTranscription
        )
        transcriber = newTranscriber

        // Ensure model is downloaded
        try await ensureModel(transcriber: newTranscriber, locale: locale)

        // Get preferred audio format for conversion.
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [newTranscriber]
        )
        logger.info("Analyzer format: \(String(describing: self.analyzerFormat))")
    }

    /// Phase 2: Create analyzer + input stream, start session. Called each recording.
    private func startAnalyzerSession() async throws {
        guard let currentTranscriber = transcriber else {
            throw VoiceInputError.internalError("Transcriber not initialized")
        }

        let newAnalyzer = SpeechAnalyzer(modules: [currentTranscriber])
        analyzer = newAnalyzer

        let (sequence, builder) = AsyncStream.makeStream(of: AnalyzerInput.self)
        inputBuilder = builder

        try await newAnalyzer.start(inputSequence: sequence)
        startResultsHandler(transcriber: currentTranscriber)
    }

    private func ensureModel(transcriber: SpeechTranscriber, locale: Locale) async throws {
        let installed = await SpeechTranscriber.installedLocales
        if installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            logger.info("Model already installed for \(locale.identifier)")
            return
        }

        logger.info("Downloading speech model for \(locale.identifier)")
        if let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) {
            try await request.downloadAndInstall()
            logger.info("Model download complete")
        }
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

    private func startAudioEngine() async throws {
        guard let inputBuilder else {
            throw VoiceInputError.internalError("Input builder not initialized")
        }

        let targetFormat = analyzerFormat

        // Start engine using nonisolated helper (audio tap runs off MainActor)
        let (engine, levelStream) = try AudioEngineHelper.startEngine(
            inputBuilder: inputBuilder,
            targetFormat: targetFormat
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

    private func cleanup() {
        // Keep transcriber + analyzerFormat for reuse (pre-warmed).
        // Only tear down per-session resources.
        analyzer = nil
        inputBuilder = nil
    }

    private func scheduleErrorReset() {
        Task {
            try? await Task.sleep(for: .seconds(3))
            if case .error = state {
                state = .idle
            }
        }
    }
}

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
