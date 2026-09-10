import AVFoundation
import Foundation
import Testing
@testable import Oppi

@Suite("Authenticated media playback audio route and mute", .serialized)
@MainActor
struct AuthenticatedMediaPlaybackAudioTests {
    @Test("playback audio session replaces leftover dictation HFP instead of mixing with it")
    func playbackCategoryReplacesDictationRoute() throws {
        #expect(MediaPlaybackAudioSession.category == .playback)
        #expect(MediaPlaybackAudioSession.mode == .default)
        #expect(!MediaPlaybackAudioSession.options.contains(.allowBluetoothHFP))
        #expect(MediaPlaybackAudioSession.needsPlaybackCategory(.playAndRecord))
        #expect(MediaPlaybackAudioSession.needsPlaybackCategory(.record))
        #expect(!MediaPlaybackAudioSession.needsPlaybackCategory(.playback))

        var assignedCategory: AVAudioSession.Category?
        var assignedMode: AVAudioSession.Mode?
        var assignedAllowsHFP = false
        try MediaPlaybackAudioSession.prepare(currentCategory: .playAndRecord) { category, mode, options in
            assignedCategory = category
            assignedMode = mode
            assignedAllowsHFP = options.contains(.allowBluetoothHFP)
        }
        #expect(assignedCategory == .playback)
        #expect(assignedMode == .default)
        #expect(!assignedAllowsHFP)

        var didReplacePlayback = false
        try MediaPlaybackAudioSession.prepare(currentCategory: .playback) { _, _, _ in
            didReplacePlayback = true
        }
        #expect(!didReplacePlayback)
    }

