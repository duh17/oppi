import Foundation

/// High-level audio mode owned by the app, independent of any concrete provider.
enum AudioLifecycleMode: Equatable, Sendable {
    case idle
    case preparingPlayback(itemID: String, source: AudioPlaybackSource)
    case playing(itemID: String, source: AudioPlaybackSource)
    case preparingCapture
    case recording
    case finalizingCapture
    case interrupted(reason: String)
    case error(message: String)
}

enum AudioPlaybackSource: Equatable, Sendable {
    case directSpeak
    case voiceMessageReplay
}

enum AudioStopReason: Equatable, Sendable {
    case user
    case microphoneStarted
    case finished
    case interrupted
    case error
}

enum ReplayState: Equatable, Sendable {
    case unavailable
    case idle
    case loading
    case playing
}

enum VoiceComposerPresentation: Equatable, Sendable {
    case idle
    case preparing
    case recording
    case finalizing
    case disabled(reason: String)
}

enum VoiceTimelinePresentation: Equatable, Sendable {
    case hidden
    case streamingTranscript(text: String, delivery: VoiceReplyDelivery?)
    case speakingTranscript(text: String, isStopping: Bool)
    case finalCard(transcript: String, attachmentID: String?, replayState: ReplayState)
    case error(message: String)
}

struct AudioPresentationState: Equatable, Sendable {
    var mode: AudioLifecycleMode = .idle
    var timelineItems: [String: VoiceTimelinePresentation] = [:]
    var composer: VoiceComposerPresentation = .idle
    var routeWarning: String?

    func timelinePresentation(for itemID: String) -> VoiceTimelinePresentation {
        timelineItems[itemID] ?? .hidden
    }
}

/// Phase-1 policy object for coordinating audio device state and rendering state.
///
/// This is intentionally provider-neutral. Existing playback and dictation
/// services can be routed through it incrementally while tests lock down the
/// lifecycle/rendering contract first.
@MainActor
final class AudioLifecycleCoordinator: VoicePlaybackInterrupter {
    private(set) var presentation = AudioPresentationState()
    private(set) var stopRequests: [(itemID: String, reason: AudioStopReason)] = []

    private weak var playbackInterrupter: (any VoicePlaybackInterrupter)?

    var mode: AudioLifecycleMode { presentation.mode }

    var hasActivePlayback: Bool {
        // Hardware playback truth belongs to the concrete playback service.
        // Presentation mode can be stale if a direct-speak notification is missed
        // during reconnect/navigation, and must not keep dictation from starting.
        playbackInterrupter?.hasActivePlayback == true
    }

    func setPlaybackInterrupter(_ interrupter: (any VoicePlaybackInterrupter)?) {
        playbackInterrupter = interrupter
    }

    func stop() {
        if case .playing(let itemID, _) = presentation.mode {
            stopRequests.append((itemID: itemID, reason: .user))
            markStoppedForCapture(itemID: itemID)
        }
        playbackInterrupter?.stop()
        presentation.mode = .idle
    }

    func syncPlaybackState(playingItemID: String?, loadingItemID: String?) {
        if let playingItemID {
            presentation.mode = .playing(itemID: canonicalItemID(fromPlaybackID: playingItemID), source: playbackSource(fromPlaybackID: playingItemID))
        } else if let loadingItemID {
            presentation.mode = .preparingPlayback(itemID: canonicalItemID(fromPlaybackID: loadingItemID), source: playbackSource(fromPlaybackID: loadingItemID))
        } else if isLifecyclePlaybackActive {
            presentation.mode = .idle
        }
    }

    func updateVoiceText(itemID: String, text: String, delivery: VoiceReplyDelivery?) {
        let transcript = normalizedTranscript(text)
        guard !transcript.isEmpty else {
            presentation.timelineItems[itemID] = .hidden
            return
        }

        switch presentation.mode {
        case .playing(let activeID, .directSpeak) where activeID == itemID:
            presentation.timelineItems[itemID] = .speakingTranscript(text: transcript, isStopping: false)
        default:
            presentation.timelineItems[itemID] = .streamingTranscript(text: transcript, delivery: delivery)
        }
    }

