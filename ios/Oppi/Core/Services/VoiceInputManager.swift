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

    enum EngineMode: String, Equatable, Sendable {
        case auto
        case onDevice
        case remote

        var logName: String {
            switch self {
            case .auto: return "auto"
            case .onDevice: return "on_device"
            case .remote: return "remote"
            }
        }
    }

    enum RouteIndicator: Equatable, Sendable {
        case auto
        case onDevice
        case remote

        var iconName: String {
            switch self {
            case .auto: return "arrow.triangle.branch"
            case .onDevice: return "iphone"
            case .remote: return "cloud.fill"
            }
        }

        var accessibilityLabel: String {
            switch self {
            case .auto: return "Automatic routing"
            case .onDevice: return "On-device transcription"
            case .remote: return "Remote transcription"
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

    private struct RemoteProbeCache {
        let endpoint: URL
        let reachable: Bool
        let checkedAt: Date
    }

    private struct RemoteChunkProfile: Sendable {
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

    // MARK: - Published State

    private(set) var state: State = .idle
    private(set) var finalizedTranscript = ""
    private(set) var volatileTranscript = ""
    private(set) var audioLevel: Float = 0

    /// Short language code for the active recording session (e.g. "EN", "中").
    /// Set at recording start from the resolved locale. Nil when not recording.
    private(set) var activeLanguageLabel: String?

    /// Effective engine selected for the current voice session.
    /// Set at start of recording (including preparing) and cleared on teardown.
    private(set) var activeEngine: TranscriptionEngine?

    var currentTranscript: String {
        (finalizedTranscript + volatileTranscript)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isRecording: Bool { state == .recording }
    var isProcessing: Bool { state == .processing }
    var isPreparing: Bool { state == .preparingModel }

    /// Route indicator for UI badges.
    /// While recording/preparing, this reflects the resolved engine.
    /// When idle, this reflects configured engine mode.
    var routeIndicator: RouteIndicator {
        if let activeEngine {
            switch activeEngine {
            case .remoteASR:
                return .remote
            case .modernSpeech, .classicDictation:
                return .onDevice
            }
        }

        switch engineMode {
        case .auto:
            return .auto
        case .onDevice:
            return .onDevice
        case .remote:
            return .remote
        }
    }

    // MARK: - Private

    /// Per-session resources — created fresh, torn down after each session.
    private var transcriber: TranscriberModule?
    private var analyzer: SpeechAnalyzer?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var audioEngine: AVAudioEngine?
    private var resultsTask: Task<Void, Never>?
    private var audioLevelTask: Task<Void, Never>?

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
    /// When nil, remote mode is unavailable.
    private(set) var remoteASREndpoint: URL?

    /// User-selected engine routing mode.
    private(set) var engineMode: EngineMode = .auto

    /// Backward-compatible engine preference surface used by tests.
    /// `nil` = auto, `.remoteASR` = remote mode, on-device values = on-device mode.
    private(set) var enginePreference: TranscriptionEngine?

    /// Cached remote reachability probe result (HEAD request).
    private var remoteProbeCache: RemoteProbeCache?
    private let remoteProbeCacheTTL: TimeInterval = 15

    /// Remote chunk tuning tags applied to per-chunk metrics for the active session.
    private var remoteChunkMetricTags: [String: String] = [:]

    private static let remoteChunkProfileDefault = RemoteChunkProfile(
        chunkInterval: 1.8,
        overlapDuration: 0.5,
        requestTimeout: 10,
        profileTag: "default"
    )

    private static let remoteChunkProfileCJK = RemoteChunkProfile(
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

    private static let remoteFillerTokens: Set<String> = [
        "uh", "um", "ah", "oh", "er", "hmm", "mm",
    ]

    private static let remoteAcknowledgementTokens: Set<String> = [
        "ok", "okay",
    ]

    // MARK: - Init

    init() {
        loadPreferences()
    }

    /// Reload persisted voice settings.
    func loadPreferences() {
        applyEngineMode(from: VoiceInputPreferences.engineMode)
        applyRemoteEndpoint(VoiceInputPreferences.remoteEndpoint)
    }

    /// Configure the remote ASR endpoint. Pass nil to disable.
    func setRemoteASREndpoint(_ url: URL?) {
        applyRemoteEndpoint(url)
    }

    /// Set engine mode directly.
    func setEngineMode(_ mode: EngineMode) {
        engineMode = mode

        switch mode {
        case .auto:
            enginePreference = nil
        case .onDevice:
            // Sentinel value for legacy tests — runtime routing still resolves
            // to locale-based on-device engine selection.
            enginePreference = .modernSpeech
        case .remote:
            enginePreference = .remoteASR
        }

        activeEngine = nil
        invalidateModelCache()
        logger.info("Engine mode: \(mode.logName)")
    }

    /// Backward-compatible preference API. Prefer `setEngineMode(_:)`.
    func setEnginePreference(_ engine: TranscriptionEngine?) {
        switch engine {
        case nil:
            setEngineMode(.auto)
        case .remoteASR?:
            setEngineMode(.remote)
        case .modernSpeech?, .classicDictation?:
            setEngineMode(.onDevice)
            enginePreference = engine
        }
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

    /// On-device engine routing. DictationTranscriber (classic keyboard dictation
    /// model) is used for all locales — it's faster, adds punctuation, and has
    /// years of Apple tuning for short-form dictation. SpeechTranscriber (new
    /// model) is designed for long-form/meeting/lecture transcription and trades
    /// short-form latency for broader context handling.
    static func preferredEngine(for locale: Locale) -> TranscriptionEngine {
        // All locales use the classic dictation engine. The new SpeechTranscriber
        // model is optimized for long-form audio (Notes, Voice Memos) and has
        // worse latency/accuracy for short chat dictation.
        _ = locale
        return .classicDictation
    }

    private static func remoteChunkProfile(for locale: Locale) -> RemoteChunkProfile {
        let langCode = locale.language.languageCode?.identifier ?? "en"
        switch langCode {
        case "zh", "ja", "ko":
            return remoteChunkProfileCJK
        default:
            return remoteChunkProfileDefault
        }
    }

    private static func remoteLanguageHint(for _: Locale) -> String? {
        // Let the server auto-detect spoken language for mixed-language dictation.
        // Forcing keyboard language here can cause unintended translation.
        nil
    }

    /// Resolve the effective engine, considering mode + remote reachability.
    private func effectiveEngine(for locale: Locale, source: String) async -> TranscriptionEngine {
        let fallback = Self.preferredEngine(for: locale)
        let localeID = locale.identifier(.bcp47)
        let fallbackAnnotation = VoiceMetricAnnotation(
            engine: TranscriptionEngine.remoteASR.logName,
            locale: localeID,
            source: source
        )

        switch engineMode {
        case .onDevice:
            return fallback

        case .remote:
            return .remoteASR

        case .auto:
            guard let endpoint = remoteASREndpoint else {
                return fallback
            }

            let reachable = await probeRemoteReachability(endpoint: endpoint, annotation: fallbackAnnotation)
            if reachable {
                return .remoteASR
            }

            logger.info("Remote ASR unreachable; using on-device engine")
            return fallback
        }
    }

    private static func modelKey(engine: TranscriptionEngine, localeID: String) -> String {
        "\(engine.rawValue)::\(localeID)"
    }

    private func applyEngineMode(from preference: VoiceInputPreferences.EngineMode) {
        switch preference {
        case .auto:
            setEngineMode(.auto)
        case .onDevice:
            setEngineMode(.onDevice)
        case .remote:
            setEngineMode(.remote)
        }
    }

    private func applyRemoteEndpoint(_ url: URL?) {
        remoteASREndpoint = url
        remoteProbeCache = nil
        invalidateModelCache()
        logger.info("Remote ASR endpoint: \(url?.absoluteString ?? "disabled")")
    }

    private func invalidateModelCache() {
        modelReady = false
        cachedFormat = nil
        cachedModelKey = nil
    }

    private func probeRemoteReachability(
        endpoint: URL,
        forceRefresh: Bool = false,
        annotation: VoiceMetricAnnotation? = nil
    ) async -> Bool {
        if !forceRefresh,
           let cache = remoteProbeCache,
           cache.endpoint == endpoint,
           Date().timeIntervalSince(cache.checkedAt) < remoteProbeCacheTTL {
            if let annotation {
                recordVoiceMetric(
                    .voiceRemoteProbeMs,
                    valueMs: 0,
                    annotation: annotation,
                    status: cache.reachable ? "ok" : "error",
                    extraTags: [
                        "cached": "1",
                        "reachable": cache.reachable ? "1" : "0",
                        "host": endpoint.host ?? "unknown",
                    ]
                )
            }
            return cache.reachable
        }

        let probeStart = ContinuousClock.now
        let reachable = await Self.remoteEndpointReachable(endpoint)
        let durationMs = elapsedMs(since: probeStart)

        remoteProbeCache = RemoteProbeCache(
            endpoint: endpoint,
            reachable: reachable,
            checkedAt: Date()
        )

        if let annotation {
            recordVoiceMetric(
                .voiceRemoteProbeMs,
                valueMs: durationMs,
                annotation: annotation,
                status: reachable ? "ok" : "error",
                extraTags: [
                    "cached": "0",
                    "reachable": reachable ? "1" : "0",
                    "host": endpoint.host ?? "unknown",
                ]
            )
        }

        logger.info(
            "Remote ASR probe: \(endpoint.absoluteString) => \(reachable ? "reachable" : "unreachable")"
        )
        return reachable
    }

    nonisolated private static func remoteEndpointReachable(_ endpoint: URL) async -> Bool {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 1.5

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.5
        config.timeoutIntervalForResource = 2
        config.waitsForConnectivity = false

        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }

            // Any non-5xx response means the host is reachable.
            return httpResponse.statusCode < 500
        } catch {
            return false
        }
    }

    // MARK: - Pre-warm

    /// Check model availability and cache audio format in the background.
    /// Call from ChatView's .task {} so the first mic tap is fast.
    /// Safe to call multiple times — no-ops after first success for the same locale+engine.
    func prewarm(keyboardLanguage: String? = nil, source: String = "unknown") async {
        let locale = Self.resolvedLocale(keyboardLanguage: keyboardLanguage)
        let localeID = locale.identifier(.bcp47)
        let engine = await effectiveEngine(for: locale, source: source)
        let key = Self.modelKey(engine: engine, localeID: localeID)
        let metricAnnotation = VoiceMetricAnnotation(
            engine: engine.logName,
            locale: localeID,
            source: source
        )

        if modelReady, cachedModelKey == nil || cachedModelKey == key {
            return
        }

        if engine == .remoteASR {
            guard let endpoint = remoteASREndpoint else {
                logger.warning("Skipping remote prewarm: endpoint not configured")
                return
            }
            _ = await probeRemoteReachability(
                endpoint: endpoint,
                forceRefresh: true,
                annotation: metricAnnotation
            )
        }

        let prewarmStart = ContinuousClock.now
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
        let engine = await effectiveEngine(for: locale, source: source)
        activeEngine = engine
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
            let userFacingMessage = userFacingErrorMessage(for: error)
            recordVoiceMetric(
                .voiceSetupMs,
                valueMs: totalMs,
                annotation: metricAnnotation,
                phase: .total,
                status: "error",
                extraTags: [
                    "path": modelPathTag,
                    "error": String(describing: type(of: error)),
                    "error_kind": Self.metricErrorKind(for: error),
                ]
            )
            logger.error("Voice setup failed: \(userFacingMessage, privacy: .public)")
            await cleanupFailedStart()
            state = .error(userFacingMessage)
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
            throw VoiceInputError.remoteEndpointNotConfigured
        }

        if engineMode == .remote {
            let reachable = await probeRemoteReachability(
                endpoint: endpoint,
                forceRefresh: true,
                annotation: metricAnnotation
            )
            guard reachable else {
                throw VoiceInputError.remoteEndpointUnreachable(
                    endpoint.host ?? endpoint.absoluteString
                )
            }
        }

        modelPathTag = "remote"
        let localeID = locale.identifier(.bcp47)
        let languageHint = Self.remoteLanguageHint(for: locale)
        let chunkProfile = Self.remoteChunkProfile(for: locale)
        remoteChunkMetricTags = chunkProfile.metricTags.merging(
            [
                "stt_profile": Self.remoteDictationSTTProfile,
                "dictation_cleanup": Self.remoteDictationCleanupEnabled ? "1" : "0",
                "overlap_text_words": String(Self.remoteOverlapTextWordCount),
                "language_hint": languageHint ?? "auto",
            ],
            uniquingKeysWith: { current, _ in current }
        )
        let setupTags = ["path": "remote"].merging(
            remoteChunkMetricTags,
            uniquingKeysWith: { current, _ in current }
        )

        // Phase 1: no model to warm — remote handles it
        let modelPhaseMs = elapsedMs(since: startTime)
        recordVoiceMetric(
            .voiceSetupMs,
            valueMs: modelPhaseMs,
            annotation: metricAnnotation,
            phase: .modelReady,
            status: "ok",
            extraTags: setupTags
        )
        logger.info(
            "Voice setup: remote ASR (endpoint: \(endpoint.absoluteString), chunk: \(chunkProfile.chunkInterval)s, overlap: \(chunkProfile.overlapDuration)s)"
        )

        // Phase 2: create remote transcriber
        let transcriberStart = ContinuousClock.now
        let config = RemoteASRTranscriber.Configuration(
            endpointURL: endpoint,
            model: "default",
            language: languageHint,
            prompt: Self.remoteDictationPrompt,
            chunkInterval: chunkProfile.chunkInterval,
            overlapDuration: chunkProfile.overlapDuration,
            requestTimeout: chunkProfile.requestTimeout,
            responseFormat: "json",
            sttProfile: Self.remoteDictationSTTProfile,
            dictationCleanup: Self.remoteDictationCleanupEnabled,
            overlapTextWordCount: Self.remoteOverlapTextWordCount
        )
        let newRemote = RemoteASRTranscriber(configuration: config)
        newRemote.onChunkTelemetry = { [weak self] chunk in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.recordRemoteChunkTelemetry(chunk, annotation: metricAnnotation)
            }
        }
        remoteTranscriber = newRemote
        activeLanguageLabel = Self.languageLabel(for: locale)

        let transcriberMs = elapsedMs(since: transcriberStart)
        recordVoiceMetric(
            .voiceSetupMs,
            valueMs: transcriberMs,
            annotation: metricAnnotation,
            phase: .transcriberCreate,
            status: "ok",
            extraTags: setupTags
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
            extraTags: setupTags
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
            extraTags: setupTags
        )
    }

    /// Start the audio engine for remote ASR — captures at device rate,
    /// resamples to 16kHz mono, feeds the remote transcriber.
    private func startRemoteAudioEngine(transcriber: RemoteASRTranscriber) throws {
        let (engine, levelStream) = try RemoteAudioEngineHelper.startEngine(
            transcriber: transcriber,
            sampleRate: transcriber.config.sampleRate
        )
        audioEngine = engine
        bindAudioLevelStream(levelStream)
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
                // Normalize chunk text and dedupe overlap between adjacent chunks.
                let normalized = Self.normalizedRemoteChunkText(result.text)
                guard !normalized.isEmpty else {
                    logger.debug("Remote chunk dropped after normalization")
                    continue
                }

                finalizedTranscript = Self.mergeRemoteChunk(
                    existing: finalizedTranscript,
                    incoming: normalized
                )
                volatileTranscript = ""
                logger.debug("Remote finalized: \(normalized)")
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
        if engine == .remoteASR {
            return nil  // Remote engine has no local model to warm
        }

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
            return nil
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
        bindAudioLevelStream(levelStream)
    }

    private func bindAudioLevelStream(_ levelStream: AsyncStream<Float>) {
        audioLevelTask?.cancel()
        audioLevelTask = Task {
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
        remoteChunkMetricTags = [:]
        audioLevelTask?.cancel()
        audioLevelTask = nil
        audioLevel = 0
        activeLanguageLabel = nil
        activeEngine = nil
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

    private static func normalizedRemoteChunkText(_ raw: String) -> String {
        let collapsed = raw
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return "" }

        var tokens = collapsed.split(separator: " ").map(String.init)

        while let first = tokens.first {
            let normalized = normalizedTokenForMerge(first)
            guard remoteFillerTokens.contains(normalized) else { break }
            tokens.removeFirst()
        }

        while let last = tokens.last {
            let normalized = normalizedTokenForMerge(last)
            guard remoteFillerTokens.contains(normalized) else { break }
            tokens.removeLast()
        }

        tokens = trimAcknowledgementEdges(tokens)
        guard !tokens.isEmpty else { return "" }

        var text = tokens.joined(separator: " ")
        text = text.replacingOccurrences(of: #" ([,.;:!?])"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func mergeRemoteChunk(existing: String, incoming: String) -> String {
        let trimmedExisting = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedExisting.isEmpty else {
            return incoming
        }

        let existingTokens = trimmedExisting.split(separator: " ").map(String.init)
        var incomingTokens = incoming.split(separator: " ").map(String.init)
        guard !existingTokens.isEmpty else { return incoming }
        guard !incomingTokens.isEmpty else { return trimmedExisting }

        if shouldSuppressAcknowledgementChunk(
            incomingTokens,
            existingTokens: existingTokens
        ) {
            return trimmedExisting
        }

        incomingTokens = trimLeadingAcknowledgement(
            incomingTokens,
            existingTokens: existingTokens
        )
        guard !incomingTokens.isEmpty else { return trimmedExisting }

        let maxOverlap = min(8, min(existingTokens.count, incomingTokens.count))
        var overlap = maxOverlap

        while overlap > 0 {
            let existingSuffix = existingTokens.suffix(overlap).map(normalizedTokenForMerge)
            let incomingPrefix = incomingTokens.prefix(overlap).map(normalizedTokenForMerge)
            if !existingSuffix.isEmpty, existingSuffix == incomingPrefix {
                let remainder = incomingTokens.dropFirst(overlap)
                guard !remainder.isEmpty else {
                    return trimmedExisting
                }
                return trimmedExisting + " " + remainder.joined(separator: " ")
            }
            overlap -= 1
        }

        if normalizedTokenForMerge(existingTokens.last ?? "")
            == normalizedTokenForMerge(incomingTokens.first ?? ""), incomingTokens.count > 1 {
            return trimmedExisting + " " + incomingTokens.dropFirst().joined(separator: " ")
        }

        return trimmedExisting + " " + incomingTokens.joined(separator: " ")
    }

    private static func trimAcknowledgementEdges(_ tokens: [String]) -> [String] {
        var trimmed = tokens

        while trimmed.count >= 3,
              let first = trimmed.first,
              remoteAcknowledgementTokens.contains(normalizedTokenForMerge(first)) {
            trimmed.removeFirst()
        }

        while trimmed.count >= 4,
              let last = trimmed.last,
              remoteAcknowledgementTokens.contains(normalizedTokenForMerge(last)) {
            trimmed.removeLast()
        }

        return trimmed
    }

    private static func trimLeadingAcknowledgement(
        _ incomingTokens: [String],
        existingTokens: [String]
    ) -> [String] {
        guard incomingTokens.count > 1 else { return incomingTokens }
        guard existingTokens.count >= 4 else { return incomingTokens }

        let lastToken = existingTokens.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let lastChar = lastToken.last, ".!?".contains(lastChar) else {
            return incomingTokens
        }

        let firstToken = incomingTokens.first ?? ""
        guard remoteAcknowledgementTokens.contains(normalizedTokenForMerge(firstToken)) else {
            return incomingTokens
        }

        return Array(incomingTokens.dropFirst())
    }

    private static func shouldSuppressAcknowledgementChunk(
        _ incomingTokens: [String],
        existingTokens: [String]
    ) -> Bool {
        guard incomingTokens.count <= 2 else { return false }
        guard existingTokens.count >= 4 else { return false }

        let normalizedIncoming = incomingTokens
            .map(normalizedTokenForMerge)
            .filter { !$0.isEmpty }
        guard !normalizedIncoming.isEmpty else { return false }
        guard normalizedIncoming.allSatisfy({ remoteAcknowledgementTokens.contains($0) }) else {
            return false
        }

        let lastToken = existingTokens.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let lastChar = lastToken.last else { return false }
        return ".!?".contains(lastChar)
    }

    private static func normalizedTokenForMerge(_ token: String) -> String {
        let filteredScalars = token.lowercased().unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar)
        }
        return String(String.UnicodeScalarView(filteredScalars))
    }

    private func userFacingErrorMessage(for error: Error) -> String {
        if let voiceError = error as? VoiceInputError,
           let description = voiceError.errorDescription,
           !description.isEmpty {
            return description
        }

        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription,
           !description.isEmpty {
            return description
        }

        return error.localizedDescription
    }

    private static func metricErrorKind(for error: Error) -> String {
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

    private func recordRemoteChunkTelemetry(
        _ chunk: RemoteASRTranscriber.ChunkTelemetry,
        annotation: VoiceMetricAnnotation
    ) {
        var tags: [String: String] = [
            "chunk_status": chunk.status.rawValue,
            "chunk_final": chunk.isFinal ? "1" : "0",
        ]
        for (key, value) in remoteChunkMetricTags {
            tags[key] = value
        }
        if let host = remoteASREndpoint?.host {
            tags["host"] = host
        }
        if let errorCategory = chunk.errorCategory {
            tags["error_category"] = errorCategory
        }

        recordVoiceMetric(
            .voiceRemoteChunkAudioMs,
            valueMs: chunk.audioDurationMs,
            annotation: annotation,
            status: chunk.status.rawValue,
            extraTags: tags
        )

        if chunk.wavBytes > 0 {
            recordVoiceCountMetric(
                .voiceRemoteChunkBytes,
                value: chunk.wavBytes,
                annotation: annotation,
                status: chunk.status.rawValue,
                extraTags: tags
            )
        }

        if let uploadDurationMs = chunk.uploadDurationMs {
            recordVoiceMetric(
                .voiceRemoteChunkUploadMs,
                valueMs: uploadDurationMs,
                annotation: annotation,
                status: chunk.status.rawValue,
                extraTags: tags
            )
        }

        if let textLength = chunk.textLength, textLength > 0 {
            recordVoiceCountMetric(
                .voiceRemoteChunkChars,
                value: textLength,
                annotation: annotation,
                status: chunk.status.rawValue,
                extraTags: tags
            )
        }

        if chunk.status == .error {
            recordVoiceCountMetric(
                .voiceRemoteChunkError,
                value: 1,
                annotation: annotation,
                status: chunk.status.rawValue,
                extraTags: tags
            )
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

    private func recordVoiceCountMetric(
        _ metric: ChatMetricName,
        value: Int,
        annotation: VoiceMetricAnnotation,
        status: String? = nil,
        extraTags: [String: String] = [:]
    ) {
        let tags = annotation.tags(status: status, extra: extraTags)
        let clampedValue = max(0, value)

        Task.detached(priority: .utility) {
            await ChatMetricsService.shared.record(
                metric: metric,
                value: Double(clampedValue),
                unit: .count,
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
    case remoteEndpointNotConfigured
    case remoteEndpointUnreachable(String)
    case remoteRequestTimedOut
    case remoteNetwork(String?)
    case remoteBadResponseStatus(Int)
    case remoteInvalidResponse
    case remoteDecodeFailed
    case internalError(String)

    var telemetryCategory: String {
        switch self {
        case .remoteRequestTimedOut:
            "timeout"
        case .remoteEndpointUnreachable, .remoteNetwork:
            "network"
        case .remoteBadResponseStatus:
            "http_status"
        case .remoteInvalidResponse, .remoteDecodeFailed:
            "decode"
        case .remoteEndpointNotConfigured:
            "misconfigured"
        case .localeNotSupported, .internalError:
            "other"
        }
    }

    var errorDescription: String? {
        switch self {
        case .localeNotSupported(let locale):
            "Speech recognition not supported for \(locale)"
        case .remoteEndpointNotConfigured:
            "Remote ASR endpoint is not configured. Open Settings → Voice Input."
        case .remoteEndpointUnreachable(let host):
            "Can’t reach remote ASR endpoint (\(host)). Check your server and network."
        case .remoteRequestTimedOut:
            "Remote ASR request timed out. Check server load or network latency."
        case .remoteNetwork:
            "Network error while contacting remote ASR."
        case .remoteBadResponseStatus(let statusCode):
            "Remote ASR returned HTTP \(statusCode)."
        case .remoteInvalidResponse:
            "Remote ASR returned an invalid response."
        case .remoteDecodeFailed:
            "Remote ASR response could not be decoded."
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

private enum RemoteAudioEngineHelper {
    static func startEngine(
        transcriber: RemoteASRTranscriber,
        sampleRate: Int
    ) throws -> (AVAudioEngine, AsyncStream<Float>) {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
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

        let (levelStream, levelContinuation) = AsyncStream<Float>.makeStream()

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak transcriber] buffer, _ in
            guard let transcriber else { return }

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

            if let channelData = outputBuffer.floatChannelData?[0] {
                let frameLength = UInt(outputBuffer.frameLength)
                var rms: Float = 0
                vDSP_rmsqv(channelData, 1, &rms, frameLength)
                let level = min(1.0, rms * 25.0)
                levelContinuation.yield(level)
            }

            transcriber.appendAudio(buffer: outputBuffer)
        }

        engine.prepare()
        try engine.start()
        return (engine, levelStream)
    }
}
