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
