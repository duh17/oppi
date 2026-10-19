import AVFoundation
import Foundation
import Testing
@testable import Oppi

@Suite("LiveVoiceAudioOwner")
@MainActor
struct LiveVoiceAudioOwnerTests {
    @Test("A valid output format is used as-is")
    func resolvedHardwareFormatKeepsValidOutput() throws {
        let output = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let input = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let resolved = try LiveVoiceCaptureEngineHelper.resolvedHardwareFormat(
            outputFormat: output,
            inputFormat: input
        )
        #expect(resolved.sampleRate == 48_000)
        #expect(resolved.channelCount == 1)
    }

    @Test("Mute stops capture so no more PCM is forwarded")
    func muteStopsCapture() async throws {
        let engine = FakeLiveVoiceCaptureEngine()
        let owner = LiveVoiceAudioOwner(engine: engine)
        var forwarded: [Data] = []
        owner.onPCM = { forwarded.append($0) }

        try await owner.start()
        #expect(owner.isCapturing)
        #expect(engine.isCapturing)
        #expect(!owner.openedDictationStream)

        engine.emit(Data([1, 2]))
        await waitUntil { forwarded == [Data([1, 2])] }

        owner.setMuted(true)
        #expect(!owner.isCapturing)
        #expect(!engine.isCapturing)

        engine.emit(Data([3, 4]))
        await Task.yield()
        #expect(forwarded == [Data([1, 2])])
    }

    @Test("Unmute resumes capture on the same owner")
    func unmuteResumesCapture() async throws {
        let engine = FakeLiveVoiceCaptureEngine()
        let owner = LiveVoiceAudioOwner(engine: engine)
        var forwarded: [Data] = []
        owner.onPCM = { forwarded.append($0) }

        try await owner.start()
        owner.setMuted(true)
        owner.setMuted(false)

        #expect(owner.isCapturing)
        engine.emit(Data([5]))
        await waitUntil { forwarded == [Data([5])] }
    }

    @Test("Owner never opens the dictation stream")
    func neverOpensDictationStream() {
        let owner = LiveVoiceAudioOwner(engine: FakeLiveVoiceCaptureEngine())
        #expect(!owner.openedDictationStream)
    }

    @Test("Inbound PCM plays even while capture is muted")
    func inboundPcmPlaysWhileMuted() async throws {
        let engine = FakeLiveVoiceCaptureEngine()
        let playback = FakeLiveVoicePlaybackEngine()
        let owner = LiveVoiceAudioOwner(engine: engine, playback: playback)
        try await owner.start()
        owner.setMuted(true)
        owner.play(Data([9, 8]))
        #expect(playback.played == [Data([9, 8])])
        #expect(!owner.isCapturing)
    }

    @Test("stopPlayback flushes the current generation")
    func stopPlaybackFlushesGeneration() {
        let playback = FakeLiveVoicePlaybackEngine()
        let owner = LiveVoiceAudioOwner(engine: FakeLiveVoiceCaptureEngine(), playback: playback)
        owner.play(Data([1]))
        owner.stopPlayback()
        owner.play(Data([2]))
        #expect(playback.played == [Data([1]), Data([2])])
        #expect(playback.stops == 1)
    }
}

@Suite("LiveVoicePlaybackScheduler")
struct LiveVoicePlaybackSchedulerTests {
    /// 60 ms of 24 kHz audio, about one network chunk.
    private let chunk = 1_440

