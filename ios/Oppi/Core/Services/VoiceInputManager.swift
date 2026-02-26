import Accelerate
@preconcurrency import AVFoundation
import Foundation
import OSLog
import Speech
import UIKit

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "VoiceInput")

/// On-device speech-to-text using `DictationTranscriber` (iOS 26+).
///
/// Uses Apple's system dictation model — the same engine that powers
/// keyboard dictation. Adds punctuation automatically and has strong
/// multilingual support including Chinese, Japanese, and Korean.
///
/// **Language detection:** By default, follows the active keyboard language
/// at mic-tap time (Chinese keyboard → Chinese model, English keyboard →
/// English model). Users can override to a specific locale in Settings.
///
/// Results are either **volatile** (immediate rough guesses that update
/// as more context arrives) or **finalized** (accurate, won't change).
/// The manager accumulates finalized text and replaces the volatile
/// portion on each update, exposing a combined `currentTranscript`.
///
/// **Key design: transcribers are never reused.** A `DictationTranscriber`
/// becomes invalid after its analyzer is finalized. We create a fresh
/// pair for each recording session. Pre-warming only checks model
/// availability and caches the audio format.
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

    /// Short language code for the active recording session (e.g. "EN", "中").
    /// Set at recording start from the resolved locale. Nil when not recording.
    private(set) var activeLanguageLabel: String?

    var currentTranscript: String {
        (finalizedTranscript + volatileTranscript)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isRecording: Bool { state == .recording }
    var isProcessing: Bool { state == .processing }
    var isPreparing: Bool { state == .preparingModel }

    // MARK: - Private

    /// Per-session resources — created fresh, torn down after each session.
    private var transcriber: DictationTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var audioEngine: AVAudioEngine?
    private var resultsTask: Task<Void, Never>?

    /// Cached across sessions — model availability and preferred audio format.
    /// Keyed by locale so switching languages invalidates correctly.
    private var cachedLocaleID: String?
    private var modelReady = false
    private var cachedFormat: AVAudioFormat?

    /// In-flight prewarm task. startRecording awaits this instead of racing.
    private var prewarmTask: Task<AVAudioFormat?, Error>?

    /// Operation lock — prevents overlapping async operations.
    private var operationInFlight = false

    // MARK: - Init

    init() {}

    // MARK: - Locale Resolution

    /// Resolve locale from a keyboard language string (BCP 47).
    /// Priority: active keyboard → persisted last keyboard → device locale.
    static func resolvedLocale(keyboardLanguage: String? = nil) -> Locale {
        if let lang = keyboardLanguage {
            return Locale(identifier: lang)
        }
        if let stored = KeyboardLanguageStore.lastLanguage {
            return Locale(identifier: stored)
        }
        return Locale.current
    }

    // MARK: - Pre-warm

    /// Check model availability and cache audio format in the background.
    /// Call from ChatView's .task {} so the first mic tap is fast.
    /// Safe to call multiple times — no-ops after first success for the same locale.
    func prewarm(keyboardLanguage: String? = nil) async {
        let locale = Self.resolvedLocale(keyboardLanguage: keyboardLanguage)
        let localeID = locale.identifier(.bcp47)
        guard !modelReady || cachedLocaleID != localeID else { return }
        guard prewarmTask == nil, state == .idle else { return }

        let task = Task {
            try await Self.warmModel(locale: locale)
        }
        prewarmTask = task

        do {
            let format = try await task.value
            cachedFormat = format
            cachedLocaleID = localeID
            modelReady = true
            logger.info("Pre-warmed dictation model (locale: \(localeID), format: \(String(describing: format)))")
        } catch {
            logger.warning("Pre-warm failed: \(error.localizedDescription)")
        }
        prewarmTask = nil
    }

    // MARK: - Availability

    /// Whether DictationTranscriber supports a locale.
    static func isAvailable(for locale: Locale = .current) async -> Bool {
        let supported = await DictationTranscriber.supportedLocales
        return supported.contains {
            $0.identifier(.bcp47) == locale.identifier(.bcp47)
        }
    }

    /// Whether the ML model is already installed for a locale.
    static func isModelInstalled(for locale: Locale) async -> Bool {
        let installed = await DictationTranscriber.installedLocales
        return installed.contains {
            $0.identifier(.bcp47) == locale.identifier(.bcp47)
        }
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
    /// Pass `keyboardLanguage` from the text view's `textInputMode?.primaryLanguage`
    /// to match the user's active keyboard. Falls back to device locale when nil.
    func startRecording(keyboardLanguage: String? = nil) async throws {
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

        if !Self.hasPermissions {
            guard await requestPermissions() else {
                state = .error("Microphone or speech permission denied")
                scheduleErrorReset()
                return
            }
        }

        state = .preparingModel
        let startTime = ContinuousClock.now
        let locale = Self.resolvedLocale(keyboardLanguage: keyboardLanguage)
        let localeID = locale.identifier(.bcp47)

        // Invalidate cache if locale changed
        if cachedLocaleID != localeID {
            modelReady = false
            cachedFormat = nil
        }

        do {
            // Phase 1: ensure model is ready
            if let inflight = prewarmTask {
                logger.info("Voice setup: awaiting in-flight prewarm")
                let format = try await inflight.value
                cachedFormat = format
                cachedLocaleID = localeID
                modelReady = true
                prewarmTask = nil
                let ms = elapsedMs(since: startTime)
                logger.error("Voice setup: joined prewarm in \(ms)ms")
            } else if !modelReady {
                let format = try await Self.warmModel(locale: locale)
                cachedFormat = format
                cachedLocaleID = localeID
                modelReady = true
                let ms = elapsedMs(since: startTime)
                logger.error("Voice setup: cold model check in \(ms)ms")
            } else {
                logger.error("Voice setup: model ready (0ms)")
            }

            // Phase 2: fresh transcriber for this session
            let newTranscriber = DictationTranscriber(
                locale: locale,
                contentHints: [.shortForm],
                transcriptionOptions: [.punctuation],
                reportingOptions: [.volatileResults],
                attributeOptions: []
            )
            transcriber = newTranscriber
            activeLanguageLabel = Self.languageLabel(for: locale)
            logger.info("Voice setup: created dictation transcriber (locale: \(localeID), label: \(self.activeLanguageLabel ?? "?"))")

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
            logger.error("Voice setup: recording started in \(totalMs)ms total (locale: \(localeID))")
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

        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        inputBuilder?.finish()

        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            logger.error("Error finalizing: \(error.localizedDescription)")
        }

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
    nonisolated private static func warmModel(locale: Locale) async throws -> AVAudioFormat? {
        let probe = DictationTranscriber(
            locale: locale,
            contentHints: [.shortForm],
            transcriptionOptions: [.punctuation],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )

        let installed = await DictationTranscriber.installedLocales
        if !installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            logger.info("Downloading dictation model for \(locale.identifier)")
            if let request = try await AssetInventory.assetInstallationRequest(
                supporting: [probe]
            ) {
                try await request.downloadAndInstall()
                logger.info("Model download complete")
            }
        } else {
            logger.info("Model already installed for \(locale.identifier)")
        }

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

        let (engine, levelStream) = try AudioEngineHelper.startEngine(
            inputBuilder: inputBuilder,
            targetFormat: format
        )
        audioEngine = engine

        Task {
            for await level in levelStream {
                self.audioLevel = level
            }
        }
    }

    private func startResultsHandler(transcriber: DictationTranscriber) {
        let recordingStartTime = ContinuousClock.now
        var firstResultReceived = false

        resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    guard !Task.isCancelled else { break }

                    if !firstResultReceived {
                        firstResultReceived = true
                        let ms = elapsedMs(since: recordingStartTime)
                        logger.error("Voice latency: first result in \(ms)ms (type: \(result.isFinal ? "final" : "volatile"))")
                    }

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

    private func teardownSession() {
        transcriber = nil
        analyzer = nil
        inputBuilder = nil
        audioLevel = 0
        activeLanguageLabel = nil
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

    /// Compact language label for display in the mic button.
    /// CJK languages get their native script character, others get 2-letter code.
    static func languageLabel(for locale: Locale) -> String {
        let langCode = locale.language.languageCode?.identifier ?? "en"
        switch langCode {
        case "zh": return "中"
        case "ja": return "あ"
        case "ko": return "한"
        default: return langCode.uppercased().prefix(2).description
        }
    }

    private func elapsedMs(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds * 1000
            + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }
}

// MARK: - Testing Support

#if DEBUG
extension VoiceInputManager {
    var _testState: State {
        get { state }
        set { state = newValue }
    }

    var _testOperationInFlight: Bool {
        get { operationInFlight }
        set { operationInFlight = newValue }
    }

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

private enum AudioEngineHelper {
    static func startEngine(
        inputBuilder: AsyncStream<AnalyzerInput>.Continuation,
        targetFormat: AVAudioFormat?
    ) throws -> (AVAudioEngine, AsyncStream<Float>) {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        let converter: AVAudioConverter?
        if let targetFormat, inputFormat != targetFormat {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        } else {
            converter = nil
        }

        let (levelStream, levelContinuation) = AsyncStream<Float>.makeStream()

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            if let channelData = buffer.floatChannelData?[0] {
                let frameLength = UInt(buffer.frameLength)
                var rms: Float = 0
                vDSP_rmsqv(channelData, 1, &rms, frameLength)
                let level = min(1.0, rms * 25.0)
                levelContinuation.yield(level)
            }

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
