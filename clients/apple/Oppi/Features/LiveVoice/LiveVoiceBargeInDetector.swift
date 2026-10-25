import Accelerate
import Foundation

/// Hears the caller talking over the agent's reply on the phone, before the server's transcript
/// does, so playback stops at once instead of a recognition round trip later.
///
/// Input is the call's voice-processed mic (16 kHz PCM after Apple's echo cancellation) and the
/// reply's level as it leaves the player. Apple's voice-processing speech-activity listener
/// (`AVAudioInputNode.setMutedSpeechActivityEventListener`) reports speech only while the input
/// is muted, so it cannot hear the caller during a live call; this is a level detector instead.
///
/// Mic buffers arrive in whatever size the tap delivers (64–100 ms on devices), longer than a
/// pause between syllables, so each buffer is judged in `window`-long pieces: a short dip inside
/// a buffer is a gap, and a click inside a buffer is only as long as it is.
///
/// Echo guard: voice processing removes most of the reply from the mic, and what remains tracks
/// the reply's own loudness. A window counts as the caller only when it is loud in absolute
/// terms and not far below the reply playing at that moment. It fires after `requiredSpeech` of
/// such windows, never in the first `playbackStartHoldoff` of a reply (the level the player
/// reports is still the previous reply's), at most once per reply, and never while muted.
/// All timing is mic audio time, so it needs no clock.
///
/// The thresholds are conservative first guesses, to be tuned on devices from the
/// `Barge-in` log lines (levels at each fire, and the loudest mic level heard during replies).
struct LiveVoiceBargeInDetector {
    /// Level reported for digital silence.
    static let silenceDBFS: Float = -160
    /// Quietest voice-processed mic level, in dBFS RMS, that can be the caller. Residual echo
    /// and room noise after voice processing and its gain control sit well below this.
    static let minimumSpeechDBFS: Float = -40
    /// Residual echo after voice processing is expected at least this far below the reply's
    /// playback level. A window quieter than `playback - echoMarginDB` is taken for echo.
    static let echoMarginDB: Float = 15
    /// Caller speech needed before playback stops; longer than a tap, cough, or click.
    static let requiredSpeech: TimeInterval = 0.2
    /// A pause between syllables this short keeps the speech counted so far.
    static let maximumGap: TimeInterval = 0.06
    /// Mic audio ignored at the start of each reply.
    static let playbackStartHoldoff: TimeInterval = 0.3
    /// Each mic buffer is judged in pieces this long, well under `maximumGap`.
    static let window: TimeInterval = 0.02
    /// The call's capture rate (`LiveVoiceCaptureEngineHelper` converts the mic to it).
    static let sampleRate = 16_000

    /// One call's detection, for the log at call end.
    struct Stats: Equatable {
        var fires = 0
        /// Loudest mic window heard while armed during a reply, in dBFS.
        var peakMicDBFS = LiveVoiceBargeInDetector.silenceDBFS
    }

    private(set) var stats = Stats()
    private var playing = false
    private var muted = false
    private var firedThisReply = false
    // Mic time in whole microseconds, so summed window lengths meet the thresholds exactly.
    /// Mic audio heard since the current reply started.
    private var heardSinceReplyStart = 0
    private var speech = 0
    private var gap = 0
    /// One buffer's samples as Float, reused so judging a buffer allocates only when buffers grow.
    private var samples: [Float] = []

    /// The agent's reply started or stopped playing. A start arms detection for that reply.
    mutating func setPlaying(_ playing: Bool) {
        guard playing != self.playing else { return }
        self.playing = playing
        firedThisReply = false
        heardSinceReplyStart = 0
        clearSpeech()
    }

    /// A muted call sends no audio and must never cut the reply off.
    mutating func setMuted(_ muted: Bool) {
        self.muted = muted
        clearSpeech()
    }

    /// Feeds one mic buffer of 16-bit little-endian mono PCM at `sampleRate`; returns the level
    /// of the window that showed the caller talking over the reply, when playback should stop now.
    mutating func observe(pcm16 data: Data, playbackDBFS: Float) -> Float? {
        guard playing, !muted, !firedThisReply else { return nil }
        let count = data.count / 2
        guard count > 0 else { return nil }
        if samples.count < count { samples = [Float](repeating: 0, count: count) }
        data.withUnsafeBytes { raw in
            for index in 0..<count {
                samples[index] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self)))
            }
        }
        let windowSamples = Int(Self.window * Double(Self.sampleRate))
        var start = 0
        while start < count {
            let length = min(windowSamples, count - start)
            var rms: Float = 0
            samples.withUnsafeBufferPointer { buffer in
                vDSP_rmsqv(buffer.baseAddress! + start, 1, &rms, vDSP_Length(length))
            }
            let micDBFS = Self.dbfs(rms: rms / 32_768)
            let duration = TimeInterval(length) / TimeInterval(Self.sampleRate)
            if observe(micDBFS: micDBFS, playbackDBFS: playbackDBFS, duration: duration) {
                return micDBFS
            }
            start += length
        }
        return nil
    }

    /// Feeds one window of mic audio; true when the caller is talking over the reply.
    mutating func observe(micDBFS: Float, playbackDBFS: Float, duration: TimeInterval) -> Bool {
        guard playing, !muted, !firedThisReply, duration > 0 else { return false }
        let micros = Self.micros(duration)
        heardSinceReplyStart += micros
        guard heardSinceReplyStart > Self.micros(Self.playbackStartHoldoff) else { return false }
        stats.peakMicDBFS = max(stats.peakMicDBFS, micDBFS)
        let caller = micDBFS >= Self.minimumSpeechDBFS
            && micDBFS >= playbackDBFS - Self.echoMarginDB
        if caller {
            speech += micros
            gap = 0
        } else {
            gap += micros
            if gap > Self.micros(Self.maximumGap) { clearSpeech() }
        }
        guard speech >= Self.micros(Self.requiredSpeech) else { return false }
        firedThisReply = true
        stats.fires += 1
        clearSpeech()
        return true
    }

    private mutating func clearSpeech() {
        speech = 0
        gap = 0
    }

    private static func micros(_ seconds: TimeInterval) -> Int {
        Int((seconds * 1_000_000).rounded())
    }

    /// An RMS amplitude (1 is full scale) in dBFS.
    static func dbfs(rms: Float) -> Float {
        guard rms > 0, rms.isFinite else { return silenceDBFS }
        return max(silenceDBFS, 20 * log10(rms))
    }

    /// Duration of 16-bit mono PCM at the call's capture rate.
    static func duration(pcm16 data: Data) -> TimeInterval {
        TimeInterval(data.count / 2) / TimeInterval(sampleRate)
    }
}
