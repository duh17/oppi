import Foundation
import Testing
@testable import Oppi

@Suite("Live Voice barge-in detector")
struct LiveVoiceBargeInDetectorTests {
    private static let buffer: TimeInterval = 0.02
    private static let speech: Float = -25
    private static let reply: Float = -20

    /// Feeds `seconds` of mic audio in 20 ms buffers; returns the elapsed mic time of each fire.
    private static func feed(
        _ detector: inout LiveVoiceBargeInDetector,
        seconds: TimeInterval,
        mic: Float,
        playback: Float = reply
    ) -> [Int] {
        var fires: [Int] = []
        let count = Int((seconds / buffer).rounded())
        for index in 0..<count where detector.observe(micDBFS: mic, playbackDBFS: playback, duration: buffer) {
            fires.append((index + 1) * Int(buffer * 1_000))
        }
        return fires
    }

    private static func playing() -> LiveVoiceBargeInDetector {
        var detector = LiveVoiceBargeInDetector()
        detector.setPlaying(true)
        return detector
    }

    @Test("Sustained speech over the reply fires once, right after the start holdoff and the required speech")
    func sustainedSpeechFiresOnce() {
        var detector = Self.playing()
        let fires = Self.feed(&detector, seconds: 2, mic: Self.speech)
        // 300 ms holdoff, then 200 ms of speech.
        #expect(fires == [500])
        #expect(detector.stats.fires == 1)
    }

    @Test("The next reply re-arms the detector")
    func nextReplyRearms() {
        var detector = Self.playing()
        #expect(Self.feed(&detector, seconds: 1, mic: Self.speech).count == 1)
        detector.setPlaying(false)
        detector.setPlaying(true)
        #expect(Self.feed(&detector, seconds: 1, mic: Self.speech).count == 1)
        #expect(detector.stats.fires == 2)
    }

    @Test("Residual echo below the reply's level never fires, however loud in absolute terms")
    func echoLevelDoesNotFire() {
        var detector = Self.playing()
        let echo = Self.reply - LiveVoiceBargeInDetector.echoMarginDB - 1
        #expect(echo > LiveVoiceBargeInDetector.minimumSpeechDBFS)
        #expect(Self.feed(&detector, seconds: 3, mic: echo).isEmpty)
    }

    @Test("Quiet input never fires, even while the reply is between sentences")
    func quietInputDoesNotFire() {
        var detector = Self.playing()
        let quiet = LiveVoiceBargeInDetector.minimumSpeechDBFS - 1
        #expect(Self.feed(&detector, seconds: 3, mic: quiet, playback: LiveVoiceBargeInDetector.silenceDBFS).isEmpty)
    }

    @Test("Clicks shorter than the required speech, separated by quiet, never fire")
    func shortClicksDoNotFire() {
        var detector = Self.playing()
        _ = Self.feed(&detector, seconds: 0.4, mic: -60)
        for _ in 0..<20 {
            #expect(Self.feed(&detector, seconds: 0.1, mic: -5).isEmpty)
            #expect(Self.feed(&detector, seconds: 0.1, mic: -60).isEmpty)
        }
    }

    @Test("A syllable gap shorter than the allowed gap keeps the speech counted")
    func shortGapKeepsSpeech() {
        var detector = Self.playing()
        _ = Self.feed(&detector, seconds: 0.4, mic: -60)
        #expect(Self.feed(&detector, seconds: 0.12, mic: Self.speech).isEmpty)
        #expect(Self.feed(&detector, seconds: 0.04, mic: -60).isEmpty)
        #expect(Self.feed(&detector, seconds: 0.08, mic: Self.speech) == [80])
    }

    @Test("Speech in the first moments of a reply does not count")
    func holdoffIgnoresReplyStart() {
        var detector = Self.playing()
        #expect(Self.feed(&detector, seconds: 0.3, mic: Self.speech).isEmpty)
        // Holdoff speech is not carried over: 200 ms more are needed.
        #expect(Self.feed(&detector, seconds: 0.2, mic: Self.speech) == [200])
    }

    @Test("Muted calls never fire, and speech before a mute does not carry over it")
    func mutedNeverFires() {
        var detector = Self.playing()
        #expect(Self.feed(&detector, seconds: 0.48, mic: Self.speech).isEmpty)
        detector.setMuted(true)
        #expect(Self.feed(&detector, seconds: 2, mic: Self.speech).isEmpty)
        detector.setMuted(false)
        #expect(Self.feed(&detector, seconds: 0.2, mic: Self.speech) == [200])
    }

    @Test("No reply playing: the caller is just talking")
    func notPlayingNeverFires() {
        var detector = LiveVoiceBargeInDetector()
        #expect(Self.feed(&detector, seconds: 2, mic: Self.speech).isEmpty)
        detector.setPlaying(true)
        detector.setPlaying(false)
        #expect(Self.feed(&detector, seconds: 2, mic: Self.speech).isEmpty)
    }

    @Test("Mic level is the 16-bit PCM's RMS in dBFS")
    func pcmLevel() {
        var half = [Int16](repeating: Int16(16_384).littleEndian, count: 160)
        let data = Data(bytes: &half, count: half.count * 2)
        #expect(abs(LiveVoiceBargeInDetector.dbfs(pcm16: data) - (-6.02)) < 0.01)
        #expect(LiveVoiceBargeInDetector.dbfs(pcm16: Data(count: 320)) == LiveVoiceBargeInDetector.silenceDBFS)
        #expect(LiveVoiceBargeInDetector.duration(pcm16: data) == 0.01)
    }
}
