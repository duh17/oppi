@preconcurrency import AVFoundation
import Foundation
import OSLog
import Speech

private let appleVoiceProviderLogger = Logger(
    subsystem: AppIdentifiers.subsystem,
    category: "VoiceInput"
)

@MainActor
final class AppleOnDeviceVoiceProvider: VoiceTranscriptionProvider {
    nonisolated let id: VoiceProviderID
    nonisolated let engine: VoiceInputManager.TranscriptionEngine

    private var cachedModelKey: String?
    private var modelReady = false
    private var cachedFormat: AVAudioFormat?
    private struct ReadyModel {
        let format: AVAudioFormat?
        let locale: Locale
    }
    private var cachedLocale: Locale?
    private var prewarmTask: Task<ReadyModel, Error>?
    private var prewarmModelKey: String?
    private var preparationGeneration = 0
    private let resolveLocale: (VoiceInputManager.TranscriptionEngine, Locale) async throws -> Locale
    private let prepareModel: (VoiceInputManager.TranscriptionEngine, Locale) async throws -> AVAudioFormat?

    init(
        engine: VoiceInputManager.TranscriptionEngine,
        resolveLocale: @escaping (VoiceInputManager.TranscriptionEngine, Locale) async throws -> Locale = {
            try await AppleOnDeviceVoiceProvider.resolvedLocale(for: $0, requestedLocale: $1)
        },
        prepareModel: @escaping (VoiceInputManager.TranscriptionEngine, Locale) async throws -> AVAudioFormat? = {
            try await AppleOnDeviceVoiceProvider.warmModel(engine: $0, locale: $1)
        }
    ) {
        self.engine = engine
        self.resolveLocale = resolveLocale
        self.prepareModel = prepareModel
        switch engine {
        case .modernSpeech:
            id = .appleModernSpeech
        case .classicDictation:
            id = .appleClassicDictation
        case .serverDictation:
            preconditionFailure("AppleOnDeviceVoiceProvider cannot wrap server dictation")
        }
    }

    func invalidateCache() {
        modelReady = false
        cachedFormat = nil
        cachedModelKey = nil
        cachedLocale = nil
        cancelPreparation()
    }

    func cancelPreparation() {
        preparationGeneration += 1
        prewarmTask?.cancel()
        prewarmTask = nil
        prewarmModelKey = nil
    }

    func prewarm(context: VoiceProviderContext) async throws {
        _ = try await prepareSession(context: context)
    }

    func prepareSession(context: VoiceProviderContext) async throws -> VoiceProviderPreparation {
        // Lookup by requested locale before any Speech/XPC call. Successful
        // preparation includes the resolved locale as well as model/format.
        let key = Self.modelKey(engine: engine, localeID: context.locale.identifier(.bcp47))
        if modelReady, cachedModelKey == nil || cachedModelKey == key {
            let locale = cachedLocale ?? context.locale
            return VoiceProviderPreparation(
                audioFormat: cachedFormat,
                transcriptionLocale: locale,
                pathTag: "warm_cache",
                setupMetricTags: Self.metricTags(for: engine, locale: locale)
            )
        }
        if prewarmTask != nil, prewarmModelKey != key { cancelPreparation() }
        let path = prewarmTask == nil ? "cold" : "join_prewarm"
        if prewarmTask == nil {
            preparationGeneration += 1
            prewarmModelKey = key
            prewarmTask = Task {
                let locale = try await resolveLocale(engine, context.locale)
                try Task.checkCancellation()
                return ReadyModel(format: try await prepareModel(engine, locale), locale: locale)
            }
        }
        guard let task = prewarmTask else { throw CancellationError() }
        let generation = preparationGeneration
        do {
            let ready = try await task.value
            try Task.checkCancellation()
            // A same-locale retry may have replaced this task while an older
            // Speech operation ignored cancellation. Key equality is not identity.
            guard preparationGeneration == generation else { throw CancellationError() }
            cachedFormat = ready.format
            cachedLocale = ready.locale
            cachedModelKey = key
            modelReady = true
            prewarmTask = nil
            prewarmModelKey = nil
            return VoiceProviderPreparation(
                audioFormat: ready.format,
                transcriptionLocale: ready.locale,
                pathTag: path,
                setupMetricTags: Self.metricTags(for: engine, locale: ready.locale)
            )
        } catch {
            if preparationGeneration == generation {
                prewarmTask = nil
                prewarmModelKey = nil
            }
            throw error
        }
    }