    @Test("A reply waits for 180 ms of audio, then plays continuously")
    func primesBeforePlaying() {
        var scheduler = LiveVoicePlaybackScheduler()
        do { let decision = scheduler.receive(frames: chunk, at: 0); #expect(decision == .hold) }
        do { let decision = scheduler.receive(frames: chunk, at: 0.05); #expect(decision == .hold) }
        // Held audio is not speech yet: the call still shows Listening.
        #expect(!scheduler.isPlaying)
        do { let decision = scheduler.receive(frames: chunk, at: 0.1); #expect(decision == .startWithHeld) }
        #expect(scheduler.isPlaying)
        do { let decision = scheduler.receive(frames: chunk, at: 0.15); #expect(decision == .schedule) }
        do { let started = scheduler.primeTimedOut(); #expect(!started) }
    }

    @Test("A short reply starts when the prime wait runs out")
    func shortReplyStartsOnTimeout() {
        var scheduler = LiveVoicePlaybackScheduler()
        do { let decision = scheduler.receive(frames: chunk, at: 0); #expect(decision == .hold) }
        do { let started = scheduler.primeTimedOut(); #expect(started) }
        do { let decision = scheduler.receive(frames: chunk, at: 0.05); #expect(decision == .schedule) }
    }

    @Test("A queue that runs dry mid-reply counts an underrun and re-primes")
    func countsUnderrunAndReprimes() {
        var scheduler = LiveVoicePlaybackScheduler()
        for i in 0..<3 { _ = scheduler.receive(frames: chunk, at: Double(i) * 0.01) }
        scheduler.played(frames: chunk * 2, at: 0.15)
        #expect(scheduler.isPlaying)
        scheduler.played(frames: chunk, at: 0.2)
        #expect(!scheduler.isPlaying)
        do { let decision = scheduler.receive(frames: chunk, at: 0.5); #expect(decision == .hold) }
        #expect(scheduler.stats.underruns == 1)
        #expect(scheduler.stats.maxGapMs == 480)

        // A new reply after a pause is not an underrun, and its gap is not jitter.
        var fresh = LiveVoicePlaybackScheduler()
        _ = fresh.receive(frames: chunk * 3, at: 0)
        fresh.played(frames: chunk * 3, at: 0.2)
        _ = fresh.receive(frames: chunk, at: 3)
        #expect(fresh.stats.underruns == 0)
        #expect(fresh.stats.maxGapMs == 0)
    }

    @Test("Talking over a reply drops its queued audio and starts the next reply primed")
    func flushDropsQueue() {
        var scheduler = LiveVoicePlaybackScheduler()
        _ = scheduler.receive(frames: chunk * 3, at: 0)
        scheduler.flush(userTalked: true)
        #expect(!scheduler.isPlaying)
        scheduler.flush(userTalked: true)
        #expect(scheduler.stats.flushes == 1)
        _ = scheduler.receive(frames: chunk * 3, at: 0.4)
        scheduler.flush(userTalked: false) // an audio restart, not the user
        #expect(scheduler.stats.flushes == 1)
        do { let decision = scheduler.receive(frames: chunk, at: 0.5); #expect(decision == .hold) }
        #expect(scheduler.stats.underruns == 0)
    }
}

@MainActor
private final class FakeLiveVoicePlaybackEngine: LiveVoicePlaybackEngine {
    var onPlaybackActiveChange: (@MainActor (Bool) -> Void)?
    private(set) var played: [Data] = []
    private(set) var stops = 0
    private(set) var teardowns = 0

    func play(_ pcm: Data) {
        played.append(pcm)
    }

    func stopPlayback() {
        stops += 1
    }

    func teardown() {
        teardowns += 1
    }
}

@MainActor
private final class FakeLiveVoiceCaptureEngine: LiveVoiceCaptureEngine {
    private(set) var isCapturing = false
    private var handler: (@Sendable (Data) -> Void)?

    func start(onPCM: @escaping @Sendable (Data) -> Void) throws {
        handler = onPCM
        isCapturing = true
    }

    func stopCapture() {
        handler = nil
        isCapturing = false
    }

    func emit(_ data: Data) {
        handler?(data)
    }
}

private func waitUntil(
    timeoutMs: Int = 500,
    _ predicate: @escaping @MainActor () -> Bool
) async {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1_000)
    while Date() < deadline {
        if await MainActor.run(body: predicate) {
            return
        }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(10))
    }
}
