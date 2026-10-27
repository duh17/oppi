import Foundation

/// Which speech-to-text backend a take uses. Identifies the backend by catalog
/// tag values; never the server host.
struct VoiceProviderTelemetry: Sendable, Equatable {
    var sttProvider: String?
    var sttProviderKind: TelemetryTag.SttProviderKind?
    var sttBackend: String?
    var sttModel: String?
}

/// The AVAudioSession route a take recorded through. Port types only: never
/// Bluetooth names or hardware identifiers.
struct VoiceAudioRouteTelemetry: Sendable, Equatable {
    var category: String?
    var mode: String?
    var inputs: String?
    var outputs: String?
    var sampleRate: Int?
    /// Capture fell back to the built-in microphone after the first engine failed.
    var builtInFallback = false

    init() {}

    /// From `DictationAudioEngineHelper.sessionRouteMetadata()`. Port lists are
    /// joined with `/`: a name tag cannot hold a comma.
    init(routeMetadata: [String: String]) {
        category = routeMetadata["category"]
        mode = routeMetadata["mode"]
        inputs = routeMetadata["input_ports"].flatMap(Self.portList)
        outputs = routeMetadata["output_ports"].flatMap(Self.portList)
        sampleRate = routeMetadata["session_hz"].flatMap(Double.init).map { Int($0.rounded()) }
    }

    /// The route as of `routeMetadata`, keeping the fallback flag: a rebuild
    /// re-reads the route but the take still fell back earlier.
    func refreshed(from routeMetadata: [String: String]) -> Self {
        var route = Self(routeMetadata: routeMetadata)
        route.builtInFallback = builtInFallback
        return route
    }

    private static func portList(_ commaSeparated: String) -> String? {
        let ports = commaSeparated.split(separator: ",").map(String.init)
        return ports.isEmpty ? nil : ports.joined(separator: "/")
    }
}

/// Phase durations of one dictation start, in milliseconds.
struct VoiceSetupTimings: Sendable, Equatable {
    var modelReadyMs = 0
    var transcriberCreateMs = 0
    var analyzerStartMs = 0
    var audioSessionMs = 0
    var audioStartMs = 0
    var totalMs = 0
}

/// Everything one dictation take reports about itself: engine, locale, what
/// started it, and (once setup finishes) the model path, STT backend, and audio
/// route. Each method builds one catalog event with these facts attached, so
/// every event of a take carries the same tags and none is dropped.
struct VoiceTakeTelemetry: Sendable, Equatable {
    let voiceEngine: TelemetryTag.VoiceEngine
    let locale: String
    /// What started the take (`composer_mic`, `quick_session`, …).
    let trigger: String
    var modelPath: TelemetryTag.ModelPath?
    var provider = VoiceProviderTelemetry()
    var route = VoiceAudioRouteTelemetry()

    init(voiceEngine: TelemetryTag.VoiceEngine, locale: String, trigger: String) {
        self.voiceEngine = voiceEngine
        self.locale = locale
        self.trigger = trigger
    }

    func prewarmEvent(
        durationMs: Int,
        status: AppDictationPrewarm.Status,
        errorKind: TelemetryTag.ErrorKind? = nil
    ) -> AppDictationPrewarm {
        AppDictationPrewarm(
            durationMs: Double(max(0, durationMs)),
            voiceEngine: voiceEngine,
            locale: locale,
            trigger: trigger,
            status: status,
            errorKind: errorKind
        )
    }

