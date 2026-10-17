import AVFoundation
import Foundation
import Testing
import UIKit
@testable import Oppi

/// Transport and ownership diagnosis for authenticated inline video.
///
/// These tests call `AVPlayer.play()` on a known-good H.264 served through the
/// production resource loader. They prove `currentTime` advancement, item
/// retention, and hide/fullscreen ownership. They do **not** prove native AVKit
/// Play tap delivery, ancestor-gesture arbitration, or actual fullscreen
/// presentation. Native tap belongs on the sim-lab / sim-test lever.
@Suite("Markdown inline video authenticated transport diagnosis", .serialized)
struct MarkdownInlineVideoNativePlayTests {
    @MainActor
    @Test("diagnosis: authenticated loader play() advances currentTime on known-good H.264")
    func authenticatedLoaderPlayAdvancesCurrentTime() async throws {
        let body = try Data(contentsOf: try knownGoodH264URL())
        let server = try AuthenticatedRangeHTTPServer(body: body, token: "Bearer native-play")
        defer { server.stop() }

        let session = AuthenticatedMediaPlaybackSession(source: mediaSource(url: server.url))
        defer { session.teardown() }
        let player = session.player

        let ready = await waitUntil(timeout: .seconds(8)) {
            player.currentItem?.status == .readyToPlay
        }
        let beforePlay = playbackProbe(player)
        #expect(ready, "item not ready: \(beforePlay) httpRanges=\(server.snapshotRanges())")
        #expect(player.currentItem != nil, "item missing before play: \(beforePlay)")

        let start = finiteSeconds(player.currentTime())
        player.play()
        let advanced = await waitUntil(timeout: .seconds(4)) {
            finiteSeconds(player.currentTime()) > start + 0.15
        }
        let afterPlay = playbackProbe(player)
        #expect(
            advanced,
            """
            currentTime did not advance after play()
            after=\(afterPlay)
            httpRanges=\(server.snapshotRanges())
            """
        )
        #expect(player === session.player, "player identity changed: \(afterPlay)")
        #expect(player.currentItem != nil, "item dropped after play: \(afterPlay)")
    }

    @MainActor
    @Test("missing media reports HTTP 404 instead of AVFoundation's generic failure")
    func missingFileReportsNotFound() async throws {
        let server = try AuthenticatedRangeHTTPServer(
            body: Data(), token: "Bearer native-play", failureStatus: 404
        )
        defer { server.stop() }
        let model = AuthenticatedMediaPlayerModel()
        defer { model.teardown() }
        model.prepare(
            source: mediaSource(url: server.url), autoplay: false,
            telemetrySource: "markdown_inline_video", telemetryMode: "inline",
            telemetrySessionId: nil, onPresentationSize: nil
        )
        let player = try #require(model.player)
        let failed = await waitUntil(timeout: .seconds(8)) { model.errorMessage != nil }
        #expect(failed, "HTTP 404 did not fail the player item")
        #expect(player.currentItem?.status == .failed)
        #expect(model.player == nil)
        #expect(!server.snapshotRanges().isEmpty)
        let error = player.currentItem?.error as NSError?
        print("MISSING_MEDIA itemError=\(String(describing: error)) underlying=\(String(describing: error?.userInfo[NSUnderlyingErrorKey])) modelMessage=\(model.errorMessage ?? "nil")")
        #expect(model.errorMessage == "Media file not found (HTTP 404)")
    }

    @MainActor
    @Test("diagnosis: hosted markdown video play() advances currentTime through authenticated route")
    func hostedMarkdownVideoPlayAdvancesCurrentTime() async throws {
        let body = try Data(contentsOf: try knownGoodH264URL())
        let server = try AuthenticatedRangeHTTPServer(body: body, token: "Bearer native-play")
        defer { server.stop() }

        let host = try makeHostedMarkdownVideo(source: mediaSource(url: server.url))
        defer { host.window.isHidden = true }

        let video = try await waitForInstalledVideo(in: host.video)
        let model = video.debugPlaybackModelForTesting
        let player = try #require(model.player)
        let ready = await waitUntil(timeout: .seconds(8)) {
            player.currentItem?.status == .readyToPlay
        }
        let before = playbackProbe(player)
        #expect(ready, "hosted item not ready: \(before) httpRanges=\(server.snapshotRanges())")
        #expect(model.debugIsVisibleForTesting)
        #expect(video.debugIsPlaybackVisibleForTesting)

        let start = finiteSeconds(player.currentTime())
        player.play()
        let advanced = await waitUntil(timeout: .seconds(4)) {
            finiteSeconds(player.currentTime()) > start + 0.15
        }
        let after = playbackProbe(player)
        #expect(
            advanced,
            """
            currentTime did not advance after play() on hosted markdown video
            after=\(after)
            modelVisible=\(model.debugIsVisibleForTesting)
            viewVisible=\(video.debugIsPlaybackVisibleForTesting)
            playerIdentity=\(ObjectIdentifier(player))
            httpRanges=\(server.snapshotRanges())
            """
        )
        #expect(model.player === player, "hosted player identity changed: \(after)")
        #expect(player.currentItem != nil, "hosted item dropped after play: \(after)")
    }

    @MainActor
    @Test("diagnosis: play() still advances currentTime after hide/reveal ownership")
    func playAdvancesAfterHideRevealOwnership() async throws {
        let body = try Data(contentsOf: try knownGoodH264URL())
        let server = try AuthenticatedRangeHTTPServer(body: body, token: "Bearer native-play")
        defer { server.stop() }

        let host = try makeHostedMarkdownVideo(source: mediaSource(url: server.url))
        defer { host.window.isHidden = true }

        let video = try await waitForInstalledVideo(in: host.video)
        let model = video.debugPlaybackModelForTesting
        let player = try #require(model.player)
        let hideRevealReady = await waitUntil(timeout: .seconds(8)) {
            player.currentItem?.status == .readyToPlay
        }
        #expect(hideRevealReady, "hide/reveal item not ready: \(playbackProbe(player))")

        video.setPlaybackVisible(false)
        #expect(!video.debugIsPlaybackVisibleForTesting)
        #expect(model.player === player)
        #expect(player.currentItem != nil)
        #expect(player.rate == 0)

        video.setPlaybackVisible(true)
        #expect(video.debugIsPlaybackVisibleForTesting)
        #expect(model.player === player)
        #expect(player.currentItem != nil)

        player.play()
        let start = finiteSeconds(player.currentTime())
        let hideRevealAdvanced = await waitUntil(timeout: .seconds(4)) {
            finiteSeconds(player.currentTime()) > start + 0.15
        }
        #expect(hideRevealAdvanced, "play() after hide/reveal did not advance: \(playbackProbe(player))")
    }

    @MainActor
    @Test("diagnosis: play() still advances currentTime after fullscreen ownership events")
    func playAdvancesAfterFullscreenOwnershipEvents() async throws {
        let body = try Data(contentsOf: try knownGoodH264URL())
        let server = try AuthenticatedRangeHTTPServer(body: body, token: "Bearer native-play")
        defer { server.stop() }

        let host = try makeHostedMarkdownVideo(source: mediaSource(url: server.url))
        defer { host.window.isHidden = true }

        let video = try await waitForInstalledVideo(in: host.video)
        let model = video.debugPlaybackModelForTesting
        let player = try #require(model.player)
        let fullscreenReady = await waitUntil(timeout: .seconds(8)) {
            player.currentItem?.status == .readyToPlay
        }
        #expect(fullscreenReady, "fullscreen-ownership item not ready: \(playbackProbe(player))")

        model.setFullScreen(true)
        #expect(model.player === player)
        player.play()
        var start = finiteSeconds(player.currentTime())
        let fullscreenAdvanced = await waitUntil(timeout: .seconds(4)) {
            finiteSeconds(player.currentTime()) > start + 0.15
        }
        #expect(fullscreenAdvanced, "fullscreen-owned play() did not advance: \(playbackProbe(player))")

        model.handleWillEndFullScreen()
        model.handleDidEndFullScreen(hostIsAttached: true)
        #expect(model.player === player)
        #expect(player.currentItem != nil)
        player.play()
        start = finiteSeconds(player.currentTime())
        let afterDismissAdvanced = await waitUntil(timeout: .seconds(4)) {
            finiteSeconds(player.currentTime()) > start + 0.15
        }
        #expect(afterDismissAdvanced, "play() after fullscreen-ownership dismiss did not advance: \(playbackProbe(player))")
    }

    @MainActor
    @Test(
        "a stalled server cannot hold a still-frame read past its deadline, and the next request recovers",
        .timeLimit(.minutes(2))
    )
    func stalledStillFrameReadFailsAtDeadlineAndRecovers() async throws {
        let body = try Data(contentsOf: try knownGoodH264URL())
        let server = try AuthenticatedRangeHTTPServer(body: body, token: "Bearer native-play")
        defer { server.stop() }
        let source = mediaSource(url: server.url)
        let size = CGSize(width: 320, height: 180)
        let store = InlineVideoStillFrameStore(
            generator: { source, size in
                try await InlineVideoStillFrameGenerator.generate(
                    source: source, maxPixelSize: size, deadline: .seconds(1)
                )
            },
            notificationCenter: NotificationCenter()
        )

        server.setStalled(true)
        let clock = ContinuousClock()
        let started = clock.now
        let stalled = await store.image(for: source, maxPixelSize: size)
        let elapsed = clock.now - started
        #expect(server.stalledRequestCount > 0, "the read never reached the stalled server")
        #expect(stalled == nil)
        #expect(elapsed < .seconds(5), "the deadline did not return: \(elapsed)")
        #expect(store.debugInFlightCountForTesting == 0, "a hung generation stayed in flight")

        // A deadline miss says nothing about the file: no failure backoff.
        server.setStalled(false)
        let recovered = await store.image(for: source, maxPixelSize: size)
        #expect(recovered != nil, "a later request did not produce a frame: \(server.snapshotRanges())")
        #expect(store.debugGenerationCountForTesting == 2)
        #expect(store.debugInFlightCountForTesting == 0)
    }

    @MainActor
    @Test("timeline scroll builds no player before tap; one tap builds one playing player; each still loads once")
    func timelineScrollBuildsNoPlayerUntilTap() async throws {
        let body = try Data(contentsOf: try knownGoodH264URL())
        let server = try AuthenticatedRangeHTTPServer(body: body, token: "Bearer sk_test")
        defer { server.stop() }
        let base = try #require(URL(string: "http://127.0.0.1:\(server.url.port ?? 0)"))

        let previousStore = InlineVideoStillFrameStore.shared
        let store = InlineVideoStillFrameStore()
        InlineVideoStillFrameStore.installForTesting(store)
        defer { InlineVideoStillFrameStore.installForTesting(previousStore) }

        let timeline = makeWindowedTimelineHarness(sessionId: "s-video-scroll")
        defer { timeline.window.isHidden = true }
        // AVKit containment needs a view controller above the collection view.
        let host = UIViewController()
        timeline.window.rootViewController = host
        host.view.addSubview(timeline.collectionView)
        timeline.collectionView.frame = host.view.bounds
        timeline.window.makeKeyAndVisible()
        timeline.connection.setAPIClientForTesting(
            APIClient(baseURL: base, token: "sk_test", configuration: .ephemeral)
        )

        let videoCount = 8
        let timestamp = Date(timeIntervalSince1970: 0)
        let rows: [ChatItem] = (0..<videoCount).map { index in
            .assistantMessage(
                id: "a\(index)",
                text: "Clip \(index)\n\n![[v\(index).mp4]]\n\nafter \(index)",
                timestamp: timestamp
            )
        }
        timeline.applyItems(rows, isBusy: false, streamingID: nil)

        var seen: [NativeMarkdownVideoView] = []
        func sampleVideos() -> [NativeMarkdownVideoView] {
            let videos = timelineAllViews(in: timeline.collectionView).compactMap { $0 as? NativeMarkdownVideoView }
            for video in videos where !seen.contains(where: { $0 === video }) { seen.append(video) }
            return videos
        }
        func expectNoPlayerAnywhere(_ label: String) {
            for video in sampleVideos() {
                #expect(!video.debugHasPlayerForTesting, "\(label): player controller mounted before tap")
                #expect(video.debugPlaybackModelForTesting.player == nil, "\(label): AVPlayer built before tap")
            }
        }

        let maxOffset = timeline.collectionView.contentSize.height - timeline.collectionView.bounds.height
        #expect(maxOffset > 0)
        for pass in 0..<2 {
            var offset: CGFloat = 0
            while offset < maxOffset {
                offset = min(offset + 120, maxOffset)
                timeline.collectionView.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
                timeline.collectionView.layoutIfNeeded()
                try? await Task.sleep(for: .milliseconds(120))
                expectNoPlayerAnywhere("pass \(pass) down")
            }
            while offset > 0 {
                offset = max(offset - 120, 0)
                timeline.collectionView.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
                timeline.collectionView.layoutIfNeeded()
                try? await Task.sleep(for: .milliseconds(120))
                expectNoPlayerAnywhere("pass \(pass) up")
            }
        }

        // Cells were recycled across the passes; no row ever built a player.
        #expect(seen.count > videoCount, "scroll never recycled a video cell")
        let onScreenStills = await waitUntil(timeout: .seconds(8)) {
            let visible = sampleVideos().filter { $0.window != nil }
            return !visible.isEmpty && visible.allSatisfy { $0.debugStillImageForTesting != nil }
        }
        #expect(onScreenStills, "visible rows never showed their still frame")
        // One generation per video identity across every re-entry.
        #expect(store.debugGenerationCountForTesting == videoCount)

        let visible = sampleVideos().filter { $0.window != nil && timelineViewIsVisible($0) }
        let target = try #require(visible.first)
        let model = target.debugPlaybackModelForTesting
        #expect(target.debugPlayButtonForTesting.accessibilityIdentifier == "markdown-video-play")
        target.debugTapPlayForTesting()
        let playing = await waitUntil(timeout: .seconds(10)) {
            model.player?.timeControlStatus == .playing
        }
        #expect(playing, "tap did not reach playing: \(model.debugPlaybackProbeForTesting)")
        let withPlayers = sampleVideos().filter { $0.debugHasPlayerForTesting }
        #expect(withPlayers.count == 1)
        #expect(withPlayers.first === target)
        #expect(sampleVideos().filter { $0 !== target }.allSatisfy { $0.debugPlaybackModelForTesting.player == nil })
        #expect(store.debugGenerationCountForTesting == videoCount)
        target.prepareForRemoval()
    }
}

