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

@MainActor
private final class FakeLiveVoicePlaybackEngine: LiveVoicePlaybackEngine {
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
