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

    enum TranscriptionEngine: String, Equatable, Sendable {
        case modernSpeech
        case classicDictation
        case remoteASR

        var logName: String {
            switch self {
            case .modernSpeech: return "speech"
            case .classicDictation: return "dictation"
            case .remoteASR: return "remote"
            }
        }
    }

    private enum TranscriberModule {
        case speech(SpeechTranscriber)
        case dictation(DictationTranscriber)

        var speechModule: any SpeechModule {
            switch self {
            case .speech(let transcriber):
                return transcriber
            case .dictation(let transcriber):
                return transcriber
            }
        }
    }

    private enum VoiceMetricPhase: String, Sendable {
        case prewarm
        case modelReady = "model_ready"
        case transcriberCreate = "transcriber_create"
        case analyzerStart = "analyzer_start"
        case audioStart = "audio_start"
        case total
        case firstResult = "first_result"
    }

    private struct VoiceMetricAnnotation: Sendable {
        let engine: String
        let locale: String
        let source: String

        func tags(
            phase: VoiceMetricPhase? = nil,
            status: String? = nil,
            extra: [String: String] = [:]
        ) -> [String: String] {
            var tags: [String: String] = [
                "engine": engine,
                "locale": locale,
                "source": source,
            ]

            if let phase {
                tags["phase"] = phase.rawValue
            }
            if let status {
                tags["status"] = status
            }

            for (key, value) in extra {
                guard !key.isEmpty else { continue }
                tags[key] = value
            }

            return tags
        }
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
    private var transcriber: TranscriberModule?
    private var analyzer: SpeechAnalyzer?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var audioEngine: AVAudioEngine?
    private var resultsTask: Task<Void, Never>?

    /// Remote ASR transcriber — used when engine is `.remoteASR`.
    private var remoteTranscriber: RemoteASRTranscriber?

    /// Cached across sessions — model availability and preferred audio format.
    /// Keyed by engine + locale so switching languages/engines invalidates correctly.
    private var cachedModelKey: String?
    private var modelReady = false
    private var cachedFormat: AVAudioFormat?

    /// In-flight prewarm task. startRecording awaits this instead of racing.
    private var prewarmTask: Task<AVAudioFormat?, Error>?
    private var prewarmModelKey: String?

    /// Operation lock — prevents overlapping async operations.
    private var operationInFlight = false

    /// Request ID for start operations, used to cancel stale in-flight starts.
    private var nextStartRequestID = 0
    private var activeStartRequestID: Int?

    // MARK: - Remote ASR Configuration

    /// Base URL for the remote ASR server (e.g. `http://mac-studio.local:8321`).
    /// When set, enables `.remoteASR` engine selection.
    private(set) var remoteASREndpoint: URL?

    /// Engine preference override. When `.remoteASR`, bypasses locale-based routing.
    private(set) var enginePreference: TranscriptionEngine?

    // MARK: - Init

    init() {}

    /// Configure the remote ASR endpoint. Pass nil to disable.
    func setRemoteASREndpoint(_ url: URL?) {
        remoteASREndpoint = url
        // Invalidate cached model state when endpoint changes
        if enginePreference == .remoteASR {
            modelReady = false
            cachedFormat = nil
            cachedModelKey = nil
        }
        logger.info("Remote ASR endpoint: \(url?.absoluteString ?? "disabled")")
    }

    /// Set engine preference override. Pass nil for automatic locale-based selection.
    func setEnginePreference(_ engine: TranscriptionEngine?) {
        enginePreference = engine
        // Invalidate cache when switching engines
        modelReady = false
        cachedFormat = nil
        cachedModelKey = nil
        logger.info("Engine preference: \(engine?.logName ?? "auto")")
    }

    // MARK: - Locale Resolution

    /// Resolve locale from a keyboard language string (BCP 47).
    /// Priority: active keyboard → persisted last keyboard → device locale.
    static func resolvedLocale(keyboardLanguage: String? = nil) -> Locale {
        if let lang = KeyboardLanguageStore.normalize(keyboardLanguage) {
            return Locale(identifier: lang)
        }
        if let stored = KeyboardLanguageStore.lastLanguage {
            return Locale(identifier: stored)
        }
        return Locale.current
    }

    /// Locale-driven engine routing:
    /// - English / most Latin locales -> modern SpeechTranscriber
    /// - Chinese/Japanese/Korean -> classic DictationTranscriber
    static func preferredEngine(for locale: Locale) -> TranscriptionEngine {
        let langCode = locale.language.languageCode?.identifier ?? "en"
        switch langCode {
        case "zh", "ja", "ko":
            return .classicDictation
        default:
            return .modernSpeech
        }
    }

    /// Resolve the effective engine, considering user preference and remote availability.
    private func effectiveEngine(for locale: Locale) -> TranscriptionEngine {
        if let pref = enginePreference {
            // If remote is preferred but no endpoint, fall back to locale-based
            if pref == .remoteASR, remoteASREndpoint == nil {
                logger.warning("Remote ASR preferred but no endpoint configured, falling back")
                return Self.preferredEngine(for: locale)
            }
            return pref
        }
        return Self.preferredEngine(for: locale)
    }

    private static func modelKey(engine: TranscriptionEngine, localeID: String) -> String {
        "\(engine.rawValue)::\(localeID)"
    }

    // MARK: - Pre-warm

    /// Check model availability and cache audio format in the background.
    /// Call from ChatView's .task {} so the first mic tap is fast.
    /// Safe to call multiple times — no-ops after first success for the same locale+engine.
    func prewarm(keyboardLanguage: String? = nil, source: String = "unknown") async {
        let locale = Self.resolvedLocale(keyboardLanguage: keyboardLanguage)
        let localeID = locale.identifier(.bcp47)
        let engine = Self.preferredEngine(for: locale)
        let key = Self.modelKey(engine: engine, localeID: localeID)
        let metricAnnotation = VoiceMetricAnnotation(
            engine: engine.logName,
            locale: localeID,
            source: source
        )
        let prewarmStart = ContinuousClock.now

        guard !modelReady || cachedModelKey != key else { return }
        guard state == .idle else { return }

        if let inflight = prewarmTask {
            guard prewarmModelKey != key else { return }
            inflight.cancel()
            prewarmTask = nil
            prewarmModelKey = nil
        }

        let task = Task {
            try await Self.warmModel(engine: engine, locale: locale)
        }
        prewarmTask = task
        prewarmModelKey = key

        do {
            let format = try await task.value
            guard prewarmModelKey == key else { return }
            cachedFormat = format
            cachedModelKey = key
            modelReady = true
            let durationMs = elapsedMs(since: prewarmStart)
            recordVoiceMetric(
                .voicePrewarmMs,
                valueMs: durationMs,
                annotation: metricAnnotation,
                phase: .prewarm,
                status: "ok"
            )
            logger.info("Pre-warmed \(engine.logName) model (locale: \(localeID), format: \(String(describing: format)))")
        } catch is CancellationError {
            let durationMs = elapsedMs(since: prewarmStart)
            recordVoiceMetric(
                .voicePrewarmMs,
                valueMs: durationMs,
                annotation: metricAnnotation,
                phase: .prewarm,
                status: "cancelled"
            )
            logger.info("Pre-warm cancelled for \(engine.logName) (locale: \(localeID))")
        } catch {
            let durationMs = elapsedMs(since: prewarmStart)
            recordVoiceMetric(
                .voicePrewarmMs,
                valueMs: durationMs,
                annotation: metricAnnotation,
                phase: .prewarm,
                status: "error",
                extraTags: ["error": String(describing: type(of: error))]
            )
            logger.warning("Pre-warm failed: \(error.localizedDescription)")
        }

        if prewarmModelKey == key {
            prewarmTask = nil
            prewarmModelKey = nil
        }
    }

    // MARK: - Availability

    // periphery:ignore - API surface for voice availability checks
    /// Whether the preferred engine for `locale` supports that locale.
    static func isAvailable(for locale: Locale = .current) async -> Bool {
        let localeID = locale.identifier(.bcp47)
        switch preferredEngine(for: locale) {
        case .modernSpeech:
            let supported = await SpeechTranscriber.supportedLocales
            return supported.contains { $0.identifier(.bcp47) == localeID }
        case .classicDictation:
            let supported = await DictationTranscriber.supportedLocales
            return supported.contains { $0.identifier(.bcp47) == localeID }
        case .remoteASR:
            return true  // Remote endpoint handles all locales
        }
    }

    // periphery:ignore - API surface for voice model availability checks
    /// Whether the preferred engine model for `locale` is installed.
    static func isModelInstalled(for locale: Locale) async -> Bool {
        let localeID = locale.identifier(.bcp47)
        switch preferredEngine(for: locale) {
        case .modernSpeech:
            let installed = await SpeechTranscriber.installedLocales
            return installed.contains { $0.identifier(.bcp47) == localeID }
        case .classicDictation:
            let installed = await DictationTranscriber.installedLocales
            return installed.contains { $0.identifier(.bcp47) == localeID }
        case .remoteASR:
            return true  // No local model needed
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
    func startRecording(keyboardLanguage: String? = nil, source: String = "unknown") async throws {
        guard state == .idle else {
            logger.warning("Cannot start: state is \(String(describing: self.state))")
            return
        }
        guard !operationInFlight else {
            logger.warning("Cannot start: operation already in flight")
            return
        }

        nextStartRequestID += 1
        let requestID = nextStartRequestID
        activeStartRequestID = requestID
        operationInFlight = true
        defer {
            if activeStartRequestID == requestID {
                activeStartRequestID = nil
                operationInFlight = false
            }
        }

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
        let engine = effectiveEngine(for: locale)
        let key = Self.modelKey(engine: engine, localeID: localeID)
        let metricAnnotation = VoiceMetricAnnotation(
            engine: engine.logName,
            locale: localeID,
            source: source
        )
        var modelPathTag = "warm_cache"

        // Invalidate cache if locale or engine changed
        if cachedModelKey != key {
            modelReady = false
            cachedFormat = nil
        }

        do {
            try ensureStartRequestActive(requestID)

            if engine == .remoteASR {
                try await startRemoteRecording(
                    requestID: requestID,
                    startTime: startTime,
                    locale: locale,
                    metricAnnotation: metricAnnotation,
                    modelPathTag: &modelPathTag
                )
            } else {
                try await startOnDeviceRecording(
                    requestID: requestID,
                    startTime: startTime,
                    engine: engine,
                    locale: locale,
                    localeID: localeID,
                    key: key,
                    metricAnnotation: metricAnnotation,
                    modelPathTag: &modelPathTag
                )
            }

            let totalMs = elapsedMs(since: startTime)
            recordVoiceMetric(
                .voiceSetupMs,
                valueMs: totalMs,
                annotation: metricAnnotation,
                phase: .total,
                status: "ok",
                extraTags: ["path": modelPathTag]
            )
            logger.error("Voice setup: recording started in \(totalMs)ms total (engine: \(engine.logName), locale: \(localeID))")
            state = .recording
        } catch is CancellationError {
            let totalMs = elapsedMs(since: startTime)
            recordVoiceMetric(
                .voiceSetupMs,
                valueMs: totalMs,
                annotation: metricAnnotation,
                phase: .total,
                status: "cancelled",
                extraTags: ["path": modelPathTag]
            )
            logger.info("Voice setup cancelled")
            await cleanupFailedStart()
            state = .idle
            return
        } catch {
            let totalMs = elapsedMs(since: startTime)
            recordVoiceMetric(
                .voiceSetupMs,
                valueMs: totalMs,
                annotation: metricAnnotation,
                phase: .total,
                status: "error",
                extraTags: [
                    "path": modelPathTag,
                    "error": String(describing: type(of: error)),
                ]
            )
            logger.error("Voice setup failed: \(error.localizedDescription)")
            await cleanupFailedStart()
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

        if let remote = remoteTranscriber {
            // Remote path: flush remaining audio as final chunk
            await remote.stop()
            remoteTranscriber = nil
        } else {
            // On-device path: finalize SpeechAnalyzer
            do {
                try await analyzer?.finalizeAndFinishThroughEndOfInput()
            } catch {
                logger.error("Error finalizing: \(error.localizedDescription)")
            }
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

        if state == .preparingModel {
            // Invalidate any in-flight start operation so stale async work
            // cannot flip us back into recording after cancel.
            activeStartRequestID = nil
            prewarmTask?.cancel()
            prewarmTask = nil
            prewarmModelKey = nil
        }

        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        inputBuilder?.finish()

        resultsTask?.cancel()
        resultsTask = nil

        remoteTranscriber?.cancel()
        remoteTranscriber = nil
        await analyzer?.cancelAndFinishNow()

        deactivateAudioSession()
        teardownSession()

        finalizedTranscript = ""
        volatileTranscript = ""
        operationInFlight = false
        state = .idle
    }

    // MARK: - Remote ASR Recording

    /// Start recording with the remote ASR engine. No SpeechAnalyzer — audio
    /// is buffered locally and uploaded in WAV chunks to the configured endpoint.
    private func startRemoteRecording(
        requestID: Int,
        startTime: ContinuousClock.Instant,
        locale: Locale,
        metricAnnotation: VoiceMetricAnnotation,
        modelPathTag: inout String
    ) async throws {
        guard let endpoint = remoteASREndpoint else {
            throw VoiceInputError.internalError("Remote ASR endpoint not configured")
        }

        modelPathTag = "remote"
        let localeID = locale.identifier(.bcp47)
        let langCode = locale.language.languageCode?.identifier

        // Phase 1: no model to warm — remote handles it
        let modelPhaseMs = elapsedMs(since: startTime)
        recordVoiceMetric(
            .voiceSetupMs,
            valueMs: modelPhaseMs,
            annotation: metricAnnotation,
            phase: .modelReady,
            status: "ok",
            extraTags: ["path": "remote"]
        )
        logger.info("Voice setup: remote ASR (endpoint: \(endpoint.absoluteString))")

        // Phase 2: create remote transcriber
        let transcriberStart = ContinuousClock.now
        let config = RemoteASRTranscriber.Configuration(
            endpointURL: endpoint,
            language: langCode
        )
        let newRemote = RemoteASRTranscriber(configuration: config)
        remoteTranscriber = newRemote
        activeLanguageLabel = Self.languageLabel(for: locale)

        let transcriberMs = elapsedMs(since: transcriberStart)
        recordVoiceMetric(
            .voiceSetupMs,
            valueMs: transcriberMs,
            annotation: metricAnnotation,
            phase: .transcriberCreate,
            status: "ok",
            extraTags: ["path": "remote"]
        )
        logger.info("Voice setup: created remote transcriber (locale: \(localeID))")
        try ensureStartRequestActive(requestID)

        // Phase 3: start the chunk loop and results handler
        let analyzerStart = ContinuousClock.now
        let resultStream = newRemote.start()

        let analyzerMs = elapsedMs(since: analyzerStart)
        recordVoiceMetric(
            .voiceSetupMs,
            valueMs: analyzerMs,
            annotation: metricAnnotation,
            phase: .analyzerStart,
            status: "ok",
            extraTags: ["path": "remote"]
        )

        startRemoteResultsHandler(
            resultStream: resultStream,
            metricAnnotation: metricAnnotation
        )
        logger.info("Voice setup: remote chunk loop started")
        try ensureStartRequestActive(requestID)

        // Phase 4: audio engine — target 16kHz mono for remote
        let audioStart = ContinuousClock.now
        try setupAudioSession()
        try startRemoteAudioEngine(transcriber: newRemote)
        try ensureStartRequestActive(requestID)

        let audioMs = elapsedMs(since: audioStart)
        recordVoiceMetric(
            .voiceSetupMs,
            valueMs: audioMs,
            annotation: metricAnnotation,
            phase: .audioStart,
            status: "ok",
            extraTags: ["path": "remote"]
        )
    }

    /// Start the audio engine for remote ASR — captures at device rate,
    /// resamples to 16kHz mono, feeds the remote transcriber.
    private func startRemoteAudioEngine(transcriber: RemoteASRTranscriber) throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Target: 16kHz mono Float32
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(transcriber.config.sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw VoiceInputError.internalError("Cannot create 16kHz mono format")
        }

        let converter: AVAudioConverter?
        if inputFormat != targetFormat {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        } else {
            converter = nil
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak transcriber] buffer, _ in
            guard let transcriber else { return }

            // Resample to 16kHz mono if needed
            let outputBuffer: AVAudioPCMBuffer
            if let converter, let targetFormat = converter.outputFormat as AVAudioFormat? {
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

            transcriber.appendAudio(buffer: outputBuffer)
        }

        engine.prepare()
        try engine.start()
        audioEngine = engine
    }

    /// Handle results from the remote ASR transcriber stream.
    private func startRemoteResultsHandler(
        resultStream: AsyncStream<RemoteASRTranscriber.TranscriptionResult>,
        metricAnnotation: VoiceMetricAnnotation
    ) {
        let recordingStartTime = ContinuousClock.now
        var firstResultReceived = false

        resultsTask = Task {
            for await result in resultStream {
                guard !Task.isCancelled else { break }

                if !firstResultReceived {
                    firstResultReceived = true
                    let ms = elapsedMs(since: recordingStartTime)
                    recordVoiceMetric(
                        .voiceFirstResultMs,
                        valueMs: ms,
                        annotation: metricAnnotation,
                        phase: .firstResult,
                        status: "ok",
                        extraTags: ["result_type": "final"]
                    )
                    logger.error("Voice latency: first remote result in \(ms)ms")
                }

                // Remote results are always finalized (one chunk = one result).
                // Add a space separator between chunks for natural text flow.
                if !finalizedTranscript.isEmpty {
                    finalizedTranscript += " "
                }
                finalizedTranscript += result.text
                volatileTranscript = ""
                logger.debug("Remote finalized: \(result.text)")
            }
        }
    }

    // MARK: - On-Device Recording

    /// Start recording with the on-device SpeechAnalyzer engine (SpeechTranscriber
    /// or DictationTranscriber). This is the original recording path.
    private func startOnDeviceRecording(
        requestID: Int,
        startTime: ContinuousClock.Instant,
        engine: TranscriptionEngine,
        locale: Locale,
        localeID: String,
        key: String,
        metricAnnotation: VoiceMetricAnnotation,
        modelPathTag: inout String
    ) async throws {
        let modelPhaseStart = ContinuousClock.now

        // Phase 1: ensure model is ready
        var joinedMatchingPrewarm = false
        if let inflight = prewarmTask {
            if prewarmModelKey == key {
                modelPathTag = "join_prewarm"
                logger.info("Voice setup: awaiting in-flight \(engine.logName) prewarm")
                let format = try await inflight.value
                try ensureStartRequestActive(requestID)
                cachedFormat = format
                cachedModelKey = key
                modelReady = true
                prewarmTask = nil
                prewarmModelKey = nil
                joinedMatchingPrewarm = true
                let ms = elapsedMs(since: startTime)
                logger.error("Voice setup: joined prewarm in \(ms)ms")
            } else {
                inflight.cancel()
                prewarmTask = nil
                prewarmModelKey = nil
            }
        }

        if !joinedMatchingPrewarm {
            if !modelReady {
                modelPathTag = "cold"
                let format = try await Self.warmModel(engine: engine, locale: locale)
                try ensureStartRequestActive(requestID)
                cachedFormat = format
                cachedModelKey = key
                modelReady = true
                let ms = elapsedMs(since: startTime)
                logger.error("Voice setup: cold \(engine.logName) model check in \(ms)ms")
            } else {
                modelPathTag = "warm_cache"
                logger.error("Voice setup: \(engine.logName) model ready (0ms)")
            }
        }

        let modelPhaseMs = elapsedMs(since: modelPhaseStart)
        recordVoiceMetric(
            .voiceSetupMs,
            valueMs: modelPhaseMs,
            annotation: metricAnnotation,
            phase: .modelReady,
            status: "ok",
            extraTags: ["path": modelPathTag]
        )

        // Phase 2: fresh transcriber for this session
        let transcriberStart = ContinuousClock.now
        let newTranscriber = Self.makeTranscriber(engine: engine, locale: locale)
        transcriber = newTranscriber
        activeLanguageLabel = Self.languageLabel(for: locale)
        let transcriberMs = elapsedMs(since: transcriberStart)
        recordVoiceMetric(
            .voiceSetupMs,
            valueMs: transcriberMs,
            annotation: metricAnnotation,
            phase: .transcriberCreate,
            status: "ok",
            extraTags: ["path": modelPathTag]
        )
        logger.info("Voice setup: created \(engine.logName) transcriber (locale: \(localeID), label: \(self.activeLanguageLabel ?? "?"))")

        // Use cached format, or compute if missing
        let format: AVAudioFormat?
        if let cached = cachedFormat {
            format = cached
        } else {
            format = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [newTranscriber.speechModule]
            )
            cachedFormat = format
        }
        try ensureStartRequestActive(requestID)

        // Phase 3: start analyzer session
        let analyzerStart = ContinuousClock.now
        let newAnalyzer = SpeechAnalyzer(modules: [newTranscriber.speechModule])
        analyzer = newAnalyzer

        let (sequence, builder) = AsyncStream.makeStream(of: AnalyzerInput.self)
        inputBuilder = builder

        try await newAnalyzer.start(inputSequence: sequence)
        try ensureStartRequestActive(requestID)
        let analyzerMs = elapsedMs(since: analyzerStart)
        recordVoiceMetric(
            .voiceSetupMs,
            valueMs: analyzerMs,
            annotation: metricAnnotation,
            phase: .analyzerStart,
            status: "ok",
            extraTags: ["path": modelPathTag]
        )
        startResultsHandler(transcriber: newTranscriber, metricAnnotation: metricAnnotation)
        logger.info("Voice setup: analyzer session started")

        // Phase 4: audio engine
        let audioStart = ContinuousClock.now
        try setupAudioSession()
        try await startAudioEngine(format: format)
        try ensureStartRequestActive(requestID)
        let audioMs = elapsedMs(since: audioStart)
        recordVoiceMetric(
            .voiceSetupMs,
            valueMs: audioMs,
            annotation: metricAnnotation,
            phase: .audioStart,
            status: "ok",
            extraTags: ["path": modelPathTag]
        )
    }

    // MARK: - Setup

    /// Check model availability and get preferred audio format.
    /// Creates a temporary transcriber to probe — does not retain it.
    nonisolated private static func warmModel(
        engine: TranscriptionEngine,
        locale: Locale
    ) async throws -> AVAudioFormat? {
        let probe = makeTranscriber(engine: engine, locale: locale)
        let localeID = locale.identifier(.bcp47)

        let isInstalled: Bool
        switch engine {
        case .modernSpeech:
            let installed = await SpeechTranscriber.installedLocales
            isInstalled = installed.contains(where: { $0.identifier(.bcp47) == localeID })
        case .classicDictation:
            let installed = await DictationTranscriber.installedLocales
            isInstalled = installed.contains(where: { $0.identifier(.bcp47) == localeID })
        case .remoteASR:
            return nil  // Remote engine has no local model to warm
        }

        if !isInstalled {
            logger.info("Downloading \(engine.logName) model for \(locale.identifier)")
            if let request = try await AssetInventory.assetInstallationRequest(
                supporting: [probe.speechModule]
            ) {
                try await request.downloadAndInstall()
                logger.info("Model download complete")
            }
        } else {
            logger.info("\(engine.logName) model already installed for \(locale.identifier)")
        }

        let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [probe.speechModule]
        )
        logger.info("Analyzer format (\(engine.logName)): \(String(describing: format))")
        return format
    }

    nonisolated private static func makeTranscriber(
        engine: TranscriptionEngine,
        locale: Locale
    ) -> TranscriberModule {
        switch engine {
        case .modernSpeech:
            // Favor Apple's streaming preset for faster volatile results.
            return .speech(
                SpeechTranscriber(
                    locale: locale,
                    preset: .progressiveTranscription
                )
            )
        case .classicDictation:
            return .dictation(
                DictationTranscriber(
                    locale: locale,
                    contentHints: [.shortForm],
                    transcriptionOptions: [.punctuation],
                    reportingOptions: [.volatileResults],
                    attributeOptions: []
                )
            )
        case .remoteASR:
            // Remote ASR doesn't use SpeechModule. This should never be called
            // for the remote path — startRemoteRecording() handles it directly.
            fatalError("makeTranscriber called for .remoteASR — use startRemoteRecording instead")
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

    private func startResultsHandler(
        transcriber: TranscriberModule,
        metricAnnotation: VoiceMetricAnnotation
    ) {
        let recordingStartTime = ContinuousClock.now
        var firstResultReceived = false

        resultsTask = Task {
            do {
                switch transcriber {
                case .dictation(let module):
                    for try await result in module.results {
                        guard !Task.isCancelled else { break }
                        handleResult(
                            text: String(result.text.characters),
                            isFinal: result.isFinal,
                            firstResultReceived: &firstResultReceived,
                            recordingStartTime: recordingStartTime,
                            metricAnnotation: metricAnnotation
                        )
                    }

                case .speech(let module):
                    for try await result in module.results {
                        guard !Task.isCancelled else { break }
                        handleResult(
                            text: String(result.text.characters),
                            isFinal: result.isFinal,
                            firstResultReceived: &firstResultReceived,
                            recordingStartTime: recordingStartTime,
                            metricAnnotation: metricAnnotation
                        )
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

    private func handleResult(
        text: String,
        isFinal: Bool,
        firstResultReceived: inout Bool,
        recordingStartTime: ContinuousClock.Instant,
        metricAnnotation: VoiceMetricAnnotation
    ) {
        if !firstResultReceived {
            firstResultReceived = true
            let ms = elapsedMs(since: recordingStartTime)
            recordVoiceMetric(
                .voiceFirstResultMs,
                valueMs: ms,
                annotation: metricAnnotation,
                phase: .firstResult,
                status: "ok",
                extraTags: ["result_type": isFinal ? "final" : "volatile"]
            )
            logger.error("Voice latency: first result in \(ms)ms (type: \(isFinal ? "final" : "volatile"))")
        }

        if isFinal {
            finalizedTranscript += text
            volatileTranscript = ""
            logger.debug("Finalized: \(text)")
        } else {
            volatileTranscript = text
            logger.debug("Volatile: \(text)")
        }
    }

    // MARK: - Cleanup

    private func teardownSession() {
        transcriber = nil
        analyzer = nil
        inputBuilder = nil
        remoteTranscriber = nil
        audioLevel = 0
        activeLanguageLabel = nil
    }

    private func cleanupFailedStart() async {
        resultsTask?.cancel()
        resultsTask = nil
        remoteTranscriber?.cancel()
        remoteTranscriber = nil
        await analyzer?.cancelAndFinishNow()
        deactivateAudioSession()
        teardownSession()
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

    private func recordVoiceMetric(
        _ metric: ChatMetricName,
        valueMs: Int,
        annotation: VoiceMetricAnnotation,
        phase: VoiceMetricPhase? = nil,
        status: String? = nil,
        extraTags: [String: String] = [:]
    ) {
        let tags = annotation.tags(phase: phase, status: status, extra: extraTags)
        let clampedValue = max(0, valueMs)

        Task.detached(priority: .utility) {
            await ChatMetricsService.shared.record(
                metric: metric,
                value: Double(clampedValue),
                unit: .ms,
                tags: tags
            )
        }
    }

    private func ensureStartRequestActive(_ requestID: Int) throws {
        guard activeStartRequestID == requestID, state == .preparingModel else {
            throw CancellationError()
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
    // periphery:ignore - used by VoiceInputManagerTests via @testable import
    var _testState: State {
        get { state }
        set { state = newValue }
    }

    // periphery:ignore - used by VoiceInputManagerTests via @testable import
    var _testOperationInFlight: Bool {
        get { operationInFlight }
        set { operationInFlight = newValue }
    }

    // periphery:ignore - used by VoiceInputManagerTests via @testable import
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
