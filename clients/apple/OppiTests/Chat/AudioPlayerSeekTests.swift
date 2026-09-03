import Testing
@testable import Oppi

@Suite("Audio player seek")
struct AudioPlayerSeekTests {
    @Test(arguments: [
        (0.0, 60.0, 0.0),
        (0.5, 60.0, 30.0),
        (1.0, 60.0, 60.0),
        (-0.2, 60.0, 0.0),
        (1.5, 60.0, 60.0),
        (0.25, 10.0, 2.5),
    ])
    func fractionMapsToClampedTime(fraction: Double, duration: Double, expected: Double) {
        #expect(AudioPlaybackSeek.time(forFraction: fraction, duration: duration) == expected)
    }

    @Test func liveDurationIsNotSeekable() {
        #expect(AudioPlaybackSeek.isSeekable(duration: nil) == false)
        #expect(AudioPlaybackSeek.time(forFraction: 0.5, duration: nil) == nil)
        #expect(AudioPlaybackSeek.clampedTime(12, duration: nil) == nil)
    }

    @Test(arguments: [0.0, -4.0, Double.nan, Double.infinity, -Double.infinity])
    func invalidDurationIsNotSeekable(duration: Double) {
        #expect(AudioPlaybackSeek.isSeekable(duration: duration) == false)
        #expect(AudioPlaybackSeek.time(forFraction: 0.5, duration: duration) == nil)
        #expect(AudioPlaybackSeek.clampedTime(8, duration: duration) == nil)
    }

    @Test func finitePositiveDurationIsSeekable() {
        #expect(AudioPlaybackSeek.isSeekable(duration: 1))
        #expect(AudioPlaybackSeek.isSeekable(duration: 60))
    }

    @Test func clampedTimeStaysInsideDuration() {
        #expect(AudioPlaybackSeek.clampedTime(-3, duration: 60) == 0)
        #expect(AudioPlaybackSeek.clampedTime(12, duration: 60) == 12)
        #expect(AudioPlaybackSeek.clampedTime(90, duration: 60) == 60)
        #expect(AudioPlaybackSeek.clampedTime(.nan, duration: 60) == nil)
        #expect(AudioPlaybackSeek.clampedTime(.infinity, duration: 60) == nil)
    }

    @Test func nonFiniteFractionDoesNotSeek() {
        #expect(AudioPlaybackSeek.time(forFraction: .nan, duration: 60) == nil)
        #expect(AudioPlaybackSeek.time(forFraction: .infinity, duration: 60) == nil)
    }
}
