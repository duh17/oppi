import AVFoundation
import Foundation
import os.log

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "AudioPlayer")

/// Manages audio playback for chat-rendered media.
///
/// Supports:
/// - playback of local audio files
/// - playback of inlined base64 audio blobs from tool output
///
/// Tracks which item is currently playing so the UI can render
/// per-row play/stop/loading state.
@MainActor @Observable
final class AudioPlayerService: NSObject {
    nonisolated static let stateDidChangeNotification = Notification.Name("AudioPlayerService.stateDidChange")
    nonisolated static let previousPlayingItemIDUserInfoKey = "previousPlayingItemID"
    nonisolated static let playingItemIDUserInfoKey = "playingItemID"
    nonisolated static let previousLoadingItemIDUserInfoKey = "previousLoadingItemID"
    nonisolated static let loadingItemIDUserInfoKey = "loadingItemID"

    /// ID of the ChatItem currently playing (nil when idle).
    private(set) var playingItemID: String?

    /// ID of the ChatItem currently loading/decoding audio.
    private(set) var loadingItemID: String?

    private var player: AVAudioPlayer?
    private var playbackDelegate: PlaybackDelegate?

    /// Play a pre-generated local audio clip file.
    func toggleFilePlayback(fileURL: URL, itemID: String) {
        if playingItemID == itemID || loadingItemID == itemID {
            stop()
            return
        }

        stop()
        do {
            try play(fileURL: fileURL, itemID: itemID)
        } catch {
            logger.error("Audio file playback failed: \(error.localizedDescription)")
        }
    }

    /// Play an in-memory base64-decoded audio blob.
    func toggleDataPlayback(data: Data, itemID: String) {
        if playingItemID == itemID || loadingItemID == itemID {
            stop()
            return
        }

        stop()
        do {
            try play(data: data, itemID: itemID)
        } catch {
            logger.error("Audio blob playback failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playbackDelegate = nil
        setPlaybackState(playing: nil, loading: nil)
    }

    // MARK: - Private

    private func play(data: Data, itemID: String) throws {
        // Configure audio session for playback
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playback, mode: .default)
        try audioSession.setActive(true)

        let audioPlayer = try AVAudioPlayer(data: data)
        attachAndStartPlayer(audioPlayer, itemID: itemID)
        logger.info("Playing audio data for item \(itemID), duration: \(audioPlayer.duration, format: .fixed(precision: 1))s")
    }

    private func play(fileURL: URL, itemID: String) throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playback, mode: .default)
        try audioSession.setActive(true)

        let audioPlayer = try AVAudioPlayer(contentsOf: fileURL)
        attachAndStartPlayer(audioPlayer, itemID: itemID)
        logger.info("Playing audio file for item \(itemID): \(fileURL.lastPathComponent, privacy: .public)")
    }

    private func attachAndStartPlayer(_ audioPlayer: AVAudioPlayer, itemID: String) {
        let delegate = PlaybackDelegate { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.player = nil
                self.playbackDelegate = nil
                self.setPlaybackState(playing: nil, loading: nil)
            }
        }
        audioPlayer.delegate = delegate

        self.player = audioPlayer
        self.playbackDelegate = delegate
        setPlaybackState(playing: itemID, loading: nil)

        audioPlayer.play()
    }

    private func setPlaybackState(playing: String?, loading: String?) {
        let previousPlaying = playingItemID
        let previousLoading = loadingItemID
        guard previousPlaying != playing || previousLoading != loading else {
            return
        }

        playingItemID = playing
        loadingItemID = loading

        NotificationCenter.default.post(
            name: Self.stateDidChangeNotification,
            object: self,
            userInfo: [
                Self.previousPlayingItemIDUserInfoKey: previousPlaying ?? "",
                Self.playingItemIDUserInfoKey: playing ?? "",
                Self.previousLoadingItemIDUserInfoKey: previousLoading ?? "",
                Self.loadingItemIDUserInfoKey: loading ?? "",
            ]
        )
    }
}

// MARK: - Delegate

private final class PlaybackDelegate: NSObject, AVAudioPlayerDelegate, Sendable {
    private let onFinish: @Sendable () -> Void

    init(onFinish: @escaping @Sendable () -> Void) {
        self.onFinish = onFinish
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        onFinish()
    }
}
