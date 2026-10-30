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
            source: try mediaSource(url: server.url, authorizationProvider: auth.provider)
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

        let session = AuthenticatedMediaPlaybackSession(source: try mediaSource(url: server.url))
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
        let body = try Data(contentsOf: try knownGoodH264URL())
        let server = try AuthenticatedRangeHTTPServer(
            body: body,
            token: "Bearer native-play",
            redirectLocation: "http://127.0.0.1/forbidden.mp4"
        )
        defer { server.stop() }

        let session = AuthenticatedMediaPlaybackSession(
            source: try mediaSource(url: server.url, token: "Bearer native-play")
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
        let body = try Data(contentsOf: try knownGoodH264URL())
        let server = try AuthenticatedRangeHTTPServer(body: body, token: "Bearer cancel-auth")
        defer { server.stop() }

        let gate = AuthorizationGate(token: "Bearer cancel-auth")
        let session = AuthenticatedMediaPlaybackSession(
            source: try mediaSource(url: server.url, authorizationProvider: gate.provider)
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
        let body = try Data(contentsOf: try knownGoodH264URL())
        let gate = AuthorizationGate(token: "Bearer cancel-continue", blockAfterCount: 2)
        let server = try AuthenticatedRangeHTTPServer(
            body: body,
            token: "Bearer cancel-continue"
        )
        defer { server.stop() }

        let session = AuthenticatedMediaPlaybackSession(
            source: try mediaSource(url: server.url, authorizationProvider: gate.provider)
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

    @MainActor
    @Test("teardown landing between authorization and task creation fails the request without a GET")
    func teardownAfterAuthorizationBeforeTaskCreationFailsRequest() async throws {
        let body = try Data(contentsOf: try knownGoodH264URL())
        let server = try AuthenticatedRangeHTTPServer(body: body, token: "Bearer race-first")
        defer { server.stop() }

        let gate = AuthorizationGate(token: "Bearer race-first")
        let session = AuthenticatedMediaPlaybackSession(
            source: try mediaSource(url: server.url, authorizationProvider: gate.provider)
        )
        defer { session.teardown() }

        let started = await waitForMainActorCondition(timeout: .seconds(5)) { gate.hasStarted }
        #expect(started, "loader never asked for authorization")

        // Teardown arrives after the authorization await and the abandonment
        // check, right where the loader creates its URLSession task. Creating
        // a task on the invalidated session raises NSGenericException.
        let fired = HookFlag()
        session.debugSetBeforeDataTaskCreationHook { _, cancelLoader in
            if fired.claim() { _ = cancelLoader() }
        }
        gate.release()

        let failed = await waitForMainActorCondition(timeout: .seconds(8)) {
            session.player.currentItem?.status == .failed
        }
        #expect(fired.isClaimed, "hook never ran, so the race was not exercised")
        #expect(failed, "request was not failed after teardown mid-authorization")
        #expect(server.snapshotRanges().isEmpty, "GET issued after teardown: \(server.snapshotRanges())")
    }

    @MainActor
    @Test("teardown landing between a continuation's authorization and task creation fails the request")
    func teardownBeforeContinuationTaskCreationFailsRequest() async throws {
        let artifact = try await GeneratedH264Fixture.makeLargerThan(
            Int(AuthenticatedMediaRequestedRange.maxChunkLength)
        )
        defer { try? FileManager.default.removeItem(at: artifact.url) }
        let server = try AuthenticatedRangeHTTPServer(body: artifact.data, token: "Bearer race-chunk")
        defer { server.stop() }

        let auth = AuthorizationProbe(token: "Bearer race-chunk")
        let session = AuthenticatedMediaPlaybackSession(
            source: try mediaSource(url: server.url, authorizationProvider: auth.provider)
        )
        defer { session.teardown() }

        // Only the range continuation (a chunk that starts past the first
        // 1 MiB) reaches this hook with a start >= maxChunkLength.
        let fired = HookFlag()
        let failedByCancellation = CountBox()
        session.debugSetBeforeDataTaskCreationHook { rangeHeader, cancelLoader in
            guard let start = rangeStart(rangeHeader),
                  start >= AuthenticatedMediaRequestedRange.maxChunkLength,
                  fired.claim() else { return }
            failedByCancellation.set(cancelLoader())
        }
        session.player.play()

        let reached = await waitForMainActorCondition(timeout: .seconds(12)) { fired.isClaimed }
        #expect(reached, "continuation never reached task creation. ranges=\(server.snapshotRanges())")
        // The continuation's loading request has no context for cancelAll() to
        // fail; the loader must end it itself instead of leaving it pending.
        let failed = await waitForMainActorCondition(timeout: .seconds(8)) {
            session.debugFailedRequestCount > failedByCancellation.value
        }
        #expect(failed, "continuation request was not failed after teardown")
        let continuationGets = server.snapshotParsedRanges().filter {
            $0.method == "GET" && ($0.start ?? 0) >= AuthenticatedMediaRequestedRange.maxChunkLength
        }
        #expect(continuationGets.isEmpty, "continuation GET issued after teardown: \(continuationGets)")
    }

    @MainActor
    @Test(
        "teardown during a continuation's authorization fails the request instead of leaving it pending",
        arguments: [false, true]
    )
    func teardownDuringContinuationAuthorizationFailsRequest(authorizationThrows: Bool) async throws {
        let artifact = try await GeneratedH264Fixture.makeLargerThan(
            Int(AuthenticatedMediaRequestedRange.maxChunkLength)
        )
        defer { try? FileManager.default.removeItem(at: artifact.url) }
        let server = try AuthenticatedRangeHTTPServer(body: artifact.data, token: "Bearer await-chunk")
        defer { server.stop() }

        // AVFoundation issues many other requests too, so only range
        // continuations get the suspended provider; the rest authorize normally.
        let gate = ContinuationAuthorizationGate(token: "Bearer await-chunk", throwsAfterRelease: authorizationThrows)
        let session = AuthenticatedMediaPlaybackSession(
            source: try mediaSource(url: server.url, authorizationProvider: AuthorizationProbe(token: "Bearer await-chunk").provider)
        )
        defer { session.teardown() }
        session.debugSetContinuationAuthorizationProvider(gate.provider)
        session.player.play()

        let blocked = await waitForMainActorCondition(timeout: .seconds(12)) { gate.isBlocked }
        #expect(blocked, "continuation authorization never blocked. ranges=\(server.snapshotRanges())")
        // Teardown while the continuation awaits. Its previous chunk's context is
        // already gone, so only the continuation itself can end the request.
        session.debugCancelLoader()
        let failedByCancellation = session.debugFailedRequestCount
        gate.release()

        let failed = await waitForMainActorCondition(timeout: .seconds(8)) {
            session.debugFailedRequestCount > failedByCancellation
        }
        #expect(failed, "continuation request stayed pending after teardown (authorizationThrows=\(authorizationThrows))")
    }
}

private final class CountBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var value: Int { lock.withLock { storage } }
    func set(_ newValue: Int) { lock.withLock { storage = newValue } }
}

private func rangeStart(_ header: String?) -> Int64? {
    guard let header, header.hasPrefix("bytes=") else { return nil }
    return Int64(header.dropFirst("bytes=".count).prefix { $0.isNumber })
}

/// Authorization that suspends until `release()`, then either succeeds or throws.
private final class ContinuationAuthorizationGate: @unchecked Sendable {
    private struct Failure: Error {}

    private let lock = NSLock()
    private let token: String
    private let throwsAfterRelease: Bool
    private var blocked = false
    private var released = false
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    init(token: String, throwsAfterRelease: Bool) {
        self.token = token
        self.throwsAfterRelease = throwsAfterRelease
    }

    var isBlocked: Bool { lock.withLock { blocked } }

    var provider: @Sendable () async throws -> String {
        { [self] in
            let wasSuspended = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                lock.lock()
                if released {
                    lock.unlock()
                    continuation.resume(returning: false)
                    return
                }
                blocked = true
                waiters.append(continuation)
                lock.unlock()
            }
            if wasSuspended && throwsAfterRelease { throw Failure() }
            return token
        }
    }

    func release() {
        lock.lock()
        released = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume(returning: true) }
    }
}

private final class HookFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    var isClaimed: Bool { lock.withLock { claimed } }

    /// True for the first caller only.
    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
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
    try TestFixtures.url("known-good-h264.mp4")
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
