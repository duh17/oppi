import AVFoundation
import MediaPlayer
import Testing
@testable import Oppi

/// Calls, Siri and lost headphones pause audio without going through Oppi's
/// controls. These tests post the notifications AVAudioSession posts for them and
/// check that the controls, the real player and the lock screen agree.
@Suite("Audio player follows system pauses", .serialized)
@MainActor
struct AudioPlayerSystemPauseTests {
    @Test(arguments: [true, false])
    func interruptionPausesAndResumesOnlyWhenTheSystemAllows(shouldResume: Bool) async throws {
        let player = AudioPlayerService()
        let restore = Self.preserveAudioSession()
        defer { player.stop(); restore() }
        player.toggleDataPlayback(data: try Self.silentAAC(), itemID: "clip")
        #expect(player.isPlaybackActiveForCapture, "Fixture must actually play")

        Self.postInterruption(.began)

        #expect(await waitForMainActorCondition { player.isPaused })
        #expect(!player.isPlaybackActiveForCapture)
        #expect(Self.nowPlayingRate == 0)

        Self.postInterruption(.ended, options: shouldResume ? .shouldResume : [])

        if shouldResume {
            #expect(await waitForMainActorCondition { !player.isPaused })
            #expect(player.isPlaybackActiveForCapture)
            #expect(Self.nowPlayingRate == player.playbackRate)
        } else {
            #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(300)) {
                player.isPaused && !player.isPlaybackActiveForCapture
            })
            #expect(Self.nowPlayingRate == 0)
        }
        #expect(player.playingItemID == "clip")
    }

    @Test(arguments: ["listener", "route loss"])
    func interruptionNeverResumesAnItemPausedBeforeIt(pausedBy: String) async throws {
        let player = AudioPlayerService()
        let restore = Self.preserveAudioSession()
        defer { player.stop(); restore() }
        player.toggleDataPlayback(data: try Self.silentAAC(), itemID: "clip")
        if pausedBy == "listener" {
            player.pause()
        } else {
            Self.postRouteChange(.oldDeviceUnavailable)
        }
        #expect(await waitForMainActorCondition { player.isPaused })

        Self.postInterruption(.began)
        Self.postInterruption(.ended, options: .shouldResume)

        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(300)) {
            player.isPaused && !player.isPlaybackActiveForCapture
        })
    }

    /// Dictation switches categories and inputs while a reply plays; only a lost
    /// output (headphones unplugged, AirPods out) may pause it.
    @Test(arguments: [
        (AVAudioSession.RouteChangeReason.oldDeviceUnavailable, true),
        (.categoryChange, false),
        (.newDeviceAvailable, false),
        (.override, false),
    ])
    func onlyALostOutputPausesClipPlayback(reason: AVAudioSession.RouteChangeReason, pauses: Bool) async throws {
        let player = AudioPlayerService()
        let restore = Self.preserveAudioSession()
        defer { player.stop(); restore() }
        player.toggleDataPlayback(data: try Self.silentAAC(), itemID: "clip")
        #expect(player.isPlaybackActiveForCapture, "Fixture must actually play")

        Self.postRouteChange(reason)

        if pauses {
            #expect(await waitForMainActorCondition { player.isPaused })
            #expect(!player.isPlaybackActiveForCapture)
            #expect(Self.nowPlayingRate == 0)
        } else {
            #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(300)) {
                !player.isPaused && player.isPlaybackActiveForCapture
            })
            #expect(Self.nowPlayingRate == player.playbackRate)
        }
        #expect(player.playingItemID == "clip")
    }

    /// AVPlayer pauses itself for an interruption, often before the interruption
    /// notification arrives. The controls must follow it, and the end of that
    /// interruption must still resume. A self-pause from long before (a stall, an
    /// AirPlay receiver) is not that interruption's and stays paused.
    @Test(arguments: [false, true])
    func mediaPausedByTheSystemShowsPausedAndResumesAfterInterruption(selfPauseIsStale: Bool) async throws {
        let body = try Self.silentAAC()
        let server = try AuthenticatedRangeHTTPServer(body: body, token: "Bearer test", filename: "reply.m4a")
        let player = AudioPlayerService()
        let restore = Self.preserveAudioSession()
        defer { player.stop(); server.stop(); restore() }
        player.toggleMediaPlayback(source: Self.mediaSource(server.url), itemID: "media")
        let started = await waitForMainActorCondition(timeout: .seconds(10)) {
            player.playingItemID == "media" && player.isPlaybackActiveForCapture
                && Self.nowPlayingRate == player.playbackRate
        }
        #expect(started, "Fixture must actually play; ranges=\(server.snapshotRanges())")

        // The simulator cannot make the system pause AVPlayer (deactivating the
        // session leaves it playing), so pause the real player from outside the
        // service, as the system does on a device.
        try #require(player._mediaPlayerForTesting).pause()

        #expect(await waitForMainActorCondition { player.isPaused })
        #expect(!player.isPlaybackActiveForCapture)
        #expect(Self.nowPlayingRate == 0)
        if selfPauseIsStale {
            try await Task.sleep(for: .milliseconds(1_300))
        }

        Self.postInterruption(.began)
        Self.postInterruption(.ended, options: .shouldResume)

        if selfPauseIsStale {
            #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(300)) {
                player.isPaused && !player.isPlaybackActiveForCapture
            })
        } else {
            #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
                !player.isPaused && player.isPlaybackActiveForCapture
            })
        }
        #expect(player.playingItemID == "media")
    }

    /// AVPlayer stops at the end of an item just like a pause. Finishing must
    /// clear the item without ever showing it as paused.
    @Test func mediaPlayingToItsEndFinishesWithoutShowingPaused() async throws {
        let body = try Self.silentAAC(seconds: 1)
        let server = try AuthenticatedRangeHTTPServer(body: body, token: "Bearer test", filename: "short.m4a")
        let player = AudioPlayerService()
        let restore = Self.preserveAudioSession()
        let pausedWhilePlaying = PausedFlag()
        // The service posts this on every state and progress change, including
        // the pause path, so a paused flash cannot slip between polls.
        let observer = NotificationCenter.default.addObserver(
            forName: AudioPlayerService.stateDidChangeNotification,
            object: player,
            queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                if player.playingItemID == "media", player.isPaused { pausedWhilePlaying.value = true }
            }
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            player.stop(); server.stop(); restore()
        }
        player.toggleMediaPlayback(source: Self.mediaSource(server.url), itemID: "media")
        let started = await waitForMainActorCondition(timeout: .seconds(10)) {
            player.playingItemID == "media" && player.isPlaybackActiveForCapture
        }
        #expect(started, "Fixture must actually play; ranges=\(server.snapshotRanges())")

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { player.playingItemID == nil })
        #expect(!pausedWhilePlaying.value)
        #expect(!player.isPaused)
    }

    // MARK: - Helpers

    @MainActor private final class PausedFlag { var value = false }

    private static func mediaSource(_ url: URL) -> AuthenticatedMediaSource {
        AuthenticatedMediaSource(
            url: url,
            authorizationHeaderValue: "Bearer test",
            tlsCertFingerprint: nil,
            contentTypeHint: "audio/mp4",
            sourceFileExtension: "m4a"
        )
    }

    private static var nowPlayingRate: Float? {
        (MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?
            .floatValue
    }

    private static func postInterruption(
        _ type: AVAudioSession.InterruptionType,
        options: AVAudioSession.InterruptionOptions = []
    ) {
        var userInfo: [AnyHashable: Any] = [AVAudioSessionInterruptionTypeKey: type.rawValue]
        if type == .ended {
            userInfo[AVAudioSessionInterruptionOptionKey] = options.rawValue
        }
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: userInfo
        )
    }

    private static func postRouteChange(_ reason: AVAudioSession.RouteChangeReason) {
        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionRouteChangeReasonKey: reason.rawValue]
        )
    }

    private static func preserveAudioSession() -> () -> Void {
        let session = AVAudioSession.sharedInstance()
        let category = session.category
        let mode = session.mode
        let options = session.categoryOptions
        return { try? session.setCategory(category, mode: mode, options: options) }
    }

    /// Ten seconds of silent AAC in an M4A container, playable by both
    /// AVAudioPlayer and the authenticated AVPlayer path.
    private static func silentAAC(seconds: Double = 10) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("system-pause-\(UUID()).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let sampleRate = 44_100.0
        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: 1,
                ],
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            let frames = AVAudioFrameCount(sampleRate * seconds)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
            buffer.frameLength = frames
            try file.write(from: buffer)
        }
        return try Data(contentsOf: url)
    }
}
