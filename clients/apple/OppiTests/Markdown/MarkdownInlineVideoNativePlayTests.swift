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
        let body = try Data(contentsOf: knownGoodH264URL())
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
    @Test("diagnosis: hosted markdown video play() advances currentTime through authenticated route")
    func hostedMarkdownVideoPlayAdvancesCurrentTime() async throws {
        let body = try Data(contentsOf: knownGoodH264URL())
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
        let body = try Data(contentsOf: knownGoodH264URL())
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
        let body = try Data(contentsOf: knownGoodH264URL())
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
    let baseURL = try #require(URL(string: "https://server.example.com"))
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
