import Testing
@testable import Oppi

@Suite("AudioLifecycleCoordinator")
@MainActor
struct AudioLifecycleCoordinatorTests {
    @Test func streamingVoiceTextProjectsCompactTimelinePresentation() {
        let coordinator = AudioLifecycleCoordinator()

        coordinator.updateVoiceText(
            itemID: "voice-1",
            text: "  Hello from direct voice.  ",
            delivery: .directSpeak
        )

        #expect(coordinator.mode == .idle)
        #expect(
            coordinator.presentation.timelinePresentation(for: "voice-1") ==
                .streamingTranscript(text: "Hello from direct voice.", delivery: .directSpeak)
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

        coordinator.finishVoiceMessage(
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
                .streamingTranscript(text: "Do not record this.", delivery: .directSpeak)
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

    @Test func playbackNotificationsSyncLifecycleMode() {
        let coordinator = AudioLifecycleCoordinator()

        coordinator.syncPlaybackState(playingItemID: "stream:voice-1", loadingItemID: nil)
        #expect(coordinator.mode == .playing(itemID: "voice-1", source: .directSpeak))

        coordinator.syncPlaybackState(playingItemID: nil, loadingItemID: "voice-2")
        #expect(coordinator.mode == .preparingPlayback(itemID: "voice-2", source: .voiceMessageReplay))

        coordinator.syncPlaybackState(playingItemID: nil, loadingItemID: nil)
        #expect(coordinator.mode == .idle)
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

        coordinator.updateVoiceText(itemID: "voice-1", text: "   \n", delivery: .voiceMessage)

        #expect(coordinator.presentation.timelinePresentation(for: "voice-1") == .hidden)
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
