import AVFoundation
import CoreMedia
import Foundation
import MediaPlayer
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
final class AudioPlayerService: NSObject, VoicePlaybackInterrupter, VoicePlaybackCaptureCoordinating {
    nonisolated static let stateDidChangeNotification = Notification.Name("AudioPlayerService.stateDidChange")
    nonisolated static let previousPlayingItemIDUserInfoKey = "previousPlayingItemID"
    nonisolated static let playingItemIDUserInfoKey = "playingItemID"
    nonisolated static let previousLoadingItemIDUserInfoKey = "previousLoadingItemID"
    nonisolated static let loadingItemIDUserInfoKey = "loadingItemID"

    private static var activePlaybackOwner: AudioPlayerService?
    private static var remoteCommandTargetsInstalled = false
    struct SessionContext: Equatable {
        let sessionID: String
        let sessionTitle: String
        let modelID: String?

        var provider: String? {
            Self.provider(from: modelID)
        }

        var modelTitle: String? {
            Self.shortModelName(from: modelID)
        }

        private static func provider(from modelID: String?) -> String? {
            guard let modelID,
                  let slashIndex = modelID.firstIndex(of: "/") else {
                return nil
            }
            let provider = String(modelID[..<slashIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            return provider.isEmpty ? nil : provider
        }

        private static func shortModelName(from modelID: String?) -> String? {
            guard let modelID else { return nil }
            let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let name = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
            return name
                .replacingOccurrences(of: "claude-", with: "")
                .replacingOccurrences(of: "gemini-", with: "")
        }
    }

    struct NowPlayingPresentation: Equatable {
        let sessionID: String
        let title: String
        let subtitle: String
        let provider: String?
    }

    private static let nowPlayingFallbackTitle = "Voice reply"
    private static let nowPlayingFallbackArtist = "Oppi"

    /// ID of the ChatItem currently playing (nil when idle).
    private(set) var playingItemID: String?

    /// ID of the ChatItem currently loading/decoding audio.
    private(set) var loadingItemID: String?

    /// Elapsed playback time for the active item.
    private(set) var currentTime: TimeInterval = 0

    /// Known duration for the active item. Nil for live streams.
    private(set) var duration: TimeInterval?

    /// True when the active item is paused rather than stopped.
    private(set) var isPaused = false

    var hasActivePlayback: Bool {
        playingItemID != nil || loadingItemID != nil || streamID != nil
    }

    /// Session whose current PCM stream still depends on live focused-session delivery.
    /// Buffered/local playback stays active after this becomes nil.
    var activeLiveTransportSessionID: String? {
        guard streamID != nil, !streamReceivedDone else { return nil }
        return streamSessionID ?? activePlaybackContext?.sessionID
    }

    var hasActiveLiveTransportPlayback: Bool {
        activeLiveTransportSessionID != nil
    }

    private var player: AVAudioPlayer?
    private var mediaPlaybackSession: AuthenticatedMediaPlaybackSession?
    private var mediaStatusObservation: NSKeyValueObservation?
    private var mediaEndObserver: NSObjectProtocol?
    private var sessionContext: SessionContext?
    private var activePlaybackContext: SessionContext?
    private var lastNowPlayingDurationSeconds: Double?
    private var lastNowPlayingIsLiveStream = false
    private var playbackDelegate: PlaybackDelegate?
    private var streamEngine: AVAudioEngine?
    private var streamNode: AVAudioPlayerNode?
    private var streamFormat: AVAudioFormat?
    private var streamID: String?
    private var streamSessionID: String?
    private var suppressedAudioStreamIDs: Set<String> = []
    private var autoPlayedVoiceReplyItemIDs: Set<String> = []
    private var playbackSuppressedForCapture = false
    private var streamPendingBuffers = 0
    private var streamReceivedDone = false
    private var progressTimer: Timer?
    private var mediaTimeObserver: Any?

    override init() {
        super.init()
    }

    var nowPlayingPresentation: NowPlayingPresentation? {
        guard hasActivePlayback else { return nil }
        let context = activePlaybackContext ?? sessionContext
        let title = context?.sessionTitle ?? Self.nowPlayingFallbackTitle
        let subtitle = context?.modelTitle
            ?? "Session \((context?.sessionID.prefix(8)).map(String.init) ?? "")"
        return NowPlayingPresentation(
            sessionID: context?.sessionID ?? "",
            title: title,
            subtitle: subtitle.isEmpty ? Self.nowPlayingFallbackArtist : subtitle,
            provider: context?.provider
        )
    }

    func setSessionContext(_ session: Session?) {
        let updatedContext = session.map {
            SessionContext(
                sessionID: $0.id,
                sessionTitle: $0.displayTitle,
                modelID: $0.model
            )
        }
        sessionContext = updatedContext
        if let updatedContext,
           activePlaybackContext?.sessionID == updatedContext.sessionID {
            activePlaybackContext = updatedContext
        }
        guard hasActivePlayback else { return }
        updateNowPlayingInfo(
            durationSeconds: lastNowPlayingDurationSeconds,
            isLiveStream: lastNowPlayingIsLiveStream
        )
    }

    /// Play a pre-generated local audio clip file.
    func toggleFilePlayback(fileURL: URL, itemID: String, mode: String = "manual") {
        if playingItemID == itemID || loadingItemID == itemID {
            stop()
            return
        }

        let startedAtMs = ChatSessionTelemetry.nowMs()
        stop()
        do {
            try play(fileURL: fileURL, itemID: itemID, mode: mode, startedAtMs: startedAtMs)
        } catch {
            recordVoicePlaybackError(source: "file", phase: "start", error: error)
            logger.error("Audio file playback failed: \(error.localizedDescription)")
        }
    }

    /// Play an in-memory base64-decoded audio blob.
    func toggleDataPlayback(data: Data, itemID: String, mode: String = "manual") {
        if playingItemID == itemID || loadingItemID == itemID {
            stop()
            return
        }

        let startedAtMs = ChatSessionTelemetry.nowMs()
        stop()
        do {
            try play(data: data, itemID: itemID, mode: mode, startedAtMs: startedAtMs)
        } catch {
            recordVoicePlaybackError(source: "data", phase: "start", error: error)
            logger.error("Audio blob playback failed: \(error.localizedDescription)")
        }
    }

    /// Stream a bearer-authenticated media attachment through AVFoundation.
    func toggleMediaPlayback(source: AuthenticatedMediaSource, itemID: String, mode: String = "manual") {
        if playingItemID == itemID || loadingItemID == itemID {
            stop()
            return
        }

        let startedAtMs = ChatSessionTelemetry.nowMs()
        stop()
        do {
            try play(source: source, itemID: itemID, mode: mode, startedAtMs: startedAtMs)
        } catch {
            recordVoicePlaybackError(source: "media", phase: "start", error: error)
            logger.error("Audio media playback failed: \(error.localizedDescription)")
        }
    }

    func beginCaptureInterruption() {
        playbackSuppressedForCapture = true
        stop()
    }

    func endCaptureInterruption() {
        playbackSuppressedForCapture = false
    }

    func stop() {
        let activeStreamID = streamID
        player?.stop()
        player = nil
        playbackDelegate = nil
        stopProgressUpdates()
        currentTime = 0
        duration = nil
        isPaused = false
        stopMediaPlaybackSession()
        stopAudioStream(clearState: false)
        if let activeStreamID {
            suppressedAudioStreamIDs.insert(activeStreamID)
        }
        deactivatePlaybackAudioSessionIfPossible()
        setPlaybackState(playing: nil, loading: nil)
        clearGlobalPlaybackOwnershipIfNeeded()
    }

    func pause() {
        guard playingItemID != nil, !isPaused else { return }
        player?.pause()
        mediaPlaybackSession?.player.pause()
        streamNode?.pause()
        isPaused = true
        stopProgressUpdates()
        publishProgress()
        updateNowPlayingInfo(
            durationSeconds: duration ?? lastNowPlayingDurationSeconds,
            isLiveStream: lastNowPlayingIsLiveStream,
            playbackRate: 0
        )
    }

    func resume() {
        guard playingItemID != nil, isPaused else { return }
        player?.play()
        mediaPlaybackSession?.player.play()
        streamNode?.play()
        isPaused = false
        startProgressUpdates()
        publishProgress()
        updateNowPlayingInfo(
            durationSeconds: duration ?? lastNowPlayingDurationSeconds,
            isLiveStream: lastNowPlayingIsLiveStream
        )
    }

    func seek(to time: TimeInterval) {
        guard playingItemID != nil, time.isFinite, time >= 0 else { return }
        if let player {
            player.currentTime = min(time, player.duration)
        }
        if let mediaPlayer = mediaPlaybackSession?.player {
            let duration = mediaPlayer.currentItem?.duration.seconds
            let clamped = duration?.isFinite == true ? min(time, duration ?? time) : time
            mediaPlayer.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
        }
        currentTime = time
        publishProgress()
    }

    func shouldAutoplayAudioMessage(itemID: String, playbackBehavior: AudioPlaybackBehavior?, sessionId: String? = nil) -> Bool {
        !playbackSuppressedForCapture
            && AppPreferences.Voice.shouldAutoplay(playbackBehavior: playbackBehavior, sessionId: sessionId)
            && !autoPlayedVoiceReplyItemIDs.contains(itemID)
    }

    func markVoiceReplyAutoplayed(itemID: String) {
        autoPlayedVoiceReplyItemIDs.insert(itemID)
    }

    func isStreamingPlaybackActive(itemID: String) -> Bool {
        let streamPlaybackID = Self.streamingPlaybackItemID(for: itemID)
        return playingItemID == streamPlaybackID || loadingItemID == streamPlaybackID
    }

    /// Consume low-latency audio chunks emitted by Oppi/Pi extensions.
    ///
    /// Supports 16-bit little-endian PCM (`audio/pcm; codecs=s16le`) for true
    /// streaming playback. WAV stream chunks are ignored here; completed WAVs
    /// should be rendered through normal tool-result audio attachments.
    func handleAudioStream(_ stream: AudioStreamMessage, sessionId: String? = nil) {
        if suppressedAudioStreamIDs.contains(stream.id) {
            if stream.event == .done || stream.event == .error {
                suppressedAudioStreamIDs.remove(stream.id)
            }
            return
        }

        if playbackSuppressedForCapture {
            suppressedAudioStreamIDs.insert(stream.id)
            if stream.event == .done || stream.event == .error {
                suppressedAudioStreamIDs.remove(stream.id)
            }
            return
        }

        let playbackBehavior = stream.playbackBehavior
        guard AppPreferences.Voice.shouldAutoplay(playbackBehavior: playbackBehavior, sessionId: sessionId) else {
            if stream.event == .error, playbackBehavior == .playNow {
                logger.error("Suppressed audio stream \(stream.id, privacy: .public) reported error: \(stream.text ?? "unknown", privacy: .public)")
            }
            return
        }

        if stream.mimeType == "audio/wav" {
            handleWAVAudioStream(stream)
            return
        }

        guard stream.mimeType == "audio/pcm; codecs=s16le" else {
            if stream.event == .error {
                recordVoicePlaybackError(source: "stream_unknown", phase: "stream", errorKind: "unsupported_mime")
                logger.error("Audio stream \(stream.id, privacy: .public) failed: \(stream.text ?? "unknown", privacy: .public)")
            }
            return
        }

        switch stream.event {
        case .metadata:
            startAudioStream(
                id: stream.id,
                sessionId: sessionId,
                sampleRate: Double(stream.sampleRate ?? 24_000),
                channels: AVAudioChannelCount(stream.channels ?? 1)
            )
        case .chunk:
            appendAudioStreamChunk(stream, sessionId: sessionId)
        case .done:
            guard stream.id == streamID else { return }
            streamReceivedDone = true
            finishAudioStreamIfDrained(id: stream.id)
        case .error:
            recordVoicePlaybackError(source: "stream_pcm", phase: "stream", errorKind: "remote_error")
            logger.error("Audio stream \(stream.id, privacy: .public) failed: \(stream.text ?? "unknown", privacy: .public)")
            stopAudioStream(clearState: true)
        }
    }

    // MARK: - Private

    private func stopMediaPlaybackSession() {
        stopProgressUpdates()
        mediaStatusObservation?.invalidate()
        mediaStatusObservation = nil
        if let mediaEndObserver {
            NotificationCenter.default.removeObserver(mediaEndObserver)
            self.mediaEndObserver = nil
        }
        mediaPlaybackSession?.teardown()
        mediaPlaybackSession = nil
    }

    private func play(data: Data, itemID: String, mode: String, startedAtMs: Int64) throws {
        guard !playbackSuppressedForCapture else { return }
        claimGlobalPlaybackOwnership()
        stopMediaPlaybackSession()
        stopAudioStream(clearState: false)
        // Configure audio session for playback
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playback, mode: .default)
        try audioSession.setActive(true)

        let audioPlayer = try AVAudioPlayer(data: data)
        attachAndStartPlayer(audioPlayer, itemID: itemID)
        recordVoicePlaybackStart(source: "data", mode: mode, durationMs: max(0, ChatSessionTelemetry.nowMs() - startedAtMs))
        logger.info("Playing audio data for item \(itemID), duration: \(audioPlayer.duration, format: .fixed(precision: 1))s")
    }

