import AVFoundation
import Foundation
import Testing
@testable import Oppi

@Suite("Authenticated media loader size and duration boundaries", .serialized)
struct AuthenticatedMediaLoaderBoundaryTests {
    @MainActor
    @Test("authenticated loader play() advances on H.264 larger than 1MiB and crosses the chunk boundary")
    func playAdvancesAcrossOneMegabyteChunkBoundary() async throws {
        let artifact = try await GeneratedH264Fixture.makeLargerThan(
            Int(AuthenticatedMediaRequestedRange.maxChunkLength)
        )
        defer { try? FileManager.default.removeItem(at: artifact.url) }
        #expect(
            artifact.byteSize > Int(AuthenticatedMediaRequestedRange.maxChunkLength),
            "generated fixture was \(artifact.byteSize) bytes, duration=\(artifact.duration)s frames=\(artifact.frameCount)"
        )

        let auth = AuthorizationProbe(token: "Bearer large-h264")
        let server = try AuthenticatedRangeHTTPServer(
            body: artifact.data,
            token: "Bearer large-h264",
            filename: "larger-than-1mib.mp4"
        )
        defer { server.stop() }

        let session = AuthenticatedMediaPlaybackSession(
            source: mediaSource(url: server.url, authorizationProvider: auth.provider)
        )
        defer { session.teardown() }
        let player = session.player

