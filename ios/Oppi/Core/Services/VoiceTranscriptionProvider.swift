@preconcurrency import AVFoundation
import Foundation

/// Stable identifiers for pluggable voice transcription backends.
enum VoiceProviderID: String, Sendable {
    case appleModernSpeech
    case appleClassicDictation
    case remoteASR
}

struct VoiceProviderContext: Sendable {
    let locale: Locale
    let source: String
    let remoteEndpoint: URL?
}

/// Cached preparation output used to create a recording session quickly.
struct VoiceProviderPreparation {
    let audioFormat: AVAudioFormat?
    let pathTag: String
    let setupMetricTags: [String: String]
}

/// Timing breakdown reported by provider-owned recording sessions.
struct VoiceSessionStartTimings: Sendable {
    let analyzerStartMs: Int
    let audioStartMs: Int
}

enum VoiceRemoteChunkStatus: String, Sendable {
    case success
    case empty
    case skipped
    case cancelled
    case error
}

struct VoiceRemoteChunkTelemetry: Sendable {
    let status: VoiceRemoteChunkStatus
    let isFinal: Bool
    let sampleCount: Int
    let audioDurationMs: Int
    let wavBytes: Int
    let uploadDurationMs: Int?
    let textLength: Int?
    let errorCategory: String?
    let tags: [String: String]
}

/// Provider-agnostic session events streamed back to the manager.
enum VoiceSessionEvent: Sendable {
    case partialTranscript(String)
    case appendFinalTranscript(String)
    case replaceFinalTranscript(String)
    case remoteChunkTelemetry(VoiceRemoteChunkTelemetry)
}

@MainActor
protocol VoiceTranscriptionSession: AnyObject {
    var events: AsyncThrowingStream<VoiceSessionEvent, Error> { get }
    var audioLevels: AsyncStream<Float> { get }

    func start() async throws -> VoiceSessionStartTimings
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
                RemoteASRVoiceProvider(),
            ]
        )
    }

    func provider(
        for engine: VoiceInputManager.TranscriptionEngine
    ) -> (any VoiceTranscriptionProvider)? {
        providersByEngine[engine]
    }
}