@MainActor
private struct HostedMarkdownVideo {
    let window: UIWindow
    let video: NativeMarkdownVideoView
}

@MainActor
private func makeHostedMarkdownVideo(source: AuthenticatedMediaSource) throws -> HostedMarkdownVideo {
    let parent = UIViewController()
    let video = NativeMarkdownVideoView()
    parent.view.addSubview(video)
    video.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        video.leadingAnchor.constraint(equalTo: parent.view.leadingAnchor, constant: 16),
        video.trailingAnchor.constraint(equalTo: parent.view.trailingAnchor, constant: -16),
        video.topAnchor.constraint(equalTo: parent.view.topAnchor, constant: 80),
    ])

    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    window.rootViewController = parent
    window.makeKeyAndVisible()

    let embed = try makeEmbed("![[known-good-h264.mp4]]")
    video.apply(
        embed: embed,
        sourceProvider: { _ in source },
        renderingMode: .live,
        preferredDisplayWidth: 320
    )
    parent.view.layoutIfNeeded()
    video.debugTapPlayForTesting()
    return HostedMarkdownVideo(window: window, video: video)
}

@MainActor
private func waitForInstalledVideo(in video: NativeMarkdownVideoView) async throws -> NativeMarkdownVideoView {
    let installed = await waitUntil(timeout: .seconds(8)) {
        video.debugHasActivePlayerForTesting
    }
    #expect(installed, "markdown video did not install an authenticated player")
    return video
}