    func beginDirectSpeak(itemID: String, transcript: String) {
        let text = normalizedTranscript(transcript)
        presentation.mode = .playing(itemID: itemID, source: .directSpeak)
        presentation.composer = .idle
        presentation.timelineItems[itemID] = .speakingTranscript(text: text, isStopping: false)
    }

    func finishVoiceMessage(itemID: String, attachmentID: String?, transcript: String?) {
        let text = normalizedTranscript(transcript ?? "")
        presentation.timelineItems[itemID] = .finalCard(
            transcript: text,
            attachmentID: attachmentID,
            replayState: attachmentID?.isEmpty == false ? .idle : .unavailable
        )
        if case .playing(let activeID, _) = presentation.mode, activeID == itemID {
            presentation.mode = .idle
        }
    }

    func playVoiceMessage(itemID: String, transcript: String, attachmentID: String?) {
        let text = normalizedTranscript(transcript)
        presentation.mode = .playing(itemID: itemID, source: .voiceMessageReplay)
        presentation.timelineItems[itemID] = .finalCard(
            transcript: text,
            attachmentID: attachmentID,
            replayState: .playing
        )
    }

    func startDictation() {
        if case .playing(let itemID, _) = presentation.mode {
            stopRequests.append((itemID: itemID, reason: .microphoneStarted))
            markStoppedForCapture(itemID: itemID)
        }
        presentation.mode = .preparingCapture
        presentation.composer = .preparing
    }

    func captureStarted() {
        presentation.mode = .recording
        presentation.composer = .recording
    }

    func finalizeCapture() {
        presentation.mode = .finalizingCapture
        presentation.composer = .finalizing
    }

    func finishCapture() {
        presentation.mode = .idle
        presentation.composer = .idle
    }

    func interrupt(reason: String) {
        if case .playing(let itemID, _) = presentation.mode {
            stopRequests.append((itemID: itemID, reason: .interrupted))
            markStoppedForCapture(itemID: itemID)
        }
        presentation.mode = .interrupted(reason: reason)
        presentation.routeWarning = reason
    }

    func fail(_ message: String, itemID: String? = nil) {
        presentation.mode = .error(message: message)
        presentation.composer = .disabled(reason: message)
        if let itemID {
            presentation.timelineItems[itemID] = .error(message: message)
        }
    }

    private func markStoppedForCapture(itemID: String) {
        switch presentation.timelineItems[itemID] {
        case .speakingTranscript(let text, _):
            presentation.timelineItems[itemID] = .streamingTranscript(text: text, delivery: .directSpeak)
        case .finalCard(let transcript, let attachmentID, _):
            presentation.timelineItems[itemID] = .finalCard(
                transcript: transcript,
                attachmentID: attachmentID,
                replayState: attachmentID?.isEmpty == false ? .idle : .unavailable
            )
        case .streamingTranscript, .error, .hidden, .none:
            break
        }
    }

    private var isLifecyclePlaybackActive: Bool {
        switch presentation.mode {
        case .preparingPlayback, .playing:
            return true
        case .idle, .preparingCapture, .recording, .finalizingCapture, .interrupted, .error:
            return false
        }
    }

    private func playbackSource(fromPlaybackID playbackID: String) -> AudioPlaybackSource {
        isDirectSpeakPlaybackID(playbackID) ? .directSpeak : .voiceMessageReplay
    }

    private func canonicalItemID(fromPlaybackID playbackID: String) -> String {
        if playbackID.hasPrefix(Self.legacyDirectSpeakPlaybackPrefix) {
            return String(playbackID.dropFirst(Self.legacyDirectSpeakPlaybackPrefix.count))
        }
        if playbackID.hasPrefix(Self.directSpeakPlaybackPrefix) {
            return String(playbackID.dropFirst(Self.directSpeakPlaybackPrefix.count))
        }
        return playbackID
    }

    private func isDirectSpeakPlaybackID(_ playbackID: String) -> Bool {
        playbackID.hasPrefix(Self.directSpeakPlaybackPrefix)
            || playbackID.hasPrefix(Self.legacyDirectSpeakPlaybackPrefix)
    }

    private static let directSpeakPlaybackPrefix = "audio-stream-"
    private static let legacyDirectSpeakPlaybackPrefix = "stream:"

    private func normalizedTranscript(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
