import Testing
@testable import Oppi

@Suite("Audio player skip")
@MainActor
struct AudioPlayerSkipTests {
    @Test func skipBackClampsToZero() {
        let player = AudioPlayerService()
        player._setPlaybackStateForTesting(playing: "clip-1", loading: nil)
        player._setProgressForTesting(currentTime: 10, duration: 60)

        player.skip(by: -15)

        #expect(player.currentTime == 0)
    }

    @Test func skipForwardClampsToDuration() {
        let player = AudioPlayerService()
        player._setPlaybackStateForTesting(playing: "clip-1", loading: nil)
        player._setProgressForTesting(currentTime: 50, duration: 60)

        player.skip(by: 15)

        #expect(player.currentTime == 60)
    }

    @Test func liveSkipForwardIsNoOp() {
        let player = AudioPlayerService()
        player._setPlaybackStateForTesting(playing: "live-1", loading: nil)
        player._setProgressForTesting(currentTime: 20, duration: nil)

        player.skip(by: 15)

        #expect(player.currentTime == 20)
    }

    @Test func liveSkipBackUsesElapsed() {
        let player = AudioPlayerService()
        player._setPlaybackStateForTesting(playing: "live-1", loading: nil)
        player._setProgressForTesting(currentTime: 20, duration: nil)

        player.skip(by: -15)

        #expect(player.currentTime == 5)
    }

    @Test func skipBackAtRestStaysAtZero() {
        let player = AudioPlayerService()
        player._setPlaybackStateForTesting(playing: "clip-1", loading: nil)
        player._setProgressForTesting(currentTime: 0, duration: 90)

        player.skip(by: -15)

        #expect(player.currentTime == 0)
    }

    @Test func liveSkipBackAtRestStaysAtZero() {
        let player = AudioPlayerService()
        player._setPlaybackStateForTesting(playing: "live-1", loading: nil)
        player._setProgressForTesting(currentTime: 0, duration: nil)

        player.skip(by: -15)

        #expect(player.currentTime == 0)
    }
}
