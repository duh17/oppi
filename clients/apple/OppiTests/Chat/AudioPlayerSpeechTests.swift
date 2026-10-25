import AVFoundation
import Foundation
import Testing
@testable import Oppi

/// Serialized: one test holds the process-wide capture claim, which quiets every player.
@Suite("Read aloud playback", .serialized)
@MainActor
struct AudioPlayerSpeechTests {
    private static let playbackID = AudioPlayerService.speechPlaybackItemID(forMessageID: "m1")

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    @Test func playsTheServerStreamThenReturnsToIdle() async {
        let player = AudioPlayerService()
        defer { player.stop() }
        let (chunks, continuation) = AsyncThrowingStream<Data, Error>.makeStream()

        player.toggleSpeech(messageID: "m1") {
            SpeechAudioStream(sampleRate: 24_000, channels: 1, chunks: chunks)
        }
        #expect(player.loadingItemID == Self.playbackID)

        await waitUntil { player.playingItemID == Self.playbackID }
        #expect(player.playingItemID == Self.playbackID)
        #expect(player.loadingItemID == nil)

        // 0.1 s of silence in odd-sized pieces, as the network delivers it.
        let pcm = Data(count: 4_800)
        continuation.yield(pcm.prefix(1_001))
        continuation.yield(pcm.dropFirst(1_001))
        continuation.finish()

        await waitUntil { player.playingItemID == nil }
        #expect(player.playingItemID == nil)
        #expect(player.playbackFailure == nil)
    }

    @Test func aFailedReadSaysWhyAndReturnsToIdle() async {
        let player = AudioPlayerService()
        defer { player.stop() }

        player.toggleSpeech(messageID: "m1") {
            throw APIError.server(status: 404, message: "Read aloud is not configured on this server")
        }

        await waitUntil { player.loadingItemID == nil }
        #expect(player.loadingItemID == nil)
        #expect(player.playingItemID == nil)
        #expect(player.playbackFailure?.itemID == Self.playbackID)
    }

    @Test func aCaptureThatStartsWhileTheReadLoadsKeepsTheReadQuiet() async {
        let player = AudioPlayerService()
        defer { player.stop() }
        let captureOwner = NSObject()
        defer { AudioPlayerService.endProcessCaptureInterruption(owner: captureOwner) }
        // Left open through the checks below, so a read that wrongly started would still be playing.
        let (chunks, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        defer { continuation.finish() }
        let opened = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()

        player.toggleSpeech(messageID: "m1") {
            opened.continuation.yield()
            var releaseIterator = release.stream.makeAsyncIterator()
            await releaseIterator.next()
            return SpeechAudioStream(sampleRate: 24_000, channels: 1, chunks: chunks)
        }
        var openedIterator = opened.stream.makeAsyncIterator()
        await openedIterator.next()

        // A Live Voice call (or dictation) takes the audio session before the read's audio arrives.
        AudioPlayerService.beginProcessCaptureInterruption(owner: captureOwner)
        release.continuation.yield()

        await waitUntil { player.loadingItemID == nil }
        #expect(player.loadingItemID == nil)
        #expect(player.playingItemID == nil)
    }

    @Test func tappingAgainWhileLoadingStopsBeforeAudioStarts() async {
        let player = AudioPlayerService()
        defer { player.stop() }
        let (chunks, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let opened = AsyncStream<Void>.makeStream()

        player.toggleSpeech(messageID: "m1") {
            opened.continuation.yield()
            try await Task.sleep(for: .seconds(30))
            return SpeechAudioStream(sampleRate: 24_000, channels: 1, chunks: chunks)
        }
        var openedIterator = opened.stream.makeAsyncIterator()
        await openedIterator.next()

        player.toggleSpeech(messageID: "m1") {
            Issue.record("A second tap must stop, not start another read")
            return SpeechAudioStream(sampleRate: 24_000, channels: 1, chunks: chunks)
        }
        continuation.finish()

        #expect(player.loadingItemID == nil)
        #expect(player.playingItemID == nil)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(player.playingItemID == nil)
        #expect(player.playbackFailure == nil)
    }
}