    private func play(fileURL: URL, itemID: String, mode: String, startedAtMs: Int64) throws {
        guard !playbackSuppressedForCapture else { return }
        claimGlobalPlaybackOwnership()
        stopMediaPlaybackSession()
        stopAudioStream(clearState: false)
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playback, mode: .default)
        try audioSession.setActive(true)

        let audioPlayer = try AVAudioPlayer(contentsOf: fileURL)
        attachAndStartPlayer(audioPlayer, itemID: itemID)
        recordVoicePlaybackStart(source: "file", mode: mode, durationMs: max(0, ChatSessionTelemetry.nowMs() - startedAtMs))
        logger.info("Playing audio file for item \(itemID): \(fileURL.lastPathComponent, privacy: .public)")
    }

    private func play(source: AuthenticatedMediaSource, itemID: String, mode: String, startedAtMs: Int64) throws {
        guard !playbackSuppressedForCapture else { return }
        claimGlobalPlaybackOwnership()
        stopMediaPlaybackSession()
        stopAudioStream(clearState: false)
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playback, mode: .default)
        try audioSession.setActive(true)

        let playbackSession = AuthenticatedMediaPlaybackSession(source: source)
        let player = playbackSession.player
        mediaPlaybackSession = playbackSession
        activePlaybackContext = sessionContext
        setPlaybackState(playing: nil, loading: itemID)
        updateNowPlayingInfo(durationSeconds: nil, isLiveStream: false)

        mediaEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.stopMediaPlaybackSession()
                self.deactivatePlaybackAudioSessionIfPossible()
                self.setPlaybackState(playing: nil, loading: nil)
                self.clearGlobalPlaybackOwnershipIfNeeded()
            }
        }

        mediaStatusObservation = player.currentItem?.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    let duration = item.duration.seconds
                    self.isPaused = false
                    self.duration = duration.isFinite && duration > 0 ? duration : nil
                    self.setPlaybackState(playing: itemID, loading: nil)
                    self.updateNowPlayingInfo(
                        durationSeconds: duration.isFinite ? duration : nil,
                        isLiveStream: false
                    )
                    player.play()
                    self.startProgressUpdates()
                    self.recordVoicePlaybackStart(
                        source: "media",
                        mode: mode,
                        durationMs: max(0, ChatSessionTelemetry.nowMs() - startedAtMs)
                    )
                case .failed:
                    self.recordVoicePlaybackError(source: "media", phase: "load", error: item.error)
                    logger.error("Audio media playback failed to load: \(item.error?.localizedDescription ?? "unknown")")
                    self.stopMediaPlaybackSession()
                    self.deactivatePlaybackAudioSessionIfPossible()
                    self.setPlaybackState(playing: nil, loading: nil)
                    self.clearGlobalPlaybackOwnershipIfNeeded()
                case .unknown:
                    self.setPlaybackState(playing: nil, loading: itemID)
                @unknown default:
                    self.stopMediaPlaybackSession()
                    self.deactivatePlaybackAudioSessionIfPossible()
                    self.setPlaybackState(playing: nil, loading: nil)
                    self.clearGlobalPlaybackOwnershipIfNeeded()
                }
            }
        }
    }

    private func attachAndStartPlayer(_ audioPlayer: AVAudioPlayer, itemID: String) {
        let delegate = PlaybackDelegate { [weak self] in
            Task { @MainActor in
                self?.handleDataPlaybackFinished()
            }
        }
        audioPlayer.delegate = delegate

        self.player = audioPlayer
        self.playbackDelegate = delegate
        activePlaybackContext = sessionContext
        isPaused = false
        currentTime = 0
        duration = audioPlayer.duration.isFinite && audioPlayer.duration > 0 ? audioPlayer.duration : nil
        setPlaybackState(playing: itemID, loading: nil)
        updateNowPlayingInfo(durationSeconds: audioPlayer.duration, isLiveStream: false)

        audioPlayer.play()
        startProgressUpdates()
    }

    private func handleDataPlaybackFinished() {
        stopProgressUpdates()
        player = nil
        playbackDelegate = nil
        deactivatePlaybackAudioSessionIfPossible()
        setPlaybackState(playing: nil, loading: nil)
        clearGlobalPlaybackOwnershipIfNeeded()
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
            markVoiceReplyAutoplayed(itemID: stream.id)
            toggleDataPlayback(data: data, itemID: Self.streamingPlaybackItemID(for: stream.id), mode: "autoplay")
        case .error:
            recordVoicePlaybackError(source: "stream_wav", phase: "stream", errorKind: "remote_error")
            logger.error("Audio stream \(stream.id, privacy: .public) failed: \(stream.text ?? "unknown", privacy: .public)")
            stopAudioStream(clearState: true)
        case .metadata:
            break
        }
    }

    private func startAudioStream(id: String, sessionId: String?, sampleRate: Double, channels: AVAudioChannelCount) {
        let startedAtMs = ChatSessionTelemetry.nowMs()
        guard (8_000...48_000).contains(sampleRate), channels == 1 || channels == 2 else {
            recordVoicePlaybackError(source: "stream_pcm", phase: "start", errorKind: "invalid_format")
            logger.error("Ignoring invalid audio stream format: \(sampleRate)Hz \(channels)ch")
            return
        }

        stop()
        claimGlobalPlaybackOwnership()

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default)
            try audioSession.setActive(true)

            let engine = AVAudioEngine()
            let node = AVAudioPlayerNode()
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels) else {
                recordVoicePlaybackError(source: "stream_pcm", phase: "start", errorKind: "invalid_format")
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
            streamSessionID = sessionId ?? sessionContext?.sessionID
            streamPendingBuffers = 0
            streamReceivedDone = false
            markVoiceReplyAutoplayed(itemID: id)
            activePlaybackContext = sessionContext
            setPlaybackState(playing: Self.streamingPlaybackItemID(for: id), loading: nil)
            updateNowPlayingInfo(durationSeconds: nil, isLiveStream: true)
            recordVoicePlaybackStart(source: "stream_pcm", mode: "autoplay", durationMs: max(0, ChatSessionTelemetry.nowMs() - startedAtMs))
        } catch {
            recordVoicePlaybackError(source: "stream_pcm", phase: "start", error: error)
            logger.error("Audio stream start failed: \(error.localizedDescription)")
            stopAudioStream(clearState: true)
        }
    }

    private func appendAudioStreamChunk(_ stream: AudioStreamMessage, sessionId: String?) {
        if streamID != stream.id {
            startAudioStream(
                id: stream.id,
                sessionId: sessionId,
                sampleRate: Double(stream.sampleRate ?? 24_000),
                channels: AVAudioChannelCount(stream.channels ?? 1)
            )
        } else if streamSessionID == nil {
            streamSessionID = sessionId ?? sessionContext?.sessionID
        }

        guard let node = streamNode,
              let format = streamFormat,
              let base64 = stream.audioBase64,
              let data = Data(base64Encoded: base64),
              !data.isEmpty else {
            return
        }

        guard data.count <= 384 * 1024 else {
            recordVoicePlaybackError(source: "stream_pcm", phase: "chunk", errorKind: "oversized_chunk")
            logger.error("Ignoring oversized audio stream chunk: \(data.count) bytes")
            return
        }

        guard let buffer = pcm16LEBuffer(data: data, format: format) else {
            recordVoicePlaybackError(source: "stream_pcm", phase: "chunk", errorKind: "decode")
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

    private func recordVoicePlaybackStart(source: String, mode: String, durationMs: Int64) {
        ChatSessionTelemetry.recordTimingMetric(
            .voicePlaybackStartMs,
            durationMs: durationMs,
            tags: [
                "source": source,
                "mode": mode,
                "status": "ok",
            ]
        )
    }

    private func recordVoicePlaybackError(
        source: String,
        phase: String,
        error: Error? = nil,
        errorKind: String? = nil
    ) {
        ChatSessionTelemetry.recordCountMetric(
            .voicePlaybackError,
            tags: [
                "source": source,
                "phase": phase,
                "error_kind": errorKind ?? error.map(ChatSessionTelemetry.metricErrorKind(for:)) ?? "other",
            ]
        )
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
        streamSessionID = nil
        streamPendingBuffers = 0
        streamReceivedDone = false
        if clearState {
            deactivatePlaybackAudioSessionIfPossible()
            setPlaybackState(playing: nil, loading: nil)
            clearGlobalPlaybackOwnershipIfNeeded()
        }
    }

    private func deactivatePlaybackAudioSessionIfPossible() {
        let audioSession = AVAudioSession.sharedInstance()
        guard Self.ownsPlaybackAudioSession(category: audioSession.category) else {
            return
        }

        do {
            try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            logger.debug("Playback audio session deactivation skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func ownsPlaybackAudioSession(category: AVAudioSession.Category) -> Bool {
        category == .playback
    }

    // periphery:ignore - test seam used by AudioPlayer/ConnectionCoordinator lifecycle tests
    var _isProgressTimerRunningForTesting: Bool { progressTimer != nil }

    // periphery:ignore - test seam used by audio completion tests
    func _finishDataPlaybackForTesting() {
        handleDataPlaybackFinished()
    }

    // periphery:ignore - test seam used by AudioPlayer/ConnectionCoordinator lifecycle tests
    func _setPlaybackStateForTesting(playing: String?, loading: String?) {
        if (playing != nil || loading != nil), playingItemID == nil, loadingItemID == nil {
            activePlaybackContext = sessionContext
        }
        setPlaybackState(playing: playing, loading: loading)
        if playing == nil, loading == nil, streamID == nil {
            activePlaybackContext = nil
        }
    }

    // periphery:ignore - test seam used by websocket/audio lifecycle tests
    func _setLiveTransportPlaybackForTesting(sessionID: String?, streamID: String = "test-stream", receivedDone: Bool = false) {
        if let sessionID {
            self.streamID = streamID
            streamSessionID = sessionID
            streamReceivedDone = receivedDone
            activePlaybackContext = SessionContext(
                sessionID: sessionID,
                sessionTitle: "Test Session",
                modelID: nil
            )
            setPlaybackState(playing: Self.streamingPlaybackItemID(for: streamID), loading: nil)
        } else {
            self.streamID = nil
            streamSessionID = nil
            streamReceivedDone = false
            setPlaybackState(playing: nil, loading: nil)
            activePlaybackContext = nil
        }
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

    private func claimGlobalPlaybackOwnership() {
        if let activeOwner = Self.activePlaybackOwner, activeOwner !== self {
            activeOwner.stop()
        }
        Self.installRemoteCommandTargetsIfNeeded()
        Self.activePlaybackOwner = self
    }

    private func clearGlobalPlaybackOwnershipIfNeeded() {
        guard Self.activePlaybackOwner === self, !hasActivePlayback else {
            return
        }
        Self.activePlaybackOwner = nil
        activePlaybackContext = nil
        lastNowPlayingDurationSeconds = nil
        lastNowPlayingIsLiveStream = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func startProgressUpdates() {
        stopProgressUpdates()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.publishProgress()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
        if let mediaPlayer = mediaPlaybackSession?.player {
            mediaTimeObserver = mediaPlayer.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                queue: .main
            ) { [weak self] time in
                Task { @MainActor in
                    guard let self else { return }
                    if time.seconds.isFinite {
                        self.currentTime = time.seconds
                    }
                    self.publishProgress()
                }
            }
        }
        publishProgress()
    }

    private func stopProgressUpdates() {
        progressTimer?.invalidate()
        progressTimer = nil
        if let mediaTimeObserver, let mediaPlayer = mediaPlaybackSession?.player {
            mediaPlayer.removeTimeObserver(mediaTimeObserver)
        }
        mediaTimeObserver = nil
    }

    private func publishProgress() {
        if let player {
            currentTime = player.currentTime
            duration = player.duration.isFinite && player.duration > 0 ? player.duration : duration
        } else if let mediaPlayer = mediaPlaybackSession?.player {
            let elapsed = mediaPlayer.currentTime().seconds
            if elapsed.isFinite {
                currentTime = elapsed
            }
            let itemDuration = mediaPlayer.currentItem?.duration.seconds
            if let itemDuration, itemDuration.isFinite, itemDuration > 0 {
                duration = itemDuration
            }
        }
        NotificationCenter.default.post(
            name: Self.stateDidChangeNotification,
            object: self,
            userInfo: [
                Self.playingItemIDUserInfoKey: playingItemID ?? "",
                Self.loadingItemIDUserInfoKey: loadingItemID ?? "",
            ]
        )
    }

    private func updateNowPlayingInfo(durationSeconds: Double?, isLiveStream: Bool, playbackRate: Float = 1.0) {
        lastNowPlayingDurationSeconds = durationSeconds
        lastNowPlayingIsLiveStream = isLiveStream

        let mediaPlayer = mediaPlaybackSession?.player
        guard player != nil || streamID != nil || mediaPlayer != nil else {
            return
        }

        let mediaElapsed = mediaPlayer?.currentTime().seconds
        let elapsedPlaybackTime = player?.currentTime
            ?? (mediaElapsed?.isFinite == true ? mediaElapsed ?? 0 : 0)
        let presentation = nowPlayingPresentation
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: presentation?.title ?? Self.nowPlayingFallbackTitle,
            MPMediaItemPropertyArtist: presentation?.subtitle ?? Self.nowPlayingFallbackArtist,
            MPMediaItemPropertyAlbumTitle: "Voice reply",
            MPNowPlayingInfoPropertyPlaybackRate: playbackRate,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsedPlaybackTime,
        ]
        if let durationSeconds {
            info[MPMediaItemPropertyPlaybackDuration] = durationSeconds
        }
        if isLiveStream {
            info[MPNowPlayingInfoPropertyIsLiveStream] = true
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private static func installRemoteCommandTargetsIfNeeded() {
        guard !remoteCommandTargetsInstalled else { return }
        remoteCommandTargetsInstalled = true

        let center = MPRemoteCommandCenter.shared()
        let stopHandler: (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus = { _ in
            Task { @MainActor in
                Self.activePlaybackOwner?.stop()
            }
            return .success
        }

        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.stopCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.playCommand.addTarget { _ in
            Task { @MainActor in
                Self.activePlaybackOwner?.resume()
            }
            return .success
        }
        center.pauseCommand.addTarget { _ in
            Task { @MainActor in
                Self.activePlaybackOwner?.pause()
            }
            return .success
        }
        center.stopCommand.addTarget(handler: stopHandler)
        center.togglePlayPauseCommand.addTarget { _ in
            Task { @MainActor in
                guard let owner = Self.activePlaybackOwner else { return }
                if owner.isPaused {
                    owner.resume()
                } else {
                    owner.pause()
                }
            }
            return .success
        }
    }

    private static func streamingPlaybackItemID(for streamID: String) -> String {
        "audio-stream-\(streamID)"
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