    @Test("mounting an authenticated player does not acquire the audio session")
    func mountingDoesNotReplaceCaptureCategory() throws {
        let audio = AVAudioSession.sharedInstance()
        let previousCategory = audio.category
        let previousMode = audio.mode
        let previousOptions = audio.categoryOptions
        defer { try? audio.setCategory(previousCategory, mode: previousMode, options: previousOptions) }
        try audio.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP])
        let session = AuthenticatedMediaPlaybackSession(source: dummyMediaSource())
        defer { session.teardown() }
        #expect(audio.category == .playAndRecord)
        #expect(audio.categoryOptions.contains(.allowBluetoothHFP))
    }

    @Test("playback preparation cannot take the route while dictation is active")
    func playbackPreparationRespectsCaptureOwner() throws {
        let manager = VoiceInputManager.shared
        let previousState = manager.state
        let audio = AVAudioSession.sharedInstance()
        let previousCategory = audio.category
        let previousMode = audio.mode
        let previousOptions = audio.categoryOptions
        defer {
            manager._testState = previousState
            try? audio.setCategory(previousCategory, mode: previousMode, options: previousOptions)
        }
        for state: VoiceInputManager.State in [.preparingModel, .recording, .processing] {
            manager._testState = state
            try audio.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP])
            #expect(!MediaPlaybackAudioSession.prepareSharedSession())
            #expect(audio.category == .playAndRecord)
        }
        manager._testState = .idle
        #expect(MediaPlaybackAudioSession.prepareSharedSession())
        #expect(audio.category == .playback)
    }

    @Test("capture acquisition pauses progressing authenticated media and blocks native play admission")
    func capturePausesProgressAndRejectsPlayBeforeRateChanges() async throws {
        let manager = VoiceInputManager.shared
        let previousState = manager.state
        let audio = AVAudioSession.sharedInstance()
        let previousCategory = audio.category
        let previousMode = audio.mode
        let previousOptions = audio.categoryOptions
        let session = AuthenticatedMediaPlaybackSession(source: dummyMediaSource())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("capture-media-\(UUID()).wav")
        defer {
            session.teardown()
            manager._testState = previousState
            try? audio.setCategory(previousCategory, mode: previousMode, options: previousOptions)
            try? FileManager.default.removeItem(at: url)
        }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160_000))
        buffer.frameLength = buffer.frameCapacity
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        manager._testState = .idle
        let player = session.player
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.play()
        let progressed = await waitUntil(timeout: .seconds(2)) {
            player.timeControlStatus == .playing && player.currentTime().seconds > 0.05
        }
        #expect(progressed, "Fixture must actually play before capture begins")
        manager._testState = .preparingModel
        #expect(player.rate == 0, "Acquisition must pause existing inline/fullscreen/PiP playback synchronously")
        #expect(player.timeControlStatus == .paused)
        try audio.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP])
        for state: VoiceInputManager.State in [.preparingModel, .recording, .processing] {
            manager._testState = state
            player.play()
            #expect(player.rate == 0, "play() must be rejected before AVPlayer starts")
            player.playImmediately(atRate: 1)
            #expect(player.rate == 0)
            player.rate = 1
            #expect(player.rate == 0, "Native transport rate requests must also be gated")
            player.setRate(1, time: .invalid, atHostTime: .invalid)
            #expect(player.rate == 0)
            #expect(audio.category == .playAndRecord)
        }
        let pausedTime = player.currentTime()
        manager._testState = .idle
        #expect(player.rate == 0, "Capture release must not auto-resume media")
        player.play()
        let resumed = await waitUntil(timeout: .seconds(2)) {
            player.timeControlStatus == .playing && player.currentTime() > pausedTime + CMTime(seconds: 0.05, preferredTimescale: 600)
        }
        #expect(resumed, "Explicit play should progress again after capture releases ownership")
        #expect(audio.category == .playback)
    }

    @Test("muted output is silent and unmute restores the previous volume")
    func mutePolicyZerosVolumeAndRestoresPrevious() {
        let muted = MediaPlaybackMutePolicy.appliedVolume(
            isMuted: true,
            currentVolume: 0.8,
            lastUnmutedVolume: 1
        )
        #expect(muted.volume == 0)
        #expect(abs(muted.lastUnmutedVolume - 0.8) < 0.000_1)

        let unmuted = MediaPlaybackMutePolicy.appliedVolume(
            isMuted: false,
            currentVolume: 0,
            lastUnmutedVolume: 0.8
        )
        #expect(abs(unmuted.volume - 0.8) < 0.000_1)
        #expect(abs(unmuted.lastUnmutedVolume - 0.8) < 0.000_1)

        let alreadyRestored = MediaPlaybackMutePolicy.appliedVolume(
            isMuted: false,
            currentVolume: 0.4,
            lastUnmutedVolume: 0.8
        )
        #expect(abs(alreadyRestored.volume - 0.4) < 0.000_1)
    }

    @Test("muting the authenticated player also zeros volume so AirPods cannot keep playing")
    func mutedPlayerZerosVolume() async {
        let session = AuthenticatedMediaPlaybackSession(source: dummyMediaSource())
        defer { session.teardown() }
        let player = session.player
        #expect(!player.isMuted)
        #expect(player.volume > 0)

        player.isMuted = true
        let silenced = await waitUntil(timeout: .seconds(1)) {
            player.isMuted && player.volume == 0
        }
        #expect(silenced, "muted player still has volume=\(player.volume)")

        player.isMuted = false
        let restored = await waitUntil(timeout: .seconds(1)) {
            !player.isMuted && player.volume > 0
        }
        #expect(restored, "unmute left volume=\(player.volume)")
    }
}

private func dummyMediaSource() -> AuthenticatedMediaSource {
    AuthenticatedMediaSource(
        url: URL(fileURLWithPath: "/tmp/oppi-muted-inline-video.mp4"),
        authorizationHeaderValue: "Bearer test",
        tlsCertFingerprint: nil,
        contentTypeHint: "video/mp4",
        sourceFileExtension: "mp4"
    )
}

@MainActor
private func waitUntil(timeout: Duration, _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}
