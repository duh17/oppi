@preconcurrency import AVFoundation
import Foundation

/// Stable identifiers for pluggable voice transcription backends.
enum VoiceProviderID: String, Sendable {
    case appleModernSpeech
    case appleClassicDictation
    case oppiServer
}

@MainActor
struct VoiceProviderContext {
    let locale: Locale
    let source: String
    let serverCredentials: ServerCredentials?
    let serverConnection: ServerConnection?
    /// Selected dictionary hints frozen for this take (not a promise of application).
    let contextualStrings: [String]

    init(
        locale: Locale,
        source: String,
        serverCredentials: ServerCredentials? = nil,
        serverConnection: ServerConnection? = nil,
        contextualStrings: [String] = []
    ) {
        self.locale = locale
        self.source = source
        self.serverCredentials = serverCredentials
        self.serverConnection = serverConnection
        self.contextualStrings = contextualStrings
    }
}

/// Cached preparation output used to create a recording session quickly.
struct VoiceProviderPreparation {
    let audioFormat: AVAudioFormat?
    /// Concrete locale selected by a provider after matching the requested locale
    /// against its supported model inventory.
    let transcriptionLocale: Locale?
    /// How the model or stream was obtained, for telemetry.
    let modelPath: TelemetryTag.ModelPath
    /// The STT backend, as far as it is known before the session is ready.
    let provider: VoiceProviderTelemetry

    init(
        audioFormat: AVAudioFormat?,
        transcriptionLocale: Locale? = nil,
        modelPath: TelemetryTag.ModelPath,
        provider: VoiceProviderTelemetry = VoiceProviderTelemetry()
    ) {
        self.audioFormat = audioFormat
        self.transcriptionLocale = transcriptionLocale
        self.modelPath = modelPath
        self.provider = provider
    }
}

/// Timing breakdown reported by provider-owned recording sessions.
struct VoiceSessionStartTimings: Sendable {
    let analyzerStartMs: Int
    let audioStartMs: Int
}

/// Provider-agnostic session events streamed back to the manager.
enum VoiceSessionEvent: Sendable {
    case partialTranscript(String)
    case appendFinalTranscript(String)
    case replaceFinalTranscript(
        String,
        snap: Bool = false,
        committedText: String? = nil,
        activeText: String? = nil
    )
    /// The STT backend and model the server resolved after async readiness;
    /// unknown at setup time, so later events of the take carry the real values.
    case sttResolved(backend: String, model: String)
}

@MainActor
protocol VoiceTranscriptionSession: AnyObject {
    var events: AsyncThrowingStream<VoiceSessionEvent, Error> { get }
    var audioLevels: AsyncStream<VoiceSpectrumFrame> { get }

    func start() async throws -> VoiceSessionStartTimings
    /// Rebuild the microphone graph onto the current route without finishing
    /// the transcription session. Used when Bluetooth/built-in handoff kills the engine.
    func rebuildAudioCapture() async throws
    func stop() async
    func cancel() async
}

@MainActor
protocol VoiceTranscriptionProvider: AnyObject {
    // periphery:ignore - protocol requirement; used by VoiceProviderRegistryTests via @testable import
    var id: VoiceProviderID { get }
    var engine: VoiceInputManager.TranscriptionEngine { get }

    func invalidateCache()
    func cancelPreparation()
    func prewarm(context: VoiceProviderContext) async throws
    func prepareSession(context: VoiceProviderContext) async throws -> VoiceProviderPreparation
    func makeSession(
        context: VoiceProviderContext,
        preparation: VoiceProviderPreparation
    ) throws -> any VoiceTranscriptionSession
}

@MainActor
struct VoiceProviderRegistry {
    private let providersByEngine: [VoiceInputManager.TranscriptionEngine: any VoiceTranscriptionProvider]

    init(providers: [any VoiceTranscriptionProvider]) {
        var byEngine: [VoiceInputManager.TranscriptionEngine: any VoiceTranscriptionProvider] = [:]
        for provider in providers {
            byEngine[provider.engine] = provider
        }
        providersByEngine = byEngine
    }

    static func makeDefault() -> Self {
        Self(
            providers: [
                AppleOnDeviceVoiceProvider(engine: .modernSpeech),
                AppleOnDeviceVoiceProvider(engine: .classicDictation),
                OppiDictationProvider(),
            ]
        )
    }

    func provider(
        for engine: VoiceInputManager.TranscriptionEngine
    ) -> (any VoiceTranscriptionProvider)? {
        providersByEngine[engine]
    }
}