    func makeSession(
        context: VoiceProviderContext,
        preparation: VoiceProviderPreparation
    ) throws -> any VoiceTranscriptionSession {
        AppleOnDeviceVoiceSession(
            transcriber: Self.makeTranscriber(
                engine: engine,
                locale: preparation.transcriptionLocale ?? context.locale
            ),
            preferredAudioFormat: preparation.audioFormat,
            contextualStrings: context.contextualStrings
        )
    }

    static func isAvailable(
        for engine: VoiceInputManager.TranscriptionEngine,
        locale: Locale
    ) async -> Bool {
        switch engine {
        case .modernSpeech:
            guard SpeechTranscriber.isAvailable else { return false }
            return await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil
        case .classicDictation:
            return await DictationTranscriber.supportedLocale(equivalentTo: locale) != nil
        case .serverDictation:
            return true
        }
    }

    static func isModelInstalled(
        for engine: VoiceInputManager.TranscriptionEngine,
        locale: Locale
    ) async -> Bool {
        switch engine {
        case .modernSpeech:
            guard SpeechTranscriber.isAvailable,
                  let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
                return false
            }
            let installed = await SpeechTranscriber.installedLocales
            return installed.contains { $0.identifier(.bcp47) == supportedLocale.identifier(.bcp47) }
        case .classicDictation:
            guard let supportedLocale = await DictationTranscriber.supportedLocale(equivalentTo: locale) else {
                return false
            }
            let installed = await DictationTranscriber.installedLocales
            return installed.contains { $0.identifier(.bcp47) == supportedLocale.identifier(.bcp47) }
        case .serverDictation:
            return true
        }
    }

    private static func modelKey(
        engine: VoiceInputManager.TranscriptionEngine,
        localeID: String
    ) -> String {
        "\(engine.rawValue)::\(localeID)"
    }

    private static func metricTags(
        for engine: VoiceInputManager.TranscriptionEngine,
        locale: Locale
    ) -> [String: String] {
        switch engine {
        case .modernSpeech:
            return [
                "provider_id": "apple_modern_speech",
                "provider_kind": "on_device",
                "stt_backend": "apple_speech",
                "model": "SpeechTranscriber",
                "transport": "local",
                "live_preview": "1",
                "transcription_locale": locale.identifier(.bcp47),
            ]
        case .classicDictation:
            return [
                "provider_id": "apple_classic_dictation",
                "provider_kind": "on_device",
                "stt_backend": "apple_dictation",
                "model": "DictationTranscriber",
                "transport": "local",
                "live_preview": "1",
                "transcription_locale": locale.identifier(.bcp47),
            ]
        case .serverDictation:
            return [:]
        }
    }

    private static func resolvedLocale(
        for engine: VoiceInputManager.TranscriptionEngine,
        requestedLocale: Locale
    ) async throws -> Locale {
        let supportedLocale: Locale?
        switch engine {
        case .modernSpeech:
            guard SpeechTranscriber.isAvailable else {
                throw VoiceInputError.localeNotSupported(requestedLocale.identifier(.bcp47))
            }
            supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale)
        case .classicDictation:
            supportedLocale = await DictationTranscriber.supportedLocale(equivalentTo: requestedLocale)
        case .serverDictation:
            return requestedLocale
        }

        guard let supportedLocale else {
            throw VoiceInputError.localeNotSupported(requestedLocale.identifier(.bcp47))
        }
        return supportedLocale
    }

    nonisolated private static func warmModel(
        engine: VoiceInputManager.TranscriptionEngine,
        locale: Locale
    ) async throws -> AVAudioFormat? {
        if engine == .serverDictation {
            return nil
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
        case .serverDictation:
            return nil
        }

        if !isInstalled {
            appleVoiceProviderLogger.info("Downloading \(engine.logName) model for \(locale.identifier)")
            if let request = try await AssetInventory.assetInstallationRequest(
                supporting: [probe.speechModule]
            ) {
                try await request.downloadAndInstall()
                appleVoiceProviderLogger.info("Model download complete")
            }
        } else {
            appleVoiceProviderLogger.info("\(engine.logName) model already installed for \(locale.identifier)")
        }

        let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [probe.speechModule]
        )
        appleVoiceProviderLogger.info("Analyzer format (\(engine.logName)): \(String(describing: format))")
        return format
    }

    nonisolated private static func makeTranscriber(
        engine: VoiceInputManager.TranscriptionEngine,
        locale: Locale
    ) -> TranscriberModule {
        switch engine {
        case .modernSpeech:
            return .speech(
                SpeechTranscriber(
                    locale: locale,
                    preset: AppleOnDeviceSpeechSettings.speechPreset
                )
            )
        case .classicDictation:
            return .dictation(
                DictationTranscriber(
                    locale: locale,
                    preset: AppleOnDeviceSpeechSettings.dictationPreset
                )
            )
        case .serverDictation:
            fatalError("makeTranscriber called for .serverDictation")
        }
    }
}