    /// One event for the whole start. A failed or cancelled start has only its
    /// total; `phases` is the per-phase breakdown of a successful one.
    func setupEvent(
        timings: VoiceSetupTimings,
        includesPhases: Bool,
        status: AppDictationSetup.Status,
        errorKind: TelemetryTag.ErrorKind? = nil
    ) -> AppDictationSetup {
        AppDictationSetup(
            totalMs: Double(max(0, timings.totalMs)),
            modelReadyMs: includesPhases ? Double(max(0, timings.modelReadyMs)) : nil,
            transcriberCreateMs: includesPhases ? Double(max(0, timings.transcriberCreateMs)) : nil,
            analyzerStartMs: includesPhases ? Double(max(0, timings.analyzerStartMs)) : nil,
            audioSessionMs: includesPhases ? Double(max(0, timings.audioSessionMs)) : nil,
            audioStartMs: includesPhases ? Double(max(0, timings.audioStartMs)) : nil,
            audioSampleRate: route.sampleRate,
            voiceEngine: voiceEngine,
            locale: locale,
            trigger: trigger,
            modelPath: modelPath,
            sttProvider: provider.sttProvider,
            sttProviderKind: provider.sttProviderKind,
            sttBackend: provider.sttBackend,
            sttModel: provider.sttModel,
            audioCategory: route.category,
            audioMode: route.mode,
            audioInputs: route.inputs,
            audioOutputs: route.outputs,
            audioRoute: route.builtInFallback ? .builtInFallback : nil,
            status: status,
            errorKind: errorKind
        )
    }

    func firstResultEvent(latencyMs: Int, resultType: String) -> AppDictationFirstResult {
        AppDictationFirstResult(
            durationMs: Double(max(0, latencyMs)),
            voiceEngine: voiceEngine,
            locale: locale,
            trigger: trigger,
            modelPath: modelPath,
            sttProvider: provider.sttProvider,
            sttProviderKind: provider.sttProviderKind,
            sttBackend: provider.sttBackend,
            sttModel: provider.sttModel,
            audioCategory: route.category,
            audioMode: route.mode,
            audioInputs: route.inputs,
            audioOutputs: route.outputs,
            audioRoute: route.builtInFallback ? .builtInFallback : nil,
            resultType: resultType
        )
    }

    func endEvent(
        finalizeMs: Int,
        sessionMs: Int,
        audioDurationMs: Int,
        resultUpdates: Int,
        previewFinalDeltaRatio: Double,
        inputLevelPeakRatio: Double
    ) -> AppDictationEnd {
        AppDictationEnd(
            finalizeMs: Double(max(0, finalizeMs)),
            sessionMs: Double(max(0, sessionMs)),
            audioDurationMs: Double(max(0, audioDurationMs)),
            resultUpdates: max(0, resultUpdates),
            previewFinalDeltaRatio: previewFinalDeltaRatio,
            inputLevelPeakRatio: inputLevelPeakRatio,
            voiceEngine: voiceEngine,
            locale: locale,
            trigger: trigger,
            modelPath: modelPath,
            sttProvider: provider.sttProvider,
            sttProviderKind: provider.sttProviderKind,
            sttBackend: provider.sttBackend,
            sttModel: provider.sttModel,
            audioCategory: route.category,
            audioMode: route.mode,
            audioInputs: route.inputs,
            audioOutputs: route.outputs,
            audioRoute: route.builtInFallback ? .builtInFallback : nil
        )
    }

    func captureErrorEvent(errorKind: TelemetryTag.ErrorKind) -> AppDictationCaptureError {
        AppDictationCaptureError(
            voiceEngine: voiceEngine,
            locale: locale,
            trigger: trigger,
            modelPath: modelPath,
            sttProvider: provider.sttProvider,
            sttProviderKind: provider.sttProviderKind,
            sttBackend: provider.sttBackend,
            sttModel: provider.sttModel,
            audioCategory: route.category,
            audioMode: route.mode,
            audioInputs: route.inputs,
            audioOutputs: route.outputs,
            audioRoute: route.builtInFallback ? .builtInFallback : nil,
            errorKind: errorKind
        )
    }

    func cancelEvent() -> AppDictationCancel {
        AppDictationCancel(
            voiceEngine: voiceEngine,
            locale: locale,
            trigger: trigger,
            modelPath: modelPath,
            sttProvider: provider.sttProvider,
            sttProviderKind: provider.sttProviderKind,
            sttBackend: provider.sttBackend,
            sttModel: provider.sttModel,
            audioCategory: route.category,
            audioMode: route.mode,
            audioInputs: route.inputs,
            audioOutputs: route.outputs,
            audioRoute: route.builtInFallback ? .builtInFallback : nil
        )
    }
}

enum VoiceInputTelemetry {
    static func userFacingMessage(for error: Error) -> String {
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
}
