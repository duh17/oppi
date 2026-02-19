import Foundation

/// Configuration for the dictation (speech-to-text) backend.
///
/// Supports any OpenAI-compatible `/v1/audio/transcriptions` endpoint:
/// - Local MLX Server (Qwen3-ASR, Whisper, etc.)
/// - OpenAI Whisper API
/// - Any compatible third-party STT service
///
/// Persisted in UserDefaults under `dev.chenda.Oppi.dictation.*` keys.
struct DictationConfig: Codable, Equatable, Sendable {

    /// Whether dictation is enabled (shows mic button in composer).
    var enabled: Bool

    /// Base URL of the STT server (e.g. `http://mac-studio:8321`).
    /// Must expose `POST /v1/audio/transcriptions`.
    var endpointURL: String

    /// Model identifier sent in the `model` form field.
    /// Examples: `mlx-community/Qwen3-ASR-1.7B-bf16`, `whisper-1`
    var model: String

    /// Optional language hint (BCP-47 or model-specific, e.g. `en`, `zh`).
    /// Empty string means auto-detect.
    var language: String

    /// Optional bearer token for authenticated endpoints.
    /// Sent as `Authorization: Bearer <token>` if non-empty.
    var apiKey: String

    /// Audio chunk duration in seconds before shipping to the server.
    /// Shorter = more responsive, longer = more context per request.
    /// Range: 1.0–10.0. Default: 2.5.
    var chunkDurationSeconds: Double

    /// Silence detection threshold (seconds of silence before auto-stop).
    /// Range: 1.0–10.0. Default: 3.0.
    var silenceTimeoutSeconds: Double

    // MARK: - Defaults

    static let `default` = Self(
        enabled: false,
        endpointURL: "",
        model: "default",
        language: "",
        apiKey: "",
        chunkDurationSeconds: 2.5,
        silenceTimeoutSeconds: 3.0
    )

    // MARK: - UserDefaults Persistence

    private static let storageKey = "\(AppIdentifiers.subsystem).dictation.config"

    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let config = try? JSONDecoder().decode(Self.self, from: data)
        else {
            return .default
        }
        return config
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    /// Whether the config has a valid endpoint URL.
    var hasValidEndpoint: Bool {
        guard let url = URL(string: endpointURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else {
            return false
        }
        return true
    }

    /// Full transcription endpoint URL.
    var transcriptionURL: URL? {
        guard hasValidEndpoint else { return nil }
        let base = endpointURL.hasSuffix("/") ? String(endpointURL.dropLast()) : endpointURL
        return URL(string: "\(base)/v1/audio/transcriptions")
    }

    /// Clamped chunk duration.
    var effectiveChunkDuration: Double {
        min(10.0, max(1.0, chunkDurationSeconds))
    }

    /// Clamped silence timeout.
    var effectiveSilenceTimeout: Double {
        min(10.0, max(1.0, silenceTimeoutSeconds))
    }
}
