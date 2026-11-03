import Foundation

/// Header-derived audio metadata: `GET /files/current/media-info`.
///
/// Mirrors `MediaInfo` in `server/src/types/workspace-files.ts`. Every field is
/// optional and absent means unknown, so a server that reads fewer structures
/// answers a subset a newer client can show, and an older client ignores keys it
/// does not read.
struct MediaInfo: Codable, Sendable, Equatable {
    /// The audio format read from the container headers.
    struct Format: Codable, Sendable, Equatable {
        /// Codec family: `mp3`, `aac`, `flac`, `pcm`, `alac`, `opus`, ….
        let codec: String
        /// Samples per second, when the container states a plausible rate.
        let sampleRate: Int?
        let channels: Int?
        /// Bits per second.
        let bitrate: Int?
    }

    /// Tags the container states; a malformed tag section reports none.
    struct Tags: Codable, Sendable, Equatable {
        let title: String?
        let artist: String?
        let album: String?
    }

    /// Length in seconds, when the headers describe a plausible one.
    let durationSeconds: Double?
    let format: Format?
    let tags: Tags?
}
