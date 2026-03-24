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

        var accessibilityLabel: String {
            switch self {
            case .auto: return "Automatic routing"
            case .onDevice: return "On-device transcription"
            case .remote: return "Remote transcription"
            }
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

    /// Shared helpers for pluggable provider routing + active session lifecycle.
    private let providerRegistry: VoiceProviderRegistry
    private let routeResolver: VoiceInputRouteResolver
    private let sessionMonitor: VoiceInputSessionMonitor
    private let systemAccess: any VoiceInputSystemAccessing

    /// Operation lock — prevents overlapping async operations.
    private var operationInFlight = false

    /// Request ID for start operations, used to cancel stale in-flight starts.
    private var nextStartRequestID = 0
    private var activeStartRequestID: Int?

    // MARK: - Session Attribution

    /// Active session ID for metric attribution. Set by ChatView on session connect.
    var activeSessionId: String?

    // MARK: - Remote ASR Configuration

    /// Base URL for the remote ASR server (e.g. `http://mac-studio.local:8321`).
    /// When nil, remote mode is unavailable.
    private(set) var remoteASREndpoint: URL?

    /// User-selected engine routing mode.
    private(set) var engineMode: EngineMode = .auto

    /// Backward-compatible engine preference surface used by tests.
    /// `nil` = auto, `.remoteASR` = remote mode, on-device values = on-device mode.
    private(set) var enginePreference: TranscriptionEngine?

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

    // periphery:ignore - used by RemoteASRTranscriberTests via @testable import
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
    /// Resolve the effective engine, considering mode + remote reachability.
    private func effectiveEngine(for locale: Locale, source: String) async -> TranscriptionEngine {
        let fallback = Self.preferredEngine(for: locale)
        let localeID = locale.identifier(.bcp47)
        let annotation = VoiceMetricAnnotation(
            engine: TranscriptionEngine.remoteASR.logName,
            locale: localeID,
            source: source
        )

        let decision = await routeResolver.resolveEngine(
            mode: engineMode,
            remoteEndpoint: remoteASREndpoint,
            fallback: fallback
        )

        if let probe = decision.probe {
            recordRemoteProbeMetric(probe, annotation: annotation)
            if !probe.reachable {
                logger.info("Remote ASR unreachable; using on-device engine")
            }
        }

        return decision.engine
    }

    private func provider(
        for engine: TranscriptionEngine
    ) -> (any VoiceTranscriptionProvider) {
        guard let provider = providerRegistry.provider(for: engine) else {
            fatalError("No voice provider registered for \(engine.rawValue)")
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

    private func applyRemoteEndpoint(_ url: URL?) {
        remoteASREndpoint = url
        routeResolver.updateRemoteEndpoint(url)
        invalidateModelCache()
        logger.info("Remote ASR endpoint: \(url?.absoluteString ?? "disabled")")
    }

    private func invalidateModelCache() {
        providerRegistry.provider(for: .modernSpeech)?.invalidateCache()
        providerRegistry.provider(for: .classicDictation)?.invalidateCache()
        providerRegistry.provider(for: .remoteASR)?.invalidateCache()
    }

    // MARK: - Pre-warm

    /// Check model availability and cache audio format in the background.
    /// Call from ChatView's .task {} so the first mic tap is fast.
    /// Safe to call multiple times — no-ops after first success for the same locale+engine.
    func prewarm(keyboardLanguage: String? = nil, source: String = "unknown") async {
        let locale = Self.resolvedLocale(keyboardLanguage: keyboardLanguage)
        let localeID = locale.identifier(.bcp47)
        let engine = await effectiveEngine(for: locale, source: source)
        let metricAnnotation = VoiceMetricAnnotation(
            engine: engine.logName,
            locale: localeID,
            source: source
        )
        let prewarmStart = ContinuousClock.now
        guard state == .idle else { return }

        do {
            if engine == .remoteASR,
               let endpoint = remoteASREndpoint {
                let probe = await routeResolver.probeRemoteReachability(
                    endpoint: endpoint,
                    forceRefresh: true
                )
                recordRemoteProbeMetric(probe, annotation: metricAnnotation)
                logger.info(
                    "Remote ASR probe: \(endpoint.absoluteString) => \(probe.reachable ? "reachable" : "unreachable")"
                )
            }

            try await provider(for: engine).prewarm(
                context: VoiceProviderContext(
                    locale: locale,
                    source: source,
                    remoteEndpoint: remoteASREndpoint
                )
            )

            let durationMs = elapsedMs(since: prewarmStart)
            recordVoiceMetric(
                .voicePrewarmMs,
                valueMs: durationMs,
                annotation: metricAnnotation,
                phase: .prewarm,
                status: "ok"
            )
            logger.info("Pre-warmed \(engine.logName) model (locale: \(localeID))")
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

        if !systemAccess.hasPermissions {
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
        let metricAnnotation = VoiceMetricAnnotation(
            engine: engine.logName,
            locale: localeID,
            source: source
        )
        let context = VoiceProviderContext(
            locale: locale,
            source: source,
            remoteEndpoint: remoteASREndpoint
        )
        let provider = provider(for: engine)
        var modelPathTag = "warm_cache"

        do {
            try ensureStartRequestActive(requestID)

            if engine == .remoteASR,
               engineMode == .remote,
               let endpoint = remoteASREndpoint {
                let probe = await routeResolver.probeRemoteReachability(
                    endpoint: endpoint,
                    forceRefresh: true
                )
                recordRemoteProbeMetric(probe, annotation: metricAnnotation)
                guard probe.reachable else {
                    throw VoiceInputError.remoteEndpointUnreachable(
                        endpoint.host ?? endpoint.absoluteString
                    )
                }
            }

            let timings = try await startProviderRecording(
                requestID: requestID,
                startTime: startTime,
                engine: engine,
                locale: locale,
                localeID: localeID,
                provider: provider,
                context: context,
                metricAnnotation: metricAnnotation,
                modelPathTag: &modelPathTag
            )

            state = .recording

            // Emit telemetry AFTER state transition — off the critical path
            emitStartupTelemetry(timings, annotation: metricAnnotation)
            logger.error("Voice setup: recording started in \(timings.totalMs)ms total (engine: \(engine.logName), locale: \(localeID))")
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

        await sessionMonitor.stop()

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
            if let activeEngine {
                provider(for: activeEngine).cancelPreparation()
            }
        }

        await sessionMonitor.cancel()

        deactivateAudioSession()
        teardownSession()

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
    }

    // MARK: - Provider Recording

    private func startProviderRecording(
        requestID: Int,
        startTime: ContinuousClock.Instant,
        engine: TranscriptionEngine,
        locale: Locale,
        localeID: String,
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
        timings.modelReadyMs = elapsedMs(since: modelPhaseStart)

        let transcriberStart = ContinuousClock.now
        let session = try provider.makeSession(context: context, preparation: preparation)
        activeLanguageLabel = Self.languageLabel(for: locale)
        timings.transcriberCreateMs = elapsedMs(since: transcriberStart)

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
                logger.error("Voice latency: first result in \(latencyMs)ms (type: \(resultType))")
            },
            onError: { [weak self] error in
                guard let self else { return }
                logger.error("Results stream error: \(error.localizedDescription)")
                self.state = .error("Transcription failed")
                self.scheduleErrorReset()
            }
        )

        try setupAudioSession()
        let sessionTimings = try await session.start()
        try ensureStartRequestActive(requestID)

        timings.analyzerStartMs = sessionTimings.analyzerStartMs
        timings.audioStartMs = sessionTimings.audioStartMs
        timings.totalMs = elapsedMs(since: startTime)

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
            volatileTranscript = text
            logger.debug("Volatile: \(text)")
        case .appendFinalTranscript(let text):
            finalizedTranscript += text
            volatileTranscript = ""
            logger.debug("Finalized append: \(text)")
        case .replaceFinalTranscript(let text):
            finalizedTranscript = text
            volatileTranscript = ""
            logger.debug("Finalized replace: \(text)")
        case .remoteChunkTelemetry(let chunk):
            recordRemoteChunkTelemetry(chunk, annotation: annotation)
        }
    }

    // MARK: - Cleanup

    private func teardownSession() {
        sessionMonitor.teardown()
        audioLevel = 0
        activeLanguageLabel = nil
        activeEngine = nil
    }

    private func cleanupFailedStart() async {
        await sessionMonitor.cancel()
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

    private func userFacingErrorMessage(for error: Error) -> String {
        VoiceInputTelemetry.userFacingMessage(for: error)
    }

    private static func metricErrorKind(for error: Error) -> String {
        VoiceInputTelemetry.metricErrorKind(for: error)
    }

    private func recordRemoteProbeMetric(
        _ probe: VoiceInputRouteResolver.RemoteProbeResult,
        annotation: VoiceMetricAnnotation
    ) {
        recordVoiceMetric(
            .voiceRemoteProbeMs,
            valueMs: probe.durationMs,
            annotation: annotation,
            status: probe.reachable ? "ok" : "error",
            extraTags: [
                "cached": probe.cached ? "1" : "0",
                "reachable": probe.reachable ? "1" : "0",
                "host": probe.host,
            ]
        )
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