#if DEBUG
extension AppleOnDeviceVoiceProvider {
    var _testModelReady: Bool {
        modelReady
    }

    func _testSetModelReady() {
        modelReady = true
        cachedModelKey = nil
        cachedFormat = nil
    }
}
#endif

/// On-device SpeechAnalyzer knobs. iOS 27 uses `AnalyzerInputConverter` in
/// `AudioEngineHelper`; remaining capture APIs are listed in
/// `.internal/reports/ios27-on-device-dictation-improvements-2026-09-06.md`.
enum OnDeviceDictationAnalysisContext {
    static func make(phrases: [String]) -> AnalysisContext {
        let context = AnalysisContext()
        let capped = DictationContextualStrings.prepared(phrases)
        if !capped.isEmpty {
            context.contextualStrings = [.general: capped]
        }
        return context
    }
}

enum AppleOnDeviceSpeechSettings {
    static let speechPreset = SpeechTranscriber.Preset.progressiveTranscription
    static let dictationPreset = DictationTranscriber.Preset.progressiveLongDictation
    /// One live analysis session at a time (`VoiceInputManager.shared`).
    /// Models stay loaded for the process so consecutive takes do not reload.
    /// The `SpeechAnalyzer` actor still cannot be reused after finish.
    static let analyzerOptions = SpeechAnalyzer.Options(
        priority: .userInitiated,
        modelRetention: .processLifetime
    )
}

enum TranscriberModule {
    case speech(SpeechTranscriber)
    case dictation(DictationTranscriber)

    var speechModule: any SpeechModule {
        switch self {
        case .speech(let transcriber):
            transcriber
        case .dictation(let transcriber):
            transcriber
        }
    }
}

@MainActor
final class AppleOnDeviceVoiceSession: VoiceTranscriptionSession {
    let events: AsyncThrowingStream<VoiceSessionEvent, Error>
    let audioLevels: AsyncStream<Float>

    private let transcriber: TranscriberModule
    private let preferredAudioFormat: AVAudioFormat?
    private let contextualStrings: [String]
    private let eventContinuation: AsyncThrowingStream<VoiceSessionEvent, Error>.Continuation
    private let audioLevelContinuation: AsyncStream<Float>.Continuation

