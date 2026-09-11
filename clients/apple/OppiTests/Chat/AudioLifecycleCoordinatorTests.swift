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

    @Test func audioPlayerKeepsCurrentPlaybackButSuppressesNewAutoplayDuringCapture() {
        let player = AudioPlayerService()
        player._startPCMStreamForTesting(id: "voice-current")

        #expect(player.shouldAutoplayAudioMessage(itemID: "voice-1", playbackBehavior: .playNow))
        #expect(player.isPlaybackActiveForCapture)

        player.beginCaptureInterruption()
        #expect(player.playingItemID == "audio-stream-voice-current")
        #expect(player.hasActivePlayback)
        #expect(!player.shouldAutoplayAudioMessage(itemID: "voice-2", playbackBehavior: .playNow))

        let audioSession = AVAudioSession.sharedInstance()
        let previousCategory = audioSession.category
        let previousMode = audioSession.mode
        let previousOptions = audioSession.categoryOptions
        defer {
            player.stop()
            try? audioSession.setCategory(previousCategory, mode: previousMode, options: previousOptions)
        }
        try? audioSession.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers])

        player.endCaptureInterruption()
        #expect(player.shouldAutoplayAudioMessage(itemID: "voice-3", playbackBehavior: .playNow))
        #expect(player.playingItemID == "audio-stream-voice-current")
        #expect(audioSession.category == .playback)
    }

    @Test func pausedPlaybackItemDoesNotReassertExclusiveSessionAfterCapture() {
        let player = AudioPlayerService()
        player._setPlaybackStateForTesting(playing: "voice-paused", loading: nil)
        player._setPausedForTesting(true)
        #expect(player.hasActivePlayback)
        #expect(!player.isPlaybackActiveForCapture)

        let audioSession = AVAudioSession.sharedInstance()
        let previousCategory = audioSession.category
        let previousMode = audioSession.mode
        let previousOptions = audioSession.categoryOptions
        defer {
            player.stop()
            try? audioSession.setCategory(previousCategory, mode: previousMode, options: previousOptions)
        }
        try? audioSession.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers])

        player.beginCaptureInterruption()
        player.endCaptureInterruption()

        #expect(audioSession.category == .playAndRecord)
    }

    @Test(arguments: ["data", "file", "pcm"], [false, true])
    func pausedPlaybackResumeReclaimsRoutingOnlyAfterCaptureRelease(path: String, captureReleased: Bool) throws {
        let player = AudioPlayerService()
        let audioSession = AVAudioSession.sharedInstance()
        let previousCategory = audioSession.category
        let previousMode = audioSession.mode
        let previousOptions = audioSession.categoryOptions
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("resume-\(UUID()).wav")
        defer {
            player.stop()
            try? audioSession.setCategory(previousCategory, mode: previousMode, options: previousOptions)
            try? FileManager.default.removeItem(at: fileURL)
        }
        switch path {
        case "data":
            player.toggleDataPlayback(data: Self.makeSilentWAV(frames: 240_000), itemID: "retained-data")
        case "file":
            try Self.makeSilentWAV(frames: 240_000).write(to: fileURL)
            player.toggleFilePlayback(fileURL: fileURL, itemID: "retained-file")
        default:
            player._startPCMStreamForTesting(id: "retained-pcm")
        }
        let retainedItem = try #require(player.playingItemID)
        player.pause()
        #expect(player.isPaused)
        player.beginCaptureInterruption()
        let captureOptions: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .mixWithOthers, .duckOthers]
        try audioSession.setCategory(.playAndRecord, mode: .default, options: captureOptions)
        try audioSession.setActive(true)
        if captureReleased {
            player.endCaptureInterruption()
            // Mirrors the manager releasing an inactive/paused playback owner.
            try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        }
        #expect(audioSession.category == .playAndRecord, "Paused release must not restore playback prematurely")

        player.resume()

        #expect(player.playingItemID == retainedItem)
        #expect(!player.isPaused)
        #expect(audioSession.category == (captureReleased ? .playback : .playAndRecord))
        #expect(audioSession.categoryOptions == (captureReleased ? [] : captureOptions))
        if !captureReleased { player.endCaptureInterruption() }
    }

    @Test func currentPCMStreamIsNotSuppressedWhenCaptureBegins() {
        #expect(!AudioPlayerService.shouldSuppressAudioStreamDuringCapture(
            captureActive: true,
            incomingStreamID: "stream-current",
            activeStreamID: "stream-current"
        ))
        #expect(AudioPlayerService.shouldSuppressAudioStreamDuringCapture(
            captureActive: true,
            incomingStreamID: "stream-late",
            activeStreamID: "stream-current"
        ))
        #expect(!AudioPlayerService.shouldSuppressAudioStreamDuringCapture(
            captureActive: false,
            incomingStreamID: "stream-late",
            activeStreamID: "stream-current"
        ))
    }

    @Test func pcmPlaybackRebuildKeepsStreamIdentityAfterConfigurationChange() {
        let player = AudioPlayerService()
        player._startPCMStreamForTesting(id: "stream-recover")
        defer { player.stop() }
        let initialGeneration = player._streamEngineGenerationForTesting

        player._rebuildPCMStreamForTesting()

        #expect(player._streamEngineGenerationForTesting > initialGeneration)
        #expect(player.playingItemID == "audio-stream-stream-recover")
        #expect(player.hasActivePlayback)
    }

    @Test func pcmConfigurationCompletionCannotDiscardUnplayedPendingBuffer() {
        let player = AudioPlayerService()
        player._startPCMStreamForTesting(id: "stream-recover-pending")
        defer { player.stop() }
        let generation = player._streamEngineGenerationForTesting
        let token = player._appendUnscheduledPCMBufferForTesting()

        player._beginPCMConfigurationChangeForTesting(generation: generation)
        player._completePCMBufferForTesting(
            token: token,
            streamID: "stream-recover-pending",
            generation: generation
        )
        #expect(player._pendingPCMBufferCountForTesting == 1)

        player._finishPCMConfigurationChangeForTesting(
            generation: generation,
            engineIsRunning: false
        )
        #expect(player._pendingPCMBufferCountForTesting == 1)
        #expect(player.playingItemID == "audio-stream-stream-recover-pending")
    }

    @Test func pcmCompletionBeforeConfigurationNotificationRetainsRealPendingAudio() throws {
        let player = AudioPlayerService()
        player._startPCMStreamForTesting(id: "completion-first")
        defer { player.stop() }
        player.pause()
        let generation = player._streamEngineGenerationForTesting
        let samples = Data([0x00, 0x40, 0x00, 0xC0])
        let token = try #require(player._schedulePCMForTesting(samples))

        player._completePCMBufferForTesting(
            token: token, streamID: "completion-first", generation: generation,
            engineIsRunning: false
        )
        #expect(player._pendingPCMBufferCountForTesting == 1)
        // Once invalidated, neither a later completion nor a running snapshot can
        // rehabilitate this generation's stop-driven callbacks.
        player._completePCMBufferForTesting(
            token: token, streamID: "completion-first", generation: generation
        )
        player._beginPCMConfigurationChangeForTesting(generation: generation)
        player._finishPCMConfigurationChangeForTesting(generation: generation, engineIsRunning: true)
        #expect(player._pendingPCMSamplesForTesting == [[0.5, -0.5]])
        #expect(player._streamEngineGenerationForTesting > generation)

        // Late callbacks from the replaced graph cannot consume the rescheduled copy.
        player._completePCMBufferForTesting(
            token: token, streamID: "completion-first", generation: generation
        )
        #expect(player._pendingPCMBufferCountForTesting == 1)
    }

    @Test func pcmArrivingOnStoppedGraphIsRetainedForRecovery() throws {
        let player = AudioPlayerService()
        player._startPCMStreamForTesting(id: "chunk-before-notification")
        defer { player.stop() }
        player.pause()
        let generation = player._streamEngineGenerationForTesting
        player._stopPCMEngineForTesting()
        _ = try #require(player._schedulePCMForTesting(Data([0x00, 0x40])))
        #expect(player._pendingPCMSamplesForTesting == [[0.5]])
        player._finishPCMConfigurationChangeForTesting(generation: generation, engineIsRunning: false)
        #expect(player._streamEngineGenerationForTesting > generation)
        #expect(player._pendingPCMSamplesForTesting == [[0.5]])
    }

    @Test func pcmConsumedCallbackCannotRetireAudioBeforePlayback() throws {
        let player = AudioPlayerService()
        player._startPCMStreamForTesting(id: "consumed-not-played")
        defer { player.stop() }
        player.pause()
        let token = try #require(player._schedulePCMForTesting(Data([0x00, 0x40])))
        let generation = player._streamEngineGenerationForTesting
        player._completePCMBufferForTesting(
            token: token, streamID: "consumed-not-played", generation: generation,
            callbackType: .dataConsumed
        )
        #expect(player._pendingPCMSamplesForTesting == [[0.5]])
        player._completePCMBufferForTesting(
            token: token, streamID: "consumed-not-played", generation: generation,
            callbackType: .dataPlayedBack
        )
        #expect(player._pendingPCMBufferCountForTesting == 0)
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

    @Test(arguments: ["data", "file", "pcm"], [(false, false), (false, true), (true, false), (true, true)])
    func otherServersPlaybackSurvivesCaptureWithoutStealingItsRoute(
        path: String, paused: (atStart: Bool, atRelease: Bool)
    ) async throws {
        let playerA = AudioPlayerService()
        let playerB = AudioPlayerService()
        let audioSession = AVAudioSession.sharedInstance()
        let previousCategory = audioSession.category
        let previousMode = audioSession.mode
        let previousOptions = audioSession.categoryOptions
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("other-server-\(UUID()).wav")
        defer {
            playerA.stop()
            playerB.stop()
            try? audioSession.setCategory(previousCategory, mode: previousMode, options: previousOptions)
            try? FileManager.default.removeItem(at: fileURL)
        }
        switch path {
        case "data":
            playerA.toggleDataPlayback(data: Self.makeSilentWAV(frames: 240_000), itemID: "server-a-data")
        case "file":
            try Self.makeSilentWAV(frames: 240_000).write(to: fileURL)
            playerA.toggleFilePlayback(fileURL: fileURL, itemID: "server-a-file")
        default:
            playerA._startPCMStreamForTesting(id: "server-a-pcm")
        }
        let retainedItem = try #require(playerA.playingItemID)
        #expect(playerA.isPlaybackActiveForCapture)
        #expect(!playerB.hasActivePlayback)
        if paused.atStart { playerA.pause() }

        let access = MockVoiceInputSystemAccess()
        let captureOptions = VoiceInputAudioRoutePlanner.plan(availableInputs: [], preserveA2DPOutput: true).options
        access.onActivateAudioSession = {
            try? audioSession.setCategory(.playAndRecord, mode: .default, options: captureOptions)
            try? audioSession.setActive(true)
        }
        let session = MockVoiceSession()
        let provider = MockVoiceProvider(id: .appleModernSpeech, engine: .modernSpeech)
        provider.makeSessionHandler = { _, _ in session }
        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [provider]), systemAccess: access
        )
        manager.setEngineMode(.onDevice)
        // Quick Session targets server B while server A still owns playback.
        manager.setPlaybackInterrupter(playerB)
        try await manager.startRecording(keyboardLanguage: "en-US", source: "test")

        #expect(access.lastInAppPlaybackActive == !paused.atStart)
        #expect(VoiceInputSystemAccess.shouldPreserveA2DPOutput(
            hasA2DPOutput: true, externalAudioPlaying: false,
            inAppPlaybackActive: access.lastInAppPlaybackActive
        ) == !paused.atStart)
        #expect(playerA.playingItemID == retainedItem)
        #expect(!playerA.shouldAutoplayAudioMessage(itemID: "late-a", playbackBehavior: .playNow))
        #expect(!playerB.shouldAutoplayAudioMessage(itemID: "late-b", playbackBehavior: .playNow))
        // An unowned release must not remove B's capture protection.
        playerA.endCaptureInterruption()
        playerA.pause()
        playerA.resume()
        #expect(!playerA.isPaused)
        #expect(audioSession.category == .playAndRecord)
        #expect(audioSession.categoryOptions == captureOptions)
        if paused.atRelease { playerA.pause() }
        // Rebinding cannot strand the original selected player's suppression.
        manager.setPlaybackInterrupter(playerA)

        await manager.cancelRecording()

        #expect(playerA.playingItemID == retainedItem)
        #expect(!playerB.hasActivePlayback)
        #expect(playerA.shouldAutoplayAudioMessage(itemID: "after-a", playbackBehavior: .playNow))
        #expect(playerB.shouldAutoplayAudioMessage(itemID: "after-b", playbackBehavior: .playNow))
        #expect(audioSession.category == (paused.atRelease ? .playAndRecord : .playback))
        // Paused media cannot block notifyOthersOnDeactivation / external resume.
        #expect(access.deactivateAudioSessionCallCount == (paused.atRelease ? 1 : 0))
        if paused.atRelease {
            playerA.resume()
            #expect(audioSession.category == .playback)
            #expect(audioSession.categoryOptions.isEmpty)
        }
    }

    @Test func captureWithoutSelectedPlayerProtectsNewPlayersAndDoesNotRetainDepartedServers() async throws {
        let audioSession = AVAudioSession.sharedInstance()
        let previousCategory = audioSession.category
        let previousMode = audioSession.mode
        let previousOptions = audioSession.categoryOptions
        var playerA: AudioPlayerService? = AudioPlayerService()
        weak var departedPlayerA = playerA
        defer {
            playerA?.stop()
            try? audioSession.setCategory(previousCategory, mode: previousMode, options: previousOptions)
        }
        playerA?.toggleDataPlayback(data: Self.makeSilentWAV(frames: 240_000), itemID: "departing-server")
        #expect(playerA?.isPlaybackActiveForCapture == true)

        let access = MockVoiceInputSystemAccess()
        let session = MockVoiceSession()
        let provider = MockVoiceProvider(id: .appleModernSpeech, engine: .modernSpeech)
        provider.makeSessionHandler = { _, _ in session }
        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [provider]), systemAccess: access
        )
        manager.setEngineMode(.onDevice)
        try await manager.startRecording(keyboardLanguage: "en-US", source: "test")
        #expect(access.lastInAppPlaybackActive)
        let captureOptions: AVAudioSession.CategoryOptions = [.mixWithOthers, .duckOthers]
        try audioSession.setCategory(.playAndRecord, mode: .default, options: captureOptions)

        var playerB: AudioPlayerService? = AudioPlayerService()
        weak var departedPlayerB = playerB
        #expect(playerB?.shouldAutoplayAudioMessage(itemID: "new-server", playbackBehavior: .playNow) == false)
        playerB?.toggleDataPlayback(data: Self.makeSilentWAV(), itemID: "blocked-start")
        #expect(playerB?.hasActivePlayback == false)
        manager.setPlaybackInterrupter(playerB)
        playerB = nil
        #expect(departedPlayerB == nil)
        // Stop the real progress timer via ordinary pause before dropping the
        // server. The process playback pointer must not keep its player alive.
        playerA?.pause()
        playerA = nil
        #expect(departedPlayerA == nil)

        let survivingPlayer = AudioPlayerService()
        #expect(!survivingPlayer.shouldAutoplayAudioMessage(itemID: "still-blocked", playbackBehavior: .playNow))
        #expect(audioSession.category == .playAndRecord)
        await manager.cancelRecording()
        #expect(access.deactivateAudioSessionCallCount == 1)
        #expect(audioSession.category == .playAndRecord)
        #expect(survivingPlayer.shouldAutoplayAudioMessage(itemID: "released", playbackBehavior: .playNow))
    }

    @Test func captureClaimsAreIdentityScopedAndWeak() {
        let playerA = AudioPlayerService()
        let playerB = AudioPlayerService()
        playerA.beginCaptureInterruption()
        playerB.beginCaptureInterruption()
        playerA.endCaptureInterruption()
        playerA.endCaptureInterruption()
        #expect(!playerA.shouldAutoplayAudioMessage(itemID: "a", playbackBehavior: .playNow))
        playerB.endCaptureInterruption()
        #expect(playerA.shouldAutoplayAudioMessage(itemID: "a", playbackBehavior: .playNow))

        var departedPlayer: AudioPlayerService? = AudioPlayerService()
        weak var weakPlayer = departedPlayer
        departedPlayer?.beginCaptureInterruption()
        #expect(!playerA.shouldAutoplayAudioMessage(itemID: "a", playbackBehavior: .playNow))
        departedPlayer = nil
        #expect(weakPlayer == nil)
        #expect(playerA.shouldAutoplayAudioMessage(itemID: "a", playbackBehavior: .playNow))
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
