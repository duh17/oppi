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
    private var prewarmTask: Task<AVAudioFormat?, Error>?
    private var prewarmModelKey: String?

    init(engine: VoiceInputManager.TranscriptionEngine) {
        self.engine = engine
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
        prewarmTask?.cancel()
        prewarmTask = nil
        prewarmModelKey = nil
    }

    func cancelPreparation() {
        prewarmTask?.cancel()
        prewarmTask = nil
        prewarmModelKey = nil
    }

    func prewarm(context: VoiceProviderContext) async throws {
        let locale = try await Self.resolvedLocale(for: engine, requestedLocale: context.locale)
        let key = Self.modelKey(engine: engine, localeID: locale.identifier(.bcp47))

        if modelReady, cachedModelKey == nil || cachedModelKey == key {
            return
        }

        if let inflight = prewarmTask {
            if prewarmModelKey == key {
                return
            }
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
        } catch {
            if prewarmModelKey == key {
                prewarmTask = nil
                prewarmModelKey = nil
            }
            throw error
        }

        if prewarmModelKey == key {
            prewarmTask = nil
            prewarmModelKey = nil
        }
    }

    func prepareSession(context: VoiceProviderContext) async throws -> VoiceProviderPreparation {
        let locale = try await Self.resolvedLocale(for: engine, requestedLocale: context.locale)
        let key = Self.modelKey(engine: engine, localeID: locale.identifier(.bcp47))

        if let inflight = prewarmTask {
            if prewarmModelKey == key {
                let format = try await inflight.value
                cachedFormat = format
                cachedModelKey = key
                modelReady = true
                prewarmTask = nil
                prewarmModelKey = nil
                return VoiceProviderPreparation(
                    audioFormat: format,
                    transcriptionLocale: locale,
                    pathTag: "join_prewarm",
                    setupMetricTags: Self.metricTags(for: engine, locale: locale)
                )
            }

            inflight.cancel()
            prewarmTask = nil
            prewarmModelKey = nil
        }

        if modelReady, cachedModelKey == nil || cachedModelKey == key {
            return VoiceProviderPreparation(
                audioFormat: cachedFormat,
                transcriptionLocale: locale,
                pathTag: "warm_cache",
                setupMetricTags: Self.metricTags(for: engine, locale: locale)
            )
        }

        let task = Task {
            try await Self.warmModel(engine: engine, locale: locale)
        }
        prewarmTask = task
        prewarmModelKey = key

        do {
            let format = try await task.value
            guard prewarmModelKey == key else {
                throw CancellationError()
            }
            cachedFormat = format
            cachedModelKey = key
            modelReady = true
            prewarmTask = nil
            prewarmModelKey = nil
            return VoiceProviderPreparation(
                audioFormat: format,
                transcriptionLocale: locale,
                pathTag: "cold",
                setupMetricTags: Self.metricTags(for: engine, locale: locale)
            )
        } catch {
            if prewarmModelKey == key {
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
            preferredAudioFormat: preparation.audioFormat
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

private enum TranscriberModule {
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
private final class AppleOnDeviceVoiceSession: VoiceTranscriptionSession {
    let events: AsyncThrowingStream<VoiceSessionEvent, Error>
    let audioLevels: AsyncStream<Float>

    private let transcriber: TranscriberModule
    private let preferredAudioFormat: AVAudioFormat?
    private let eventContinuation: AsyncThrowingStream<VoiceSessionEvent, Error>.Continuation
    private let audioLevelContinuation: AsyncStream<Float>.Continuation

    private var analyzer: SpeechAnalyzer?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var audioEngine: AVAudioEngine?
    private var resultsTask: Task<Void, Never>?
    private var audioLevelTask: Task<Void, Never>?

    init(
        transcriber: TranscriberModule,
        preferredAudioFormat: AVAudioFormat?
    ) {
        self.transcriber = transcriber
        self.preferredAudioFormat = preferredAudioFormat

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
        let newAnalyzer = SpeechAnalyzer(modules: [transcriber.speechModule])
        analyzer = newAnalyzer

        let (sequence, builder) = AsyncStream.makeStream(of: AnalyzerInput.self)
        inputBuilder = builder
        try await newAnalyzer.prepareToAnalyze(in: preferredAudioFormat)
        try await newAnalyzer.start(inputSequence: sequence)
        startResultsBridge()
        let analyzerStartMs = analyzerStart.elapsedMs()

        let audioStart = ContinuousClock.now
        guard let inputBuilder else {
            throw VoiceInputError.internalError("Input builder not initialized")
        }
        let (engine, levelStream) = try AudioEngineHelper.startEngine(
            inputBuilder: inputBuilder,
            targetFormat: preferredAudioFormat
        )
        audioEngine = engine
        startAudioLevelBridge(levelStream)
        let audioStartMs = audioStart.elapsedMs()

        return VoiceSessionStartTimings(
            analyzerStartMs: analyzerStartMs,
            audioStartMs: audioStartMs
        )
    }

    func stop() async {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        inputBuilder?.finish()

        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            appleVoiceProviderLogger.error("Error finalizing on-device session: \(error.localizedDescription)")
        }

        await resultsTask?.value
        cleanupAfterStop()
    }

    func cancel() async {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        inputBuilder?.finish()

        resultsTask?.cancel()
        resultsTask = nil
        audioLevelTask?.cancel()
        audioLevelTask = nil
        await analyzer?.cancelAndFinishNow()

        analyzer = nil
        inputBuilder = nil
        eventContinuation.finish()
        audioLevelContinuation.finish()
    }

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
                audioLevelContinuation.yield(level)
            }
            audioLevelContinuation.finish()
        }
    }

    private func cleanupAfterStop() {
        analyzer = nil
        inputBuilder = nil
        resultsTask = nil
        audioLevelTask?.cancel()
        audioLevelTask = nil
        audioLevelContinuation.finish()
    }


}