        let ready = await waitForMainActorCondition(timeout: .seconds(12)) {
            player.currentItem?.status == .readyToPlay
        }
        #expect(
            ready,
            "item not ready size=\(artifact.byteSize) duration=\(artifact.duration) ranges=\(server.snapshotRanges())"
        )

        let start = finiteSeconds(player.currentTime())
        player.play()
        let advanced = await waitForMainActorCondition(timeout: .seconds(8)) {
            finiteSeconds(player.currentTime()) > start + 0.15
        }
        let ranges = server.snapshotParsedRanges()
        let gets = ranges.filter { $0.method == "GET" }
        let spans = server.snapshotRanges()
        print(
            "LARGE_CLIP size=\(artifact.byteSize) duration=\(artifact.duration) frames=\(artifact.frameCount) auth=\(auth.count) gets=\(spans)"
        )
        #expect(
            advanced,
            """
            currentTime did not advance on \(artifact.byteSize)-byte \(artifact.duration)s H.264
            ranges=\(spans)
            """
        )
        #expect(player.currentItem != nil, "item dropped after play on \(artifact.byteSize)-byte file")
        #expect(
            gets.allSatisfy { $0.servedBytes <= Int(AuthenticatedMediaRequestedRange.maxChunkLength) },
            "a GET exceeded the 1MiB per-request cap: \(gets)"
        )
        let starts = gets.compactMap(\.start)
        let crossedCap = starts.contains { $0 < AuthenticatedMediaRequestedRange.maxChunkLength }
            && starts.contains { $0 >= AuthenticatedMediaRequestedRange.maxChunkLength }
        #expect(
            crossedCap,
            "no GET started at/after 1MiB, so continuation was not proved. size=\(artifact.byteSize) ranges=\(spans)"
        )
        #expect(
            auth.count >= 2,
            "continuation did not refresh auth; count=\(auth.count) ranges=\(spans)"
        )
    }

    @MainActor
    @Test("seek to a late timestamp on long-duration H.264 advances without a duration gate")
    func seekToLateTimestampOnHourLengthClipAdvances() async throws {
        let artifact = try await GeneratedH264Fixture.makeLongDuration(duration: 3_600)
        defer { try? FileManager.default.removeItem(at: artifact.url) }
        #expect(artifact.duration >= 3_500, "generated duration was \(artifact.duration)s size=\(artifact.byteSize)")

        let server = try AuthenticatedRangeHTTPServer(
            body: artifact.data,
            token: "Bearer long-h264",
            filename: "hour-length.mp4"
        )
        defer { server.stop() }

        let session = AuthenticatedMediaPlaybackSession(source: mediaSource(url: server.url))
        defer { session.teardown() }
        let player = session.player
        let ready = await waitForMainActorCondition(timeout: .seconds(12)) {
            player.currentItem?.status == .readyToPlay
        }
        #expect(ready, "long clip not ready duration=\(artifact.duration) size=\(artifact.byteSize)")

        let seekTarget = CMTime(seconds: 3_500, preferredTimescale: 600)
        await player.seek(
            to: seekTarget,
            toleranceBefore: .zero,
            toleranceAfter: CMTime(seconds: 2, preferredTimescale: 600)
        )
        let afterSeek = finiteSeconds(player.currentTime())
        #expect(
            afterSeek > 3_000,
            "seek did not land near 3500s; time=\(afterSeek) duration=\(artifact.duration)s size=\(artifact.byteSize)"
        )

        player.play()
        let advanced = await waitForMainActorCondition(timeout: .seconds(8)) {
            finiteSeconds(player.currentTime()) > afterSeek + 0.15
        }
        let spans = server.snapshotRanges()
        print(
            "LONG_CLIP size=\(artifact.byteSize) duration=\(artifact.duration) seek=\(afterSeek) target=3500 gets=\(spans)"
        )
        #expect(
            advanced,
            "play() after seek to \(afterSeek)s did not advance duration=\(artifact.duration)s size=\(artifact.byteSize) ranges=\(spans)"
        )
        #expect(player.currentItem != nil)
    }

    @MainActor
    @Test("authenticated loader rejects redirects instead of following them")
    func authenticatedLoaderRejectsRedirect() async throws {
        let body = try Data(contentsOf: knownGoodH264URL())
        let server = try AuthenticatedRangeHTTPServer(
            body: body,
            token: "Bearer native-play",
            redirectLocation: "http://127.0.0.1/forbidden.mp4"
        )
        defer { server.stop() }

        let session = AuthenticatedMediaPlaybackSession(
            source: mediaSource(url: server.url, token: "Bearer native-play")
        )
        defer { session.teardown() }
        let player = session.player
        let failed = await waitForMainActorCondition(timeout: .seconds(8)) {
            player.currentItem?.status == .failed
        }
        let start = finiteSeconds(player.currentTime())
        player.play()
        let advanced = await waitForMainActorCondition(timeout: .seconds(1)) {
            finiteSeconds(player.currentTime()) > start + 0.15
        }
        #expect(failed || !advanced, "redirect was followed; ranges=\(server.snapshotRanges())")
        #expect(!advanced, "playhead advanced after a rejected redirect")
    }

    @MainActor
    @Test("debug playback probe carries stable model and player identity")
    func debugPlaybackProbeCarriesStableIdentity() {
        let model = AuthenticatedMediaPlayerModel()
        let player = model.debugInstallStandalonePlayerForTesting()
        let probe = model.debugPlaybackProbeForTesting
        let mid = probe.split(separator: " ").first { $0.hasPrefix("mid=") }
        let pid = probe.split(separator: " ").first { $0.hasPrefix("pid=") }
        #expect(mid != nil && mid != "mid=")
        #expect(pid != nil && pid != "pid=nil")
        #expect(probe.contains("fs=0"))
        model.setFullScreen(true)
        let fullScreen = model.debugPlaybackProbeForTesting
        #expect(fullScreen.contains("fs=1"))
        if let mid {
            #expect(fullScreen.contains(String(mid)))
        }
        if let pid {
            #expect(fullScreen.contains(String(pid)))
        }
        #expect(model.player === player)
    }

    @MainActor
    @Test("cancelling during authorization does not issue a GET")
    func cancellingDuringAuthorizationDoesNotIssueGet() async throws {
        let body = try Data(contentsOf: knownGoodH264URL())
        let server = try AuthenticatedRangeHTTPServer(body: body, token: "Bearer cancel-auth")
        defer { server.stop() }

        let gate = AuthorizationGate(token: "Bearer cancel-auth")
        let session = AuthenticatedMediaPlaybackSession(
            source: mediaSource(url: server.url, authorizationProvider: gate.provider)
        )

        let started = await waitForMainActorCondition(timeout: .seconds(5)) {
            gate.hasStarted
        }
        #expect(started, "loader never asked for authorization")
        session.teardown()
        gate.release()

        let stayedEmpty = await waitForMainActorConditionToStayTrue(for: .milliseconds(400)) {
            server.snapshotRanges().isEmpty
        }
        #expect(
            stayedEmpty,
            "GET issued after cancel during authorization: \(server.snapshotRanges())"
        )
    }

    @MainActor
    @Test("cancelling during a later authorization does not start another GET")
    func cancellingDuringLaterAuthorizationDoesNotStartAnotherGet() async throws {
        let body = try Data(contentsOf: knownGoodH264URL())
        let gate = AuthorizationGate(token: "Bearer cancel-continue", blockAfterCount: 2)
        let server = try AuthenticatedRangeHTTPServer(
            body: body,
            token: "Bearer cancel-continue"
        )
        defer { server.stop() }

        let session = AuthenticatedMediaPlaybackSession(
            source: mediaSource(url: server.url, authorizationProvider: gate.provider)
        )

        let firstGet = await waitForMainActorCondition(timeout: .seconds(8)) {
            !server.snapshotRanges().isEmpty
        }
        #expect(firstGet, "first GET never started ranges=\(server.snapshotRanges())")
        let getsBeforeCancel = server.snapshotRanges().count

        let gated = await waitForMainActorCondition(timeout: .seconds(8)) {
            gate.isBlocked
        }
        #expect(gated, "later authorization never blocked count=\(gate.count)")
        session.teardown()
        gate.release()

        let noExtra = await waitForMainActorConditionToStayTrue(for: .milliseconds(400)) {
            server.snapshotRanges().count == getsBeforeCancel
        }
        #expect(
            noExtra,
            "GET started after cancel during later authorization. before=\(getsBeforeCancel) after=\(server.snapshotRanges())"
        )
    }
}