@MainActor
private func playbackProbe(_ player: AVPlayer) -> String {
    let item = player.currentItem
    let time = finiteSeconds(player.currentTime())
    let waiting = player.reasonForWaitingToPlay?.rawValue ?? "none"
    let error = item?.error?.localizedDescription ?? "none"
    return [
        "status=\(String(describing: item?.status))",
        "rate=\(player.rate)",
        "timeControl=\(String(describing: player.timeControlStatus))",
        "waiting=\(waiting)",
        "time=\(time)",
        "item=\(item == nil ? "nil" : "present")",
        "error=\(error)",
    ].joined(separator: " ")
}

private func finiteSeconds(_ time: CMTime) -> TimeInterval {
    let seconds = time.seconds
    return seconds.isFinite ? seconds : 0
}

private func mediaSource(url: URL) -> AuthenticatedMediaSource {
    AuthenticatedMediaSource(
        url: url,
        authorizationHeaderValue: "Bearer native-play",
        tlsCertFingerprint: nil,
        contentTypeHint: "video/mp4",
        sourceFileExtension: "mp4"
    )
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

private func makeEmbed(_ markdown: String) throws -> MarkdownVideoEmbed {
    let baseURL = testUnwrap(URL(string: "https://server.example.com"))
    let segments = FlatSegment.build(
        from: parseCommonMark(markdown),
        themeID: .dark,
        serverID: "server-a",
        workspaceID: "workspace-a",
        sessionID: "session-a",
        serverBaseURL: baseURL
    )
    return try #require(segments.compactMap { segment -> MarkdownVideoEmbed? in
        guard case .video(let embed) = segment else { return nil }
        return embed
    }.first)
}

@MainActor
private func waitUntil(
    timeout: Duration,
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}