    private var analyzer: SpeechAnalyzer?
    private var inputBuilder: AnalyzerInputBuffer?
    private var audioCapture: (any OnDeviceAudioCapture)?
    private var resultsTask: Task<Void, Never>?
    private var audioLevelTask: Task<Void, Never>?
    private var hasCapturedAudio = false
    private var stopped = false
    private var isFinalizing = false
    private var analyzerInputFailed = false
    private var analyzerCancellation: Task<Void, Never>?

    init(
        transcriber: TranscriberModule,
        preferredAudioFormat: AVAudioFormat?,
        contextualStrings: [String]
    ) {
        self.transcriber = transcriber
        self.preferredAudioFormat = preferredAudioFormat
        self.contextualStrings = contextualStrings

        let eventPair: (
            AsyncThrowingStream<VoiceSessionEvent, Error>,
            AsyncThrowingStream<VoiceSessionEvent, Error>.Continuation
        ) = {
            var capturedContinuation: AsyncThrowingStream<VoiceSessionEvent, Error>.Continuation?
            let stream = AsyncThrowingStream<VoiceSessionEvent, Error> {
                capturedContinuation = $0
            }
            guard let continuation = capturedContinuation else {
                preconditionFailure("Failed to create voice events stream")
            }
            return (stream, continuation)
        }()
        events = eventPair.0
        eventContinuation = eventPair.1

        let (audioLevels, audioLevelContinuation) = AsyncStream.makeStream(of: Float.self)
        self.audioLevels = audioLevels
        self.audioLevelContinuation = audioLevelContinuation
    }

