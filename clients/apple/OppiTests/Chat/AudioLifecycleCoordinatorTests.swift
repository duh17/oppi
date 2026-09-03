import AVFoundation
import MediaPlayer
import Testing
@testable import Oppi

@Suite("AudioLifecycleCoordinator")
@MainActor
struct AudioLifecycleCoordinatorTests {
    @Test func streamingVoiceTextProjectsCompactTimelinePresentation() {
        let coordinator = AudioLifecycleCoordinator()

        coordinator.updateAudioText(
            itemID: "voice-1",
            text: "  Hello from direct voice.  ",
            playbackBehavior: .playNow
        )

        #expect(coordinator.mode == .idle)
        #expect(
            coordinator.presentation.timelinePresentation(for: "voice-1") ==
                .streamingTranscript(text: "Hello from direct voice.", playbackBehavior: .playNow)
        )
    }

    @Test func directSpeakProjectsSpeakingTranscriptAndFinalCard() {
        let coordinator = AudioLifecycleCoordinator()

        coordinator.beginDirectSpeak(itemID: "voice-1", transcript: "Speaking now.")
        #expect(coordinator.mode == .playing(itemID: "voice-1", source: .directSpeak))
        #expect(
            coordinator.presentation.timelinePresentation(for: "voice-1") ==
                .speakingTranscript(text: "Speaking now.", isStopping: false)
        )

        coordinator.finishAudioMessage(
            itemID: "voice-1",
            attachmentID: "att-1",
            transcript: "Speaking now."
        )
        #expect(coordinator.mode == .idle)
        #expect(
            coordinator.presentation.timelinePresentation(for: "voice-1") ==
                .finalCard(transcript: "Speaking now.", attachmentID: "att-1", replayState: .idle)
        )
    }

    @Test func microphoneStartInterruptsPlaybackBeforePreparingCapture() {
        let coordinator = AudioLifecycleCoordinator()
        coordinator.beginDirectSpeak(itemID: "voice-1", transcript: "Do not record this.")

        coordinator.startDictation()

        #expect(coordinator.mode == .preparingCapture)
        #expect(coordinator.presentation.composer == .preparing)
        #expect(coordinator.stopRequests.count == 1)
        #expect(coordinator.stopRequests.first?.itemID == "voice-1")
        #expect(coordinator.stopRequests.first?.reason == .microphoneStarted)
        #expect(
            coordinator.presentation.timelinePresentation(for: "voice-1") ==
                .streamingTranscript(text: "Do not record this.", playbackBehavior: .playNow)
        )
    }

    @Test func coordinatorInterrupterDelegatesStopAndUpdatesLifecycle() {
        let playback = PlaybackInterrupterSpy()
        let coordinator = AudioLifecycleCoordinator()
        coordinator.setPlaybackInterrupter(playback)
        coordinator.beginDirectSpeak(itemID: "voice-1", transcript: "Speaking.")

        #expect(coordinator.hasActivePlayback)
        coordinator.stop()

        #expect(playback.stopCount == 1)
        #expect(coordinator.mode == .idle)
        #expect(coordinator.stopRequests.last?.reason == .user)
    }

    @Test func presentationPlaybackAloneDoesNotReportHardwarePlayback() {
        let coordinator = AudioLifecycleCoordinator()

        coordinator.beginDirectSpeak(itemID: "voice-1", transcript: "Stale presentation.")

        #expect(coordinator.mode == .playing(itemID: "voice-1", source: .directSpeak))
        #expect(!coordinator.hasActivePlayback)
    }

    @Test func playbackNotificationsSyncLifecycleMode() {
        let coordinator = AudioLifecycleCoordinator()

        coordinator.syncPlaybackState(playingItemID: "audio-stream-voice-1", loadingItemID: nil)
        #expect(coordinator.mode == .playing(itemID: "voice-1", source: .directSpeak))

        coordinator.syncPlaybackState(playingItemID: nil, loadingItemID: "voice-2")
        #expect(coordinator.mode == .preparingPlayback(itemID: "voice-2", source: .audioMessageReplay))

        coordinator.syncPlaybackState(playingItemID: nil, loadingItemID: nil)
        #expect(coordinator.mode == .idle)
    }

    @Test func legacyDirectSpeakPlaybackIDsRemainSupported() {
        let coordinator = AudioLifecycleCoordinator()

        coordinator.syncPlaybackState(playingItemID: "stream:voice-1", loadingItemID: nil)

        #expect(coordinator.mode == .playing(itemID: "voice-1", source: .directSpeak))
    }

    @Test func captureLifecycleProjectsComposerState() {
        let coordinator = AudioLifecycleCoordinator()

        coordinator.startDictation()
        #expect(coordinator.presentation.composer == .preparing)

        coordinator.captureStarted()
        #expect(coordinator.mode == .recording)
        #expect(coordinator.presentation.composer == .recording)

        coordinator.finalizeCapture()
        #expect(coordinator.mode == .finalizingCapture)
        #expect(coordinator.presentation.composer == .finalizing)

        coordinator.finishCapture()
        #expect(coordinator.mode == .idle)
        #expect(coordinator.presentation.composer == .idle)
    }

    @Test func emptyVoiceTextProjectsHiddenTimelineState() {
        let coordinator = AudioLifecycleCoordinator()

        coordinator.updateAudioText(itemID: "voice-1", text: "   \n", playbackBehavior: .tapToPlay)

        #expect(coordinator.presentation.timelinePresentation(for: "voice-1") == .hidden)
    }

    @Test func audioPlayerOnlyDeactivatesPlaybackOwnedSession() {
        #expect(AudioPlayerService.ownsPlaybackAudioSession(category: .playback))
        #expect(!AudioPlayerService.ownsPlaybackAudioSession(category: .record))
        #expect(!AudioPlayerService.ownsPlaybackAudioSession(category: .playAndRecord))
    }

    @Test func audioPlayerAutoplayIsSuppressedDuringCapture() {
        let player = AudioPlayerService()

        #expect(player.shouldAutoplayAudioMessage(itemID: "voice-1", playbackBehavior: .playNow))

        player.beginCaptureInterruption()
        #expect(!player.shouldAutoplayAudioMessage(itemID: "voice-2", playbackBehavior: .playNow))

        player.endCaptureInterruption()
        #expect(player.shouldAutoplayAudioMessage(itemID: "voice-3", playbackBehavior: .playNow))
    }

    @Test func audioPlayerUsesSessionReplyModeOverrideForAutoplay() {
        let player = AudioPlayerService()
        let sessionId = "session-voice-override"
        let previousReplyMode = AppPreferences.Voice.replyMode
        let previousSessionReplyMode = AppPreferences.Voice.sessionReplyMode(for: sessionId)
        defer {
            AppPreferences.Voice.setReplyMode(previousReplyMode)
            AppPreferences.Voice.setSessionReplyMode(previousSessionReplyMode, for: sessionId)
        }

        AppPreferences.Voice.setReplyMode(.autoplay)
        AppPreferences.Voice.setSessionReplyMode(.manual, for: sessionId)

        #expect(!player.shouldAutoplayAudioMessage(itemID: "voice-session-manual", playbackBehavior: .tapToPlay, sessionId: sessionId))
        #expect(!player.shouldAutoplayAudioMessage(itemID: "voice-session-direct", playbackBehavior: .playNow, sessionId: sessionId))
    }

    @Test func audioPlayerAgentDecidesModeOnlyAutoplaysPlayNowReplies() {
        let player = AudioPlayerService()
        let previousReplyMode = AppPreferences.Voice.replyMode
        defer { AppPreferences.Voice.setReplyMode(previousReplyMode) }

        AppPreferences.Voice.setReplyMode(.autoplay)

        #expect(player.shouldAutoplayAudioMessage(itemID: "voice-agent-direct", playbackBehavior: .playNow))
        #expect(!player.shouldAutoplayAudioMessage(itemID: "voice-agent-manual", playbackBehavior: .tapToPlay))
        #expect(!player.shouldAutoplayAudioMessage(itemID: "voice-agent-default", playbackBehavior: nil))
    }

    @Test func audioPlayerNowPlayingInfoDoesNotInstallArtwork() {
        let player = AudioPlayerService()
        player.setSessionContext(
            makeTestSession(
                id: "session-artwork-crash",
                name: "Artwork crash guard",
                model: "openai/o4-mini"
            )
        )
        player.toggleDataPlayback(data: Self.makeSilentWAV(), itemID: "voice-artwork-guard")
        defer { player.stop() }

        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        #expect(info?[MPMediaItemPropertyTitle] as? String == "Voice reply")
        #expect(info?[MPMediaItemPropertyArtwork] == nil)
    }

    @Test func audioPlayerStopsProgressTimerWhenDataPlaybackFinishes() {
        let player = AudioPlayerService()
        player.toggleDataPlayback(data: Self.makeSilentWAV(), itemID: "voice-finish-timer")
        defer { player.stop() }

        #expect(player._isProgressTimerRunningForTesting)
        player._finishDataPlaybackForTesting()
        #expect(!player._isProgressTimerRunningForTesting)
        #expect(player.playingItemID == nil)
    }

    @Test func audioPlayerNowPlayingPresentationUsesSessionTitleAndModel() {
        let player = AudioPlayerService()
        player.setSessionContext(
            makeTestSession(
                id: "session-12345678",
                name: "Fix playback bar",
                model: "openai/o4-mini"
            )
        )
        player._setPlaybackStateForTesting(playing: "voice-1", loading: nil)

        let presentation = player.nowPlayingPresentation
        #expect(presentation?.sessionID == "session-12345678")
        #expect(presentation?.title == "Voice reply")
        #expect(presentation?.subtitle == "o4-mini")
        #expect(presentation?.provider == "openai")
    }

    @Test func audioPlayerNowPlayingPresentationFallsBackToSessionPrefixWithoutModel() {
        let player = AudioPlayerService()
        player.setSessionContext(
            makeTestSession(
                id: "abc12345-rest-of-session",
                name: nil,
                model: nil,
                firstMessage: nil
            )
        )
        player._setPlaybackStateForTesting(playing: "voice-2", loading: nil)

        let presentation = player.nowPlayingPresentation
        #expect(presentation?.title == "Voice reply")
        #expect(presentation?.subtitle == "Session abc12345")
        #expect(presentation?.provider == nil)
    }

    @Test func audioPlayerNowPlayingPresentationStaysBoundToOriginalSessionDuringPlayback() {
        let player = AudioPlayerService()
        player.setSessionContext(
            makeTestSession(
                id: "session-a",
                name: "Session A",
                model: "openai/o4-mini"
            )
        )
        player._setPlaybackStateForTesting(playing: "voice-3", loading: nil)

        player.setSessionContext(
            makeTestSession(
                id: "session-b",
                name: "Session B",
                model: "anthropic/claude-sonnet-4"
            )
        )

        let presentation = player.nowPlayingPresentation
        #expect(presentation?.sessionID == "session-a")
        #expect(presentation?.title == "Voice reply")
        #expect(presentation?.subtitle == "o4-mini")
        #expect(presentation?.provider == "openai")
    }

    @Test func validMicrophoneFormatPassesAudioEngineValidation() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))

        try AudioEngineHelper.validateInputFormat(format)
    }

    private static func makeSilentWAV(sampleRate: Int = 24_000, frames: Int = 2_400) -> Data {
        var data = Data()
        let pcmBytes = frames * 2
        func appendString(_ value: String) { data.append(contentsOf: value.utf8) }
        func appendUInt16(_ value: UInt16) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        func appendUInt32(_ value: UInt32) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }

        appendString("RIFF")
        appendUInt32(UInt32(36 + pcmBytes))
        appendString("WAVE")
        appendString("fmt ")
        appendUInt32(16)
        appendUInt16(1)
        appendUInt16(1)
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(sampleRate * 2))
        appendUInt16(2)
        appendUInt16(16)
        appendString("data")
        appendUInt32(UInt32(pcmBytes))
        data.append(Data(repeating: 0, count: pcmBytes))
        return data
    }
}

@MainActor
private final class PlaybackInterrupterSpy: VoicePlaybackInterrupter {
    var hasActivePlayback = true
    private(set) var stopCount = 0

    func stop() {
        stopCount += 1
        hasActivePlayback = false
    }
}
