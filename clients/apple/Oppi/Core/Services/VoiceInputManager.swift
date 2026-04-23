@preconcurrency import AVFoundation
import Foundation
import OSLog

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
        case serverDictation

        var logName: String {
            switch self {
            case .modernSpeech: return "speech"
            case .classicDictation: return "dictation"
            case .serverDictation: return "server"
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

        var accessibilityLabel: String {
            switch self {
            case .auto: return "Automatic routing"
            case .onDevice: return "On-device transcription"
            case .remote: return "Remote transcription"
            }
        }
    }

    /// Yuwp-style preview split for full-replacement transcript updates.
    /// Everything after `committedText` stays visually volatile until the next
    /// segment commit (`snap`) settles it.
    private struct ReplaceTranscriptState {
        var committedText = ""
        var activeText = ""

        var isTracking: Bool {
            !committedText.isEmpty || !activeText.isEmpty
        }

        mutating func reset() {
            committedText = ""
            activeText = ""
        }

        mutating func applyReplacement(fullText: String, snap: Bool) {
            let trimmedFullText = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedFullText.isEmpty else {
                reset()
                return
            }

            if snap {
                committedText = trimmedFullText
                activeText = ""
                return
            }

            if let active = Self.splitActiveText(from: trimmedFullText, committedText: committedText) {
                activeText = active
            } else {
                committedText = ""
                activeText = trimmedFullText
            }
        }

        func visibleActiveSuffixLength(in displayText: String) -> Int {
            guard isTracking else { return 0 }
            let trimmedDisplayText = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedDisplayText.isEmpty else { return 0 }

            let committedPrefixLength = committedVisiblePrefixLength(in: trimmedDisplayText)
            return max(0, trimmedDisplayText.count - committedPrefixLength)
        }

        private func committedVisiblePrefixLength(in displayText: String) -> Int {
            guard !displayText.isEmpty, !committedText.isEmpty else { return 0 }
            let shared = Self.commonPrefixCount(displayText, committedText)

            if !activeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               shared < displayText.count {
                let index = displayText.index(displayText.startIndex, offsetBy: shared)
                if displayText[index] == " " {
                    return min(displayText.count, shared + 1)
                }
            }

            return min(displayText.count, shared)
        }

        private static func splitActiveText(from fullText: String, committedText: String) -> String? {
            let trimmedCommitted = committedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedCommitted.isEmpty else { return fullText }
            if fullText == trimmedCommitted { return "" }

            let separator = trimmedCommitted + " "
            guard fullText.hasPrefix(separator) else { return nil }
            return String(fullText.dropFirst(separator.count))
        }

        private static func commonPrefixCount(_ lhs: String, _ rhs: String) -> Int {
            var count = 0
            var leftIndex = lhs.startIndex
            var rightIndex = rhs.startIndex

            while leftIndex < lhs.endIndex,
                  rightIndex < rhs.endIndex,
                  lhs[leftIndex] == rhs[rightIndex] {
                count += 1
                leftIndex = lhs.index(after: leftIndex)
                rightIndex = rhs.index(after: rightIndex)
            }

            return count
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
        let base: String
        if typewriterAnimator.isAnimating {
            // During animation, show the partially revealed text.
            base = typewriterAnimator.displayText + volatileTranscript
        } else {
            base = finalizedTranscript + volatileTranscript
        }
        return base.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Visible volatile suffix in the current transcript preview.
    /// Used by the composer to tint unstable text without affecting settled text.
    var currentTranscriptVolatileSuffixLength: Int {
        if replaceTranscriptState.isTracking {
            return replaceTranscriptState.visibleActiveSuffixLength(in: currentTranscript)
        }

        if typewriterAnimator.isAnimating {
            return min(currentTranscript.count, typewriterAnimator.visibleAnimatedSuffixLength)
        }

        guard !volatileTranscript.isEmpty else { return 0 }
        return min(currentTranscript.count, volatileTranscript.count)
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
            case .serverDictation:
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

    /// Shared helpers for pluggable provider routing + active session lifecycle.
    private let providerRegistry: VoiceProviderRegistry
    private let routeResolver: VoiceInputRouteResolver
    private let sessionMonitor: VoiceInputSessionMonitor
    private let systemAccess: any VoiceInputSystemAccessing

    /// Drives character-by-character text reveal for server dictation updates.
    let typewriterAnimator = TypewriterAnimator()

    /// Operation lock — prevents overlapping async operations.
    private var operationInFlight = false

    /// Request ID for start operations, used to cancel stale in-flight starts.
    private var nextStartRequestID = 0
    private var activeStartRequestID: Int?

    // MARK: - Session Attribution

    /// Active session ID for metric attribution. Set by ChatView on session connect.
    var activeSessionId: String?

    // MARK: - Dictation Telemetry State

    private var activeMetricAnnotation: VoiceMetricAnnotation?
    private var activeDictationMetricTags: [String: String] = [:]
    private var dictationSessionStart: ContinuousClock.Instant?
    private var recordingStart: ContinuousClock.Instant?
    private var resultUpdateCount = 0
    private var replaceTranscriptState = ReplaceTranscriptState()

    // MARK: - Server Configuration

    /// Server credentials for the Oppi dictation endpoint.
    /// Set by ChatView when server connection is active.
    private(set) var serverCredentials: ServerCredentials?
    private(set) var serverConnection: ServerConnection?

    /// User-selected engine routing mode.
    private(set) var engineMode: EngineMode = .auto

    // MARK: - Init

    init(
        providerRegistry: VoiceProviderRegistry = .makeDefault(),
        routeResolver: VoiceInputRouteResolver = VoiceInputRouteResolver(),
        sessionMonitor: VoiceInputSessionMonitor = VoiceInputSessionMonitor(),
        systemAccess: any VoiceInputSystemAccessing = VoiceInputSystemAccess.live
    ) {
        self.providerRegistry = providerRegistry
        self.routeResolver = routeResolver
        self.sessionMonitor = sessionMonitor
        self.systemAccess = systemAccess
        loadPreferences()
    }

    /// Reload persisted voice settings.
    func loadPreferences() {
        applyEngineMode(from: VoiceInputPreferences.engineMode)
    }

    /// Update server credentials for the dictation provider.
    /// Called by ChatView when the server connection state changes.
    func setServerCredentials(_ credentials: ServerCredentials?) {
        serverCredentials = credentials
        if credentials != nil {
            invalidateModelCache()
        }
        let host = credentials?.host ?? "none"
        logger.info("Server credentials: \(credentials != nil ? "set" : "cleared") host=\(host)")
    }

    /// Update the server connection reference for the dictation provider.
    /// Called by ChatView alongside setServerCredentials.
    func setServerConnection(_ connection: ServerConnection?) {
        serverConnection = connection
    }

    /// Set engine mode directly.
    func setEngineMode(_ mode: EngineMode) {
        engineMode = mode
        activeEngine = nil
        invalidateModelCache()
        logger.info("Engine mode: \(mode.logName)")
    }

    // MARK: - Locale Resolution
    /// Resolve the effective engine, considering mode + server availability.
    private func effectiveEngine(for locale: Locale) async -> TranscriptionEngine {
        let fallback = Self.preferredEngine(for: locale)
        return await routeResolver.resolveEngine(
            mode: engineMode,
            fallback: fallback,
            serverCredentials: serverCredentials,
            asrAvailable: serverConnection?.asrAvailable ?? false
        )
    }

    private func provider(
        for engine: TranscriptionEngine
    ) throws -> any VoiceTranscriptionProvider {
        guard let provider = providerRegistry.provider(for: engine) else {
            throw VoiceInputError.internalError("No voice provider registered for \(engine.rawValue)")
        }
        return provider
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

    private func invalidateModelCache() {
        providerRegistry.provider(for: .modernSpeech)?.invalidateCache()
        providerRegistry.provider(for: .classicDictation)?.invalidateCache()
        providerRegistry.provider(for: .serverDictation)?.invalidateCache()
    }

    // MARK: - Pre-warm

    /// Check model availability and cache audio format in the background.
    /// Call from ChatView's .task {} so the first mic tap is fast.
    /// Safe to call multiple times — no-ops after first success for the same locale+engine.
    func prewarm(keyboardLanguage: String? = nil, source: String = "unknown") async {
        let locale = Self.resolvedLocale(keyboardLanguage: keyboardLanguage)
        let localeID = locale.identifier(.bcp47)
        let engine = await effectiveEngine(for: locale)
        let metricAnnotation = VoiceMetricAnnotation(
            engine: engine.logName,
            locale: localeID,
            source: source
        )
        let prewarmStart = ContinuousClock.now
        guard state == .idle else { return }

        do {
            try await provider(for: engine).prewarm(
                context: VoiceProviderContext(
                    locale: locale,
                    source: source,
                    serverCredentials: serverCredentials,
                    serverConnection: serverConnection
                )
            )

            let durationMs = prewarmStart.elapsedMs()
            recordVoiceMetric(
                .voicePrewarmMs,
                valueMs: durationMs,
                annotation: metricAnnotation,
                phase: .prewarm,
                status: "ok"
            )
            logger.info("Pre-warmed \(engine.logName) model (locale: \(localeID))")
        } catch is CancellationError {
            let durationMs = prewarmStart.elapsedMs()
            recordVoiceMetric(
                .voicePrewarmMs,
                valueMs: durationMs,
                annotation: metricAnnotation,
                phase: .prewarm,
                status: "cancelled"
            )
            logger.info("Pre-warm cancelled for \(engine.logName) (locale: \(localeID))")
        } catch {
            let durationMs = prewarmStart.elapsedMs()
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
    }

    // MARK: - Permissions

    /// Request mic + speech permissions. Returns true if both granted.
    func requestPermissions() async -> Bool {
        let granted = await systemAccess.requestPermissions()
        guard granted else {
            if AVAudioApplication.shared.recordPermission != .granted {
                logger.warning("Microphone permission denied")
            } else {
                logger.warning("Speech recognition permission denied")
            }
            return false
        }
        return true
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
        activeMetricAnnotation = nil
        activeDictationMetricTags = [:]
        dictationSessionStart = nil
        recordingStart = nil
        resultUpdateCount = 0
        replaceTranscriptState.reset()

        state = .preparingModel
        let startTime = ContinuousClock.now
        let locale = Self.resolvedLocale(keyboardLanguage: keyboardLanguage)
        let localeID = locale.identifier(.bcp47)
        let fallbackEngine = Self.preferredEngine(for: locale)
        var engine = await effectiveEngine(for: locale)
        var attemptedServerFallback = false
        dictationSessionStart = startTime

        while true {
            activeEngine = engine

            // Engine-aware permission check: server dictation needs only mic,
            // on-device engines need both mic + speech recognition.
            switch engine {
            case .serverDictation:
                if !systemAccess.hasMicPermission {
                    guard await systemAccess.requestMicPermission() else {
                        activeEngine = nil
                        state = .error("Microphone permission denied")
                        scheduleErrorReset()
                        return
                    }
                }
            case .modernSpeech, .classicDictation:
                if !systemAccess.hasPermissions {
                    guard await requestPermissions() else {
                        activeEngine = nil
                        state = .error("Microphone or speech permission denied")
                        scheduleErrorReset()
                        return
                    }
                }
            }

            let metricAnnotation = VoiceMetricAnnotation(
                engine: engine.logName,
                locale: localeID,
                source: source
            )
            activeMetricAnnotation = metricAnnotation

            let context = VoiceProviderContext(
                locale: locale,
                source: source,
                serverCredentials: serverCredentials,
                serverConnection: serverConnection
            )
            let provider = try provider(for: engine)
            var modelPathTag = "warm_cache"

            do {
                try ensureStartRequestActive(requestID)

                let timings = try await startProviderRecording(
                    requestID: requestID,
                    startTime: startTime,
                    locale: locale,
                    provider: provider,
                    context: context,
                    metricAnnotation: metricAnnotation,
                    modelPathTag: &modelPathTag
                )

                state = .recording

                // Emit telemetry AFTER state transition — off the critical path
                emitStartupTelemetry(timings, annotation: metricAnnotation)
                logger.error("Voice setup: recording started in \(timings.totalMs)ms total (engine: \(engine.logName), locale: \(localeID))")
                return
            } catch is CancellationError {
                let totalMs = startTime.elapsedMs()
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
                if engine == .serverDictation, !attemptedServerFallback {
                    attemptedServerFallback = true
                    let message = userFacingErrorMessage(for: error)
                    logger.warning(
                        "Server dictation setup failed: \(message, privacy: .public) — falling back to \(fallbackEngine.logName, privacy: .public)"
                    )
                    await cleanupFailedStart()
                    state = .preparingModel
                    engine = fallbackEngine
                    continue
                }

                let totalMs = startTime.elapsedMs()
                let userFacingMessage = userFacingErrorMessage(for: error)
                let errorKind = Self.metricErrorKind(for: error)
                recordVoiceMetric(
                    .voiceSetupMs,
                    valueMs: totalMs,
                    annotation: metricAnnotation,
                    phase: .total,
                    status: "error",
                    extraTags: [
                        "path": modelPathTag,
                        "error": String(describing: type(of: error)),
                        "error_kind": errorKind,
                    ]
                )
                recordDictationCountMetric(
                    .dictationError,
                    value: 1,
                    annotation: metricAnnotation,
                    status: "error",
                    extraTags: [
                        "phase": "setup",
                        "error_kind": errorKind,
                    ]
                )
                logger.error("Voice setup failed: \(userFacingMessage, privacy: .public)")
                await cleanupFailedStart()
                state = .error(userFacingMessage)
                scheduleErrorReset()
                throw error
            }
        }
    }

    /// Stop recording. Finalizes transcription and waits for last results.
    /// Returns the final transcript captured before session teardown.
    @discardableResult
    func stopRecording() async -> String {
        guard state == .recording else {
            logger.warning("Cannot stop: state is \(String(describing: self.state))")
            return ""
        }
        guard !operationInFlight else {
            logger.warning("Cannot stop: operation already in flight")
            return ""
        }
        operationInFlight = true
        defer { operationInFlight = false }

        state = .processing
        typewriterAnimator.commitCurrentAnimation()
        logger.info("Stopping recording")

        let finalizeStart = ContinuousClock.now
        let previewTranscript = currentTranscript
        let audioDurationMs = recordingStart?.elapsedMs() ?? 0

        await sessionMonitor.stop()

        let finalizeMs = finalizeStart.elapsedMs()
        let sessionMs = dictationSessionStart?.elapsedMs() ?? finalizeMs
        emitDictationStopTelemetry(
            finalizeMs: finalizeMs,
            sessionMs: sessionMs,
            audioDurationMs: audioDurationMs,
            previewTranscript: previewTranscript,
            finalTranscript: currentTranscript
        )

        let result = currentTranscript

        deactivateAudioSession()
        teardownSession()
        state = .idle
        logger.info("Stopped. Transcript length: \(result.count) chars")
        return result
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
            if let activeEngine {
                try? provider(for: activeEngine).cancelPreparation()
            }
        }

        await sessionMonitor.cancel()

        deactivateAudioSession()
        teardownSession()

        emitDictationCancelTelemetry()

        finalizedTranscript = ""
        volatileTranscript = ""
        operationInFlight = false
        state = .idle
    }

    // MARK: - Startup Timings (deferred telemetry)

    /// Captured during startProviderRecording, emitted after state = .recording.
    private struct StartupTimings {
        var modelReadyMs: Int = 0
        var transcriberCreateMs: Int = 0
        var analyzerStartMs: Int = 0
        var audioStartMs: Int = 0
        var totalMs: Int = 0
        var pathTag: String = "warm_cache"
        var providerTags: [String: String] = [:]
    }

    private func emitStartupTelemetry(
        _ timings: StartupTimings,
        annotation: VoiceMetricAnnotation
    ) {
        // Build merged tags once for all 5 emissions (deferred — not on hot path)
        var tags = ["path": timings.pathTag]
        for (k, v) in timings.providerTags { tags[k] = v }
        activeDictationMetricTags = tags

        recordVoiceMetric(.voiceSetupMs, valueMs: timings.modelReadyMs,
                          annotation: annotation, phase: .modelReady, status: "ok", extraTags: tags)
        recordVoiceMetric(.voiceSetupMs, valueMs: timings.transcriberCreateMs,
                          annotation: annotation, phase: .transcriberCreate, status: "ok", extraTags: tags)
        recordVoiceMetric(.voiceSetupMs, valueMs: timings.analyzerStartMs,
                          annotation: annotation, phase: .analyzerStart, status: "ok", extraTags: tags)
        recordVoiceMetric(.voiceSetupMs, valueMs: timings.audioStartMs,
                          annotation: annotation, phase: .audioStart, status: "ok", extraTags: tags)
        recordVoiceMetric(.voiceSetupMs, valueMs: timings.totalMs,
                          annotation: annotation, phase: .total, status: "ok", extraTags: tags)
        recordDictationMetric(
            .dictationSetupMs,
            valueMs: timings.totalMs,
            annotation: annotation,
            status: "ok",
            extraTags: tags
        )
    }

    // MARK: - Provider Recording

    private func startProviderRecording(
        requestID: Int,
        startTime: ContinuousClock.Instant,
        locale: Locale,
        provider: any VoiceTranscriptionProvider,
        context: VoiceProviderContext,
        metricAnnotation: VoiceMetricAnnotation,
        modelPathTag: inout String
    ) async throws -> StartupTimings {
        var timings = StartupTimings()

        let modelPhaseStart = ContinuousClock.now
        let preparation = try await provider.prepareSession(context: context)
        try ensureStartRequestActive(requestID)

        modelPathTag = preparation.pathTag
        timings.pathTag = modelPathTag
        timings.providerTags = preparation.setupMetricTags
        timings.modelReadyMs = modelPhaseStart.elapsedMs()

        let transcriberStart = ContinuousClock.now
        let session = try provider.makeSession(context: context, preparation: preparation)
        activeLanguageLabel = Self.languageLabel(for: locale)
        timings.transcriberCreateMs = transcriberStart.elapsedMs()

        try ensureStartRequestActive(requestID)

        sessionMonitor.bind(
            session: session,
            recordingStartTime: ContinuousClock.now,
            onAudioLevel: { [weak self] level in
                self?.audioLevel = level
            },
            onEvent: { [weak self] event in
                self?.applySessionEvent(event, annotation: metricAnnotation)
            },
            onFirstTranscript: { [weak self] latencyMs, resultType in
                guard let self else { return }
                self.recordVoiceMetric(
                    .voiceFirstResultMs,
                    valueMs: latencyMs,
                    annotation: metricAnnotation,
                    phase: .firstResult,
                    status: "ok",
                    extraTags: ["result_type": resultType]
                )
                self.recordDictationMetric(
                    .dictationFirstResultMs,
                    valueMs: latencyMs,
                    annotation: metricAnnotation,
                    status: "ok",
                    extraTags: ["result_type": resultType]
                )
                logger.error("Voice latency: first result in \(latencyMs)ms (type: \(resultType))")
            },
            onError: { [weak self] error in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    await self?.handleSessionStreamError(error, annotation: metricAnnotation)
                }
            }
        )

        try setupAudioSession()
        let sessionTimings = try await session.start()
        try ensureStartRequestActive(requestID)

        timings.analyzerStartMs = sessionTimings.analyzerStartMs
        timings.audioStartMs = sessionTimings.audioStartMs
        timings.totalMs = startTime.elapsedMs()
        recordingStart = ContinuousClock.now

        return timings
    }

    // MARK: - Setup

    private func setupAudioSession() throws {
        try systemAccess.activateAudioSession()
    }

    private func deactivateAudioSession() {
        systemAccess.deactivateAudioSession()
    }

    private func applySessionEvent(
        _ event: VoiceSessionEvent,
        annotation: VoiceMetricAnnotation
    ) {
        switch event {
        case .partialTranscript(let text):
            replaceTranscriptState.reset()
            volatileTranscript = text
            resultUpdateCount += 1
            logger.debug("Volatile: \(text.count) chars")
        case .appendFinalTranscript(let text):
            replaceTranscriptState.reset()
            finalizedTranscript += text
            volatileTranscript = ""
            resultUpdateCount += 1
            logger.debug("Finalized append: \(text.count) chars")
        case .replaceFinalTranscript(let text, let snap):
            replaceTranscriptState.applyReplacement(fullText: text, snap: snap)
            finalizedTranscript = text
            volatileTranscript = ""
            resultUpdateCount += 1
            if state == .recording {
                if snap {
                    // Segment commit: keep the full replacement visible, but
                    // settle the volatile styling immediately.
                    typewriterAnimator.commitCurrentAnimation()
                } else {
                    typewriterAnimator.update(fullText: text)
                }
            }
            logger.debug("Finalized replace: \(text.count) chars\(snap ? " (snap)" : "")")

        case .remoteChunkTelemetry(let chunk):
            recordRemoteChunkTelemetry(chunk, annotation: annotation)

        case .providerMetricTags(let tags):
            // Merge backend metadata (stt_backend, model) resolved after readiness.
            // Subsequent metrics (finalize, session, audio_duration) get the real values.
            for (key, value) in tags {
                activeDictationMetricTags[key] = value
            }
        }
    }

    // MARK: - Cleanup

    private func teardownSession() {
        typewriterAnimator.reset()
        sessionMonitor.teardown()
        finalizedTranscript = ""
        volatileTranscript = ""
        replaceTranscriptState.reset()
        audioLevel = 0
        activeLanguageLabel = nil
        activeEngine = nil
        activeMetricAnnotation = nil
        activeDictationMetricTags = [:]
        dictationSessionStart = nil
        recordingStart = nil
        resultUpdateCount = 0
    }

    private func cleanupFailedStart() async {
        await sessionMonitor.cancel()
        deactivateAudioSession()
        teardownSession()
    }

    private func handleSessionStreamError(
        _ error: Error,
        annotation: VoiceMetricAnnotation
    ) async {
        logger.error("Results stream error: \(error.localizedDescription, privacy: .public)")
        recordDictationCountMetric(
            .dictationError,
            value: 1,
            annotation: annotation,
            status: "error",
            extraTags: [
                "phase": "stream",
                "error_kind": Self.metricErrorKind(for: error),
            ]
        )

        await sessionMonitor.cancel()
        deactivateAudioSession()
        teardownSession()
        state = .error(userFacingErrorMessage(for: error))
        scheduleErrorReset()
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

    private func userFacingErrorMessage(for error: Error) -> String {
        VoiceInputTelemetry.userFacingMessage(for: error)
    }

    private static func metricErrorKind(for error: Error) -> String {
        VoiceInputTelemetry.metricErrorKind(for: error)
    }

    private func recordRemoteChunkTelemetry(
        _ chunk: VoiceRemoteChunkTelemetry,
        annotation: VoiceMetricAnnotation
    ) {
        VoiceInputTelemetry.recordRemoteChunkTelemetry(
            chunk,
            annotation: annotation,
            sessionId: activeSessionId
        )
    }

    private func recordVoiceMetric(
        _ metric: ChatMetricName,
        valueMs: Int,
        annotation: VoiceMetricAnnotation,
        phase: VoiceMetricPhase? = nil,
        status: String? = nil,
        extraTags: [String: String] = [:]
    ) {
        VoiceInputTelemetry.recordMetric(
            metric,
            valueMs: valueMs,
            annotation: annotation,
            sessionId: activeSessionId,
            phase: phase,
            status: status,
            extraTags: extraTags
        )
    }

    private func recordDictationMetric(
        _ metric: ChatMetricName,
        valueMs: Int,
        annotation: VoiceMetricAnnotation,
        status: String? = nil,
        extraTags: [String: String] = [:]
    ) {
        VoiceInputTelemetry.recordMetric(
            metric,
            valueMs: valueMs,
            annotation: annotation,
            sessionId: activeSessionId,
            status: status,
            extraTags: mergedDictationMetricTags(extraTags)
        )
    }

    private func recordDictationCountMetric(
        _ metric: ChatMetricName,
        value: Int,
        annotation: VoiceMetricAnnotation,
        status: String? = nil,
        extraTags: [String: String] = [:]
    ) {
        VoiceInputTelemetry.recordCountMetric(
            metric,
            value: value,
            annotation: annotation,
            sessionId: activeSessionId,
            status: status,
            extraTags: mergedDictationMetricTags(extraTags)
        )
    }

    private func recordDictationRatioMetric(
        _ metric: ChatMetricName,
        value: Double,
        annotation: VoiceMetricAnnotation,
        status: String? = nil,
        extraTags: [String: String] = [:]
    ) {
        VoiceInputTelemetry.recordRatioMetric(
            metric,
            value: value,
            annotation: annotation,
            sessionId: activeSessionId,
            status: status,
            extraTags: mergedDictationMetricTags(extraTags)
        )
    }

    private func mergedDictationMetricTags(_ extraTags: [String: String]) -> [String: String] {
        var tags = activeDictationMetricTags
        for (key, value) in extraTags {
            tags[key] = value
        }
        return tags
    }

    private func emitDictationStopTelemetry(
        finalizeMs: Int,
        sessionMs: Int,
        audioDurationMs: Int,
        previewTranscript: String,
        finalTranscript: String
    ) {
        guard let annotation = activeMetricAnnotation else { return }

        recordDictationMetric(
            .dictationFinalizeMs,
            valueMs: finalizeMs,
            annotation: annotation,
            status: "ok"
        )
        recordDictationMetric(
            .dictationSessionMs,
            valueMs: sessionMs,
            annotation: annotation,
            status: "ok"
        )
        recordDictationMetric(
            .dictationAudioDurationMs,
            valueMs: audioDurationMs,
            annotation: annotation,
            status: "ok"
        )
        recordDictationCountMetric(
            .dictationResultUpdates,
            value: resultUpdateCount,
            annotation: annotation,
            status: "ok"
        )
        recordDictationRatioMetric(
            .dictationPreviewFinalDelta,
            value: Self.previewFinalDelta(preview: previewTranscript, final: finalTranscript),
            annotation: annotation,
            status: "ok"
        )
    }

    private func emitDictationCancelTelemetry() {
        guard let annotation = activeMetricAnnotation else { return }
        recordDictationCountMetric(
            .dictationCancel,
            value: 1,
            annotation: annotation,
            status: "cancelled"
        )
    }

    private static func previewFinalDelta(preview: String, final: String) -> Double {
        let lhs = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhs = final.trimmingCharacters(in: .whitespacesAndNewlines)
        let maxLength = max(lhs.count, rhs.count)
        guard maxLength > 0 else { return 0 }
        let distance = levenshteinDistance(Array(lhs), Array(rhs))
        return min(1, Double(distance) / Double(maxLength))
    }

    private static func levenshteinDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }

        var previous = Array(0...rhs.count)
        var current = Array(repeating: 0, count: rhs.count + 1)

        for (i, left) in lhs.enumerated() {
            current[0] = i + 1
            for (j, right) in rhs.enumerated() {
                let substitutionCost = left == right ? 0 : 1
                current[j + 1] = min(
                    previous[j + 1] + 1,
                    current[j] + 1,
                    previous[j] + substitutionCost
                )
            }
            swap(&previous, &current)
        }

        return previous[rhs.count]
    }

    private func ensureStartRequestActive(_ requestID: Int) throws {
        guard activeStartRequestID == requestID, state == .preparingModel else {
            throw CancellationError()
        }
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
        get {
            (providerRegistry.provider(for: .classicDictation) as? AppleOnDeviceVoiceProvider)?._testModelReady ?? false
        }
        set {
            if newValue {
                (providerRegistry.provider(for: .classicDictation) as? AppleOnDeviceVoiceProvider)?._testSetModelReady()
            } else {
                providerRegistry.provider(for: .classicDictation)?.invalidateCache()
            }
        }
    }
}
#endif