    func start() async throws -> VoiceSessionStartTimings {
        let analyzerStart = ContinuousClock.now
        let newAnalyzer = SpeechAnalyzer(
            modules: [transcriber.speechModule],
            options: AppleOnDeviceSpeechSettings.analyzerOptions
        )
        analyzer = newAnalyzer
        if !contextualStrings.isEmpty {
            do {
                try await newAnalyzer.setContext(
                    OnDeviceDictationAnalysisContext.make(phrases: contextualStrings)
                )
            } catch {
                appleVoiceProviderLogger.error(
                    "Failed to set dictation hint context: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        let inputs = makeAnalyzerInputBuffer()
        inputBuilder = inputs
        try await newAnalyzer.prepareToAnalyze(in: preferredAudioFormat)
        try await newAnalyzer.start(inputSequence: inputs)
        startResultsBridge()
        let analyzerStartMs = analyzerStart.elapsedMs()

        let audioStart = ContinuousClock.now
        guard let inputBuilder else {
            throw VoiceInputError.internalError("Input builder not initialized")
        }
        try await startAudioCapture {
            try AudioEngineHelper.startEngine(
                inputBuilder: inputBuilder,
                targetFormat: self.preferredAudioFormat,
                events: self.eventContinuation
            )
        }
        let audioStartMs = audioStart.elapsedMs()

        return VoiceSessionStartTimings(
            analyzerStartMs: analyzerStartMs,
            audioStartMs: audioStartMs
        )
    }

    func rebuildAudioCapture() async throws {
        guard !stopped, analyzer != nil, inputBuilder != nil else {
            throw VoiceInputError.audioCaptureUnavailable
        }
        audioLevelTask?.cancel()
        audioLevelTask = nil
        audioCapture?.stop()
        audioCapture = nil
        hasCapturedAudio = false
        guard let inputBuilder else {
            throw VoiceInputError.internalError("Input builder not initialized")
        }
        try await startAudioCapture {
            try AudioEngineHelper.startEngine(
                inputBuilder: inputBuilder,
                targetFormat: self.preferredAudioFormat,
                events: self.eventContinuation
            )
        }
    }

    func startAudioCapture(
        makeCapture: () throws -> any OnDeviceAudioCapture,
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws {
        try await DictationAudioEngineHelper.startWithFirstAudio(
            start: {
                self.hasCapturedAudio = false
                let capture = try makeCapture()
                self.audioCapture = capture
                self.startAudioLevelBridge(capture.audioLevels)
            },
            hasAudio: { self.hasCapturedAudio },
            isRunning: { self.audioCapture?.isRunning == true },
            stop: {
                self.audioLevelTask?.cancel()
                self.audioLevelTask = nil
                // Keep the analyzer sequence open for the bounded same-route retry.
                self.audioCapture?.stop()
                self.audioCapture = nil
            },
            isCancelled: { self.stopped },
            sleep: sleep
        )
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        isFinalizing = true
        defer { isFinalizing = false }
        audioCapture?.stopAndFinishInput(flush: true)
        audioCapture = nil
        finishAnalyzerInput()

        do {
            // The one-shot failure callback may have completed while recording,
            // before the manager consumes its error. Stop now owns the drain and
            // must not await ordinary finalization of that already-failed input.
            if analyzerInputFailed {
                await cancelAnalyzer()
            } else {
                try await finalizeAnalyzer()
            }
        } catch {
            appleVoiceProviderLogger.error("Error finalizing on-device session: \(error.localizedDescription)")
        }

        // A failure during finalization may have started cancellation. Keep
        // capture ownership until it finishes, even if finalization returns first.
        await analyzerCancellation?.value
#if DEBUG
        _testStopPhase = .waitingForResults
#endif
        await resultsTask?.value
#if DEBUG
        _testStopPhase = .finishedResults
#endif
        // The callback can publish cancellation while results suspend above.
        // Join again on MainActor: a nil task cannot suspend before cleanup and
        // isFinalizing's defer; a later callback therefore cannot start a drain.
        // A non-nil task is shared for this session and never replaced.
        await analyzerCancellation?.value
        cleanupAfterStop()
    }

    func cancel() async {
        guard !stopped else { return }
        stopped = true
        audioCapture?.stopAndFinishInput(flush: false)
        audioCapture = nil
        inputBuilder?.finish(discard: true)
        inputBuilder = nil

        resultsTask?.cancel()
        resultsTask = nil
        audioLevelTask?.cancel()
        audioLevelTask = nil
        await cancelAnalyzer()

        analyzer = nil
        eventContinuation.finish()
        audioLevelContinuation.finish()
    }

    private func makeAnalyzerInputBuffer(
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) -> AnalyzerInputBuffer {
        AnalyzerInputBuffer(events: eventContinuation, onFailure: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
#if DEBUG
                await self._testBeforeInputFailure?()
#endif
                await self.handleAnalyzerInputFailure()
#if DEBUG
                self._testInputFailureHandled = true
#endif
            }
        }, now: now)
    }

    private func handleAnalyzerInputFailure() async {
        // Latch on MainActor even while recording: event delivery and Stop can
        // cross after this callback. Recording still leaves cancellation to the
        // manager; once Stop owns the drain, either it or this callback cancels.
        analyzerInputFailed = true
        guard isFinalizing else { return }
        await cancelAnalyzer()
    }

    private func finalizeAnalyzer() async throws {
#if DEBUG
        if let _testFinalizeAnalyzer { try await _testFinalizeAnalyzer(); return }
#endif
        try await analyzer?.finalizeAndFinishThroughEndOfInput()
    }

    private func cancelAnalyzer() async {
        if let analyzerCancellation {
            await analyzerCancellation.value
            return
        }
#if DEBUG
        let testCancel = _testCancelAnalyzer
#endif
        let cancellation = Task { [analyzer] in
#if DEBUG
            if let testCancel { await testCancel(); return }
#endif
            await analyzer?.cancelAndFinishNow()
            return
        }
        // Publish before suspending so callback/Stop callers share one drain.
        analyzerCancellation = cancellation
        await cancellation.value
    }

    private func finishAnalyzerInput() {
        inputBuilder?.finish()
        inputBuilder = nil
    }

    // periphery:ignore - test seam for stop-during-rebuild input lifetime
    func _testInstallAnalyzerInputStream(
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) -> AnalyzerInputBuffer {
        let inputs = makeAnalyzerInputBuffer(now: now)
        inputBuilder = inputs
        return inputs
    }

    // periphery:ignore - exercises the same enqueue boundary as the microphone feed
    func _testEnqueueAnalyzerInput(_ input: AnalyzerInput) -> Bool {
        guard let inputBuilder else { return false }
        return AudioEngineHelper.enqueueCaptureInput(input, into: inputBuilder, events: eventContinuation)
    }

#if DEBUG
    // Replace only Speech's terminal operations; tests retain the real queue,
    // failure callback, Stop/cancel ownership and manager event consumer.
    var _testFinalizeAnalyzer: (@MainActor () async throws -> Void)?
    var _testCancelAnalyzer: (@MainActor () async -> Void)?
    private(set) var _testInputFailureHandled = false
    // Gate callback delivery and the results task independently, without replacing
    // the queue's failure publication or Stop's ownership/join ordering.
    var _testBeforeInputFailure: (@MainActor () async -> Void)?
    enum TestStopPhase { case waitingForResults, finishedResults, cleanedUp }
    private(set) var _testStopPhase: TestStopPhase?

    func _testInstallResultsTask(_ task: Task<Void, Never>) { resultsTask = task }

    // periphery:ignore - a successful analyzer completion must not mask capture failure
    func _testFinishAnalyzerResults() { eventContinuation.finish() }

    // periphery:ignore - inject the converter/allocator, retaining the real session terminal publisher
    func _testMakeLegacyFeed(
        converter: AVAudioConverter,
        allocateBuffer: @escaping (AVAudioFormat, AVAudioFrameCount) -> AVAudioPCMBuffer?
    ) throws -> any AnalyzerInputFeeding {
        guard let inputBuilder else { throw VoiceInputError.audioCaptureUnavailable }
        return AudioEngineHelper.LegacyConverterFeed(
            converter: converter, inputFormat: converter.inputFormat, targetFormat: converter.outputFormat,
            inputBuilder: inputBuilder, events: eventContinuation, allocateBuffer: allocateBuffer
        )
    }
#endif

    private func startResultsBridge() {
        resultsTask?.cancel()
        resultsTask = Task {
            do {
                switch transcriber {
                case .dictation(let module):
                    for try await result in module.results {
                        guard !Task.isCancelled else { break }
                        eventContinuation.yield(
                            result.isFinal
                                ? .appendFinalTranscript(String(result.text.characters))
                                : .partialTranscript(String(result.text.characters))
                        )
                    }
                case .speech(let module):
                    for try await result in module.results {
                        guard !Task.isCancelled else { break }
                        eventContinuation.yield(
                            result.isFinal
                                ? .appendFinalTranscript(String(result.text.characters))
                                : .partialTranscript(String(result.text.characters))
                        )
                    }
                }

                eventContinuation.finish()
            } catch {
                if Task.isCancelled {
                    eventContinuation.finish()
                } else {
                    eventContinuation.finish(throwing: error)
                }
            }
        }
    }

    private func startAudioLevelBridge(_ levelStream: AsyncStream<Float>) {
        audioLevelTask?.cancel()
        audioLevelTask = Task {
            for await level in levelStream {
                guard !Task.isCancelled else { break }
                hasCapturedAudio = true
                audioLevelContinuation.yield(level)
            }
            // A failed capture attempt can end its levels before retry. Only
            // session stop/cancel may finish the public level stream.
        }
    }

    private func cleanupAfterStop() {
#if DEBUG
        _testStopPhase = .cleanedUp
#endif
        analyzer = nil
        inputBuilder = nil
        resultsTask = nil
        audioLevelTask?.cancel()
        audioLevelTask = nil
        audioLevelContinuation.finish()
    }
}
