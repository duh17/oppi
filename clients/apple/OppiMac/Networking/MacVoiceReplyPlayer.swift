import AVFoundation
import Foundation
import OSLog

private let macVoiceReplyLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "OppiMac",
    category: "MacVoiceReply"
)

/// Plays live autoplay voice replies on Mac without a UIKit audio service.
///
/// Live WAV chunks use `AVAudioPlayer`. Completed attachment cards stay
/// tap-to-play on `MacAuthenticatedAVPlayerView` (iOS `suppressAutoplay`).
/// Live PCM (`audio/pcm; codecs=s16le`) is not played here; that needs an
/// `AVAudioEngine` streamer the Mac app does not have.
@MainActor
final class MacVoiceReplyPlayer {
    private var wavPlayer: AVAudioPlayer?

    func handleAudioStream(_ stream: AudioStreamMessage, sessionId: String) {
        guard AppPreferenceStore.Voice.shouldAutoplay(
            playbackBehavior: stream.playbackBehavior,
            sessionId: sessionId
        ) else {
            return
        }

        if stream.mimeType == "audio/wav" {
            playWAVIfPresent(stream, sessionId: sessionId)
            return
        }
    }

    static func wavDataForPlayback(
        from stream: AudioStreamMessage,
        sessionId: String
    ) -> Data? {
        guard AppPreferenceStore.Voice.shouldAutoplay(
            playbackBehavior: stream.playbackBehavior,
            sessionId: sessionId
        ) else {
            return nil
        }
        guard stream.mimeType == "audio/wav" else { return nil }
        switch stream.event {
        case .chunk, .done:
            guard let base64 = stream.audioBase64,
                  let data = Data(base64Encoded: base64),
                  !data.isEmpty,
                  data.count <= 10 * 1024 * 1024
            else {
                return nil
            }
            return data
        case .metadata, .error:
            return nil
        }
    }

    private func playWAVIfPresent(_ stream: AudioStreamMessage, sessionId: String) {
        switch stream.event {
        case .chunk, .done:
            guard let data = Self.wavDataForPlayback(from: stream, sessionId: sessionId) else { return }
            playWAV(data)
        case .error:
            macVoiceReplyLogger.error(
                "Voice reply stream \(stream.id, privacy: .public) failed: \(stream.text ?? "unknown", privacy: .public)"
            )
            stop()
        case .metadata:
            break
        }
    }

    private func playWAV(_ data: Data) {
        stop()
        do {
            let player = try AVAudioPlayer(data: data)
            wavPlayer = player
            player.play()
        } catch {
            macVoiceReplyLogger.error(
                "Voice reply WAV playback failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func stop() {
        wavPlayer?.stop()
        wavPlayer = nil
    }
}
