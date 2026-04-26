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

    /// When enabled, live/automatic streamed speech is suppressed.
    /// Manual replay from an audio card still works after the user taps play.
    var autoPlaybackMuted: Bool {
        didSet {
            UserDefaults.standard.set(autoPlaybackMuted, forKey: Self.autoPlaybackMutedDefaultsKey)
            if autoPlaybackMuted {
                stopAudioStream(clearState: true)
            }
            postPlaybackPolicyChanged()
        }
    }

    var hasActivePlayback: Bool {
        playingItemID != nil || loadingItemID != nil || streamID != nil
    }

    private static let autoPlaybackMutedDefaultsKey = "AudioPlayerService.autoPlaybackMuted"

    private var player: AVAudioPlayer?
    private var playbackDelegate: PlaybackDelegate?
    private var streamEngine: AVAudioEngine?
    private var streamNode: AVAudioPlayerNode?
    private var streamFormat: AVAudioFormat?
    private var streamID: String?
    private var suppressedAudioStreamIDs: Set<String> = []
    private var streamPendingBuffers = 0
    private var streamReceivedDone = false

    override init() {
        if let stored = UserDefaults.standard.object(forKey: Self.autoPlaybackMutedDefaultsKey) as? Bool {
            self.autoPlaybackMuted = stored
        } else {
            self.autoPlaybackMuted = true
        }
        super.init()
    }

    func toggleAutoPlaybackMuted() {
        autoPlaybackMuted.toggle()
    }

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
        let activeStreamID = streamID
        player?.stop()
        player = nil
        playbackDelegate = nil
        stopAudioStream(clearState: false)
        if let activeStreamID {
            suppressedAudioStreamIDs.insert(activeStreamID)
        }
        setPlaybackState(playing: nil, loading: nil)
    }

    /// Consume low-latency audio chunks emitted by Oppi/Pi extensions.
    ///
    /// Supports 16-bit little-endian PCM (`audio/pcm; codecs=s16le`) for true
    /// streaming playback. WAV stream chunks are ignored here; completed WAVs
    /// should be rendered through normal tool-result audio attachments.
    func handleAudioStream(_ stream: AudioStreamMessage) {
        if suppressedAudioStreamIDs.contains(stream.id) {
            if stream.event == .done || stream.event == .error {
                suppressedAudioStreamIDs.remove(stream.id)
            }
            return
        }

        if autoPlaybackMuted {
            if stream.event == .error {
                logger.error("Muted audio stream \(stream.id, privacy: .public) reported error: \(stream.text ?? "unknown", privacy: .public)")
            }
            return
        }

        if stream.mimeType == "audio/wav" {
            handleWAVAudioStream(stream)
            return
        }

        guard stream.mimeType == "audio/pcm; codecs=s16le" else {
            if stream.event == .error { logger.error("Audio stream \(stream.id, privacy: .public) failed: \(stream.text ?? "unknown", privacy: .public)") }
            return
        }

        switch stream.event {
        case .metadata:
            startAudioStream(
                id: stream.id,
                sampleRate: Double(stream.sampleRate ?? 24_000),
                channels: AVAudioChannelCount(stream.channels ?? 1)
            )
        case .chunk:
            appendAudioStreamChunk(stream)
        case .done:
            guard stream.id == streamID else { return }
            streamReceivedDone = true
            finishAudioStreamIfDrained(id: stream.id)
        case .error:
            logger.error("Audio stream \(stream.id, privacy: .public) failed: \(stream.text ?? "unknown", privacy: .public)")
            stopAudioStream(clearState: true)
        }
    }

    // MARK: - Private

    private func play(data: Data, itemID: String) throws {
        stopAudioStream(clearState: false)
        // Configure audio session for playback
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playback, mode: .default)
        try audioSession.setActive(true)

        let audioPlayer = try AVAudioPlayer(data: data)
        attachAndStartPlayer(audioPlayer, itemID: itemID)
        logger.info("Playing audio data for item \(itemID), duration: \(audioPlayer.duration, format: .fixed(precision: 1))s")
    }

    private func play(fileURL: URL, itemID: String) throws {
        stopAudioStream(clearState: false)
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

    private func handleWAVAudioStream(_ stream: AudioStreamMessage) {
        switch stream.event {
        case .chunk, .done:
            guard let base64 = stream.audioBase64,
                  let data = Data(base64Encoded: base64),
                  !data.isEmpty,
                  data.count <= 10 * 1024 * 1024 else {
                return
            }
            toggleDataPlayback(data: data, itemID: "audio-stream-\(stream.id)")
        case .error:
            logger.error("Audio stream \(stream.id, privacy: .public) failed: \(stream.text ?? "unknown", privacy: .public)")
            stopAudioStream(clearState: true)
        case .metadata:
            break
        }
    }

    private func startAudioStream(id: String, sampleRate: Double, channels: AVAudioChannelCount) {
        guard (8_000...48_000).contains(sampleRate), channels == 1 || channels == 2 else {
            logger.error("Ignoring invalid audio stream format: \(sampleRate)Hz \(channels)ch")
            return
        }

        stop()

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default)
            try audioSession.setActive(true)

            let engine = AVAudioEngine()
            let node = AVAudioPlayerNode()
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels) else {
                logger.error("Failed to create audio stream format")
                return
            }

            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            try engine.start()
            node.play()

            streamEngine = engine
            streamNode = node
            streamFormat = format
            streamID = id
            streamPendingBuffers = 0
            streamReceivedDone = false
            setPlaybackState(playing: "audio-stream-\(id)", loading: nil)
        } catch {
            logger.error("Audio stream start failed: \(error.localizedDescription)")
            stopAudioStream(clearState: true)
        }
    }

    private func appendAudioStreamChunk(_ stream: AudioStreamMessage) {
        if streamID != stream.id {
            startAudioStream(
                id: stream.id,
                sampleRate: Double(stream.sampleRate ?? 24_000),
                channels: AVAudioChannelCount(stream.channels ?? 1)
            )
        }

        guard let node = streamNode,
              let format = streamFormat,
              let base64 = stream.audioBase64,
              let data = Data(base64Encoded: base64),
              !data.isEmpty else {
            return
        }

        guard data.count <= 384 * 1024 else {
            logger.error("Ignoring oversized audio stream chunk: \(data.count) bytes")
            return
        }

        guard let buffer = pcm16LEBuffer(data: data, format: format) else {
            logger.error("Failed to decode audio stream PCM chunk")
            return
        }

        streamPendingBuffers += 1
        node.scheduleBuffer(buffer) { [weak self, id = stream.id] in
            Task { @MainActor in
                guard let self, self.streamID == id else { return }
                self.streamPendingBuffers = max(0, self.streamPendingBuffers - 1)
                self.finishAudioStreamIfDrained(id: id)
            }
        }
        if !node.isPlaying { node.play() }
    }

    private func pcm16LEBuffer(data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let channels = Int(format.channelCount)
        guard channels > 0, data.count >= channels * 2 else { return nil }
        let frameCount = data.count / (channels * 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let floatChannels = buffer.floatChannelData else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        data.withUnsafeBytes { rawBuffer in
            guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            for frame in 0..<frameCount {
                for channel in 0..<channels {
                    let byteOffset = (frame * channels + channel) * 2
                    let sample = Int16(bitPattern: UInt16(bytes[byteOffset]) | (UInt16(bytes[byteOffset + 1]) << 8))
                    floatChannels[channel][frame] = max(-1, Float(sample) / 32768.0)
                }
            }
        }
        return buffer
    }

    private func finishAudioStreamIfDrained(id: String) {
        guard streamID == id, streamReceivedDone, streamPendingBuffers == 0 else { return }
        stopAudioStream(clearState: true)
    }

    private func stopAudioStream(clearState: Bool) {
        streamNode?.stop()
        streamEngine?.stop()
        streamEngine = nil
        streamNode = nil
        streamFormat = nil
        streamID = nil
        streamPendingBuffers = 0
        streamReceivedDone = false
        if clearState {
            setPlaybackState(playing: nil, loading: nil)
        }
    }

    private func postPlaybackPolicyChanged() {
        NotificationCenter.default.post(
            name: Self.stateDidChangeNotification,
            object: self,
            userInfo: [
                Self.previousPlayingItemIDUserInfoKey: playingItemID ?? "",
                Self.playingItemIDUserInfoKey: playingItemID ?? "",
                Self.previousLoadingItemIDUserInfoKey: loadingItemID ?? "",
                Self.loadingItemIDUserInfoKey: loadingItemID ?? "",
            ]
        )
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
