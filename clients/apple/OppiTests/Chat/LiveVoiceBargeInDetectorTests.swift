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

    // MARK: Real tap buffers

    /// 16 kHz PCM from `(milliseconds, amplitude)` segments, split into `bufferMs` buffers as the
    /// mic tap delivers it.
    private static func buffers(bufferMs: Int, _ segments: [(ms: Int, amplitude: Int16)]) -> [Data] {
        var samples: [Int16] = []
        for segment in segments {
            samples += [Int16](repeating: segment.amplitude.littleEndian, count: segment.ms * 16)
        }
        let size = bufferMs * 16
        return stride(from: 0, to: samples.count, by: size).map { start in
            var chunk = Array(samples[start..<min(start + size, samples.count)])
            return Data(bytes: &chunk, count: chunk.count * 2)
        }
    }

    /// Feeds PCM buffers; returns the elapsed mic time, in ms, at the end of each buffer that fired.
    private static func feed(_ detector: inout LiveVoiceBargeInDetector, _ buffers: [Data]) -> [Int] {
        var elapsed = 0
        var fires: [Int] = []
        for buffer in buffers {
            elapsed += buffer.count / 32
            if detector.observe(pcm16: buffer, playbackDBFS: reply) != nil { fires.append(elapsed) }
        }
        return fires
    }

    /// About -6 dBFS: plainly the caller.
    private static let loud: Int16 = 16_384
    /// About -66 dBFS: quiet room.
    private static let quiet: Int16 = 16

    @Test("Sustained speech fires in the buffer that completes the required speech", arguments: [(64, 512), (100, 500)])
    func realBufferSizesFire(bufferMs: Int, firesAtMs: Int) {
        var detector = Self.playing()
        let fires = Self.feed(&detector, Self.buffers(bufferMs: bufferMs, [(2_000, Self.loud)]))
        #expect(fires == [firesAtMs])
    }

    @Test("Syllable gaps inside long buffers keep the speech counted", arguments: [64, 100])
    func syllableGapsInsideBuffers(bufferMs: Int) {
        var detector = Self.playing()
        // 100 ms syllables with 40 ms pauses, after the holdoff.
        var segments: [(ms: Int, amplitude: Int16)] = [(320, Self.quiet)]
        for _ in 0..<4 { segments += [(100, Self.loud), (40, Self.quiet)] }
        let fires = Self.feed(&detector, Self.buffers(bufferMs: bufferMs, segments))
        #expect(fires.count == 1)
        // 200 ms of speech is complete about 320 + 100 + 40 + 100 ms in (a window straddling a
        // syllable edge counts whole), and reported at the end of that buffer.
        #expect((500..<(560 + bufferMs)).contains(fires.first ?? 0))
    }

    @Test("Full-scale clicks inside long buffers never fire", arguments: [64, 100])
    func clicksInsideBuffersDoNotFire(bufferMs: Int) {
        var detector = Self.playing()
        // A 20 ms click every 150 ms: judged per buffer, most buffers would hold a click and
        // read as loud; judged per window, each click is 20–40 ms followed by a real pause.
        var segments: [(ms: Int, amplitude: Int16)] = []
        for _ in 0..<20 { segments += [(20, Int16.max), (130, Self.quiet)] }
        #expect(Self.feed(&detector, Self.buffers(bufferMs: bufferMs, segments)).isEmpty)
    }

    @Test("Echo-level input in long buffers never fires", arguments: [64, 100])
    func echoInLongBuffersDoesNotFire(bufferMs: Int) {
        var detector = Self.playing()
        // About -36 dBFS: above the speech floor, below reply - margin (-35).
        let echo: Int16 = 520
        #expect(Self.feed(&detector, Self.buffers(bufferMs: bufferMs, [(3_000, echo)])).isEmpty)
    }

    @Test("The level reported at a fire is the window's RMS in dBFS")
    func reportedLevel() {
        var detector = Self.playing()
        var level: Float?
        for buffer in Self.buffers(bufferMs: 100, [(1_000, Self.loud)]) where level == nil {
            level = detector.observe(pcm16: buffer, playbackDBFS: Self.reply)
        }
        #expect(abs((level ?? 0) - (-6.02)) < 0.01)
        #expect(LiveVoiceBargeInDetector.duration(pcm16: Data(count: 2_048)) == 0.064)
    }
}