@MainActor
private func mediaSource(
    url: URL,
    token: String = "Bearer long-h264",
    authorizationProvider: (@Sendable () async throws -> String)? = nil
) -> AuthenticatedMediaSource {
    if let authorizationProvider {
        return AuthenticatedMediaSource(
            url: url,
            authorizationProvider: authorizationProvider,
            tlsCertFingerprint: nil,
            contentTypeHint: "video/mp4",
            sourceFileExtension: "mp4"
        )
    }
    return AuthenticatedMediaSource(
        url: url,
        authorizationHeaderValue: token,
        tlsCertFingerprint: nil,
        contentTypeHint: "video/mp4",
        sourceFileExtension: "mp4"
    )
}

private func finiteSeconds(_ time: CMTime) -> TimeInterval {
    let seconds = time.seconds
    return seconds.isFinite ? seconds : 0
}

private func knownGoodH264URL() throws -> URL {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/known-good-h264.mp4")
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw CocoaError(.fileNoSuchFile)
    }
    return url
}

private final class AuthorizationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var countStorage = 0
    private let token: String

    init(token: String) {
        self.token = token
    }

    var count: Int {
        lock.withLock { countStorage }
    }

    var provider: @Sendable () async throws -> String {
        { [self] in
            self.lock.withLock {
                self.countStorage += 1
            }
            return self.token
        }
    }
}

private final class AuthorizationGate: @unchecked Sendable {
    private let lock = NSLock()
    private let token: String
    private let blockAfterCount: Int
    private var countStorage = 0
    private var started = false
    private var blocked = false
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(token: String, blockAfterCount: Int = 1) {
        self.token = token
        self.blockAfterCount = blockAfterCount
    }

    var hasStarted: Bool { lock.withLock { started } }
    var isBlocked: Bool { lock.withLock { blocked } }
    var count: Int { lock.withLock { countStorage } }

    var provider: @Sendable () async throws -> String {
        { [self] in
            await self.nextToken()
        }
    }

    private func nextToken() async -> String {
        let shouldBlock = lock.withLock { () -> Bool in
            countStorage += 1
            started = true
            return countStorage >= blockAfterCount && !released
        }
        if shouldBlock {
            await withCheckedContinuation { continuation in
                lock.lock()
                if released {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                blocked = true
                releaseWaiters.append(continuation)
                lock.unlock()
            }
            lock.withLock { blocked = false }
        }
        return token
    }

    func release() {
        lock.lock()
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        blocked = false
        lock.unlock()
        waiters.forEach { $0.resume() }
    }
}
