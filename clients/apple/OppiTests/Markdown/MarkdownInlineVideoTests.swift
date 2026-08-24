import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Oppi

@Suite("Markdown inline video contract", .serialized)
struct MarkdownInlineVideoTests {
    @Test("embed syntax produces video while ordinary wiki syntax stays a link")
    func syntaxAndSourcePolicy() throws {
        let baseURL = try #require(URL(string: "https://server.example.com"))
        let segments = FlatSegment.build(
            from: parseCommonMark("![[media/demo.mp4]]\n\n[[media/demo.mp4]]\n\n![[notes/readme.md]]"),
            themeID: .dark,
            serverID: "server-a",
            workspaceID: "workspace-a",
            sessionID: "session-a",
            serverBaseURL: baseURL
        )

        let videos = segments.compactMap { segment -> MarkdownVideoEmbed? in
            guard case .video(let embed) = segment else { return nil }
            return embed
        }
        #expect(videos.count == 1)
        #expect(videos.first?.reference.fileCandidatePath == "media/demo.mp4")
        #expect(videos.first?.reference.kind == .workspaceFile)

        let renderedText = segments.compactMap { segment -> AttributedString? in
            guard case .text(let text) = segment else { return nil }
            return text
        }
        let uniqueLinkTargets = Set(renderedText.flatMap { $0.runs.compactMap(\.link) })
        #expect(uniqueLinkTargets.count == 2)
        #expect(renderedText.map { String($0.characters) }.joined().contains("!"))
    }

    @Test("host files are eligible but remote and attachment-like targets never embed")
    func sourcePolicyRejectsOutsideAuthenticatedFileRoutes() throws {
        let baseURL = try #require(URL(string: "https://server.example.com"))
        let markdown = """
        ![[/tmp/demo.mov]]

        ![[https://example.com/demo.mp4]]

        ![[attachment:stored-video]]

        <video src="https://example.com/demo.mp4"></video>
        """
        let segments = FlatSegment.build(
            from: parseCommonMark(markdown),
            themeID: .dark,
            serverID: "server-a",
            workspaceID: "workspace-a",
            sessionID: "session-a",
            serverBaseURL: baseURL
        )

        let videos = segments.compactMap { segment -> MarkdownVideoEmbed? in
            guard case .video(let embed) = segment else { return nil }
            return embed
        }
        #expect(videos.count == 1)
        #expect(videos.first?.reference.kind == .hostFile)
        #expect(videos.first?.reference.fileCandidatePath == "/tmp/demo.mov")
    }

    @Test("eligible references select only authenticated host, session, or workspace routes")
    func authenticatedMediaRouteSelection() throws {
        let baseURL = try #require(URL(string: "https://server.example.com"))
        let workspaceEmbed = try #require(build("![[media/demo.mp4]]", baseURL: baseURL).segments.compactMap { segment -> MarkdownVideoEmbed? in
            guard case .video(let embed) = segment else { return nil }
            return embed
        }.first)
        let hostEmbed = try #require(build("![[/tmp/demo.mov]]", baseURL: baseURL).segments.compactMap { segment -> MarkdownVideoEmbed? in
            guard case .video(let embed) = segment else { return nil }
            return embed
        }.first)

        #expect(MarkdownVideoMediaSourceRoute.resolve(
            embed: workspaceEmbed,
            workspaceID: "fallback-workspace",
            sessionID: "session-a",
            worktreeID: "worktree-a"
        ) == .session(workspaceID: "workspace-a", sessionID: "session-a", path: "media/demo.mp4"))
        #expect(MarkdownVideoMediaSourceRoute.resolve(
            embed: workspaceEmbed,
            workspaceID: "fallback-workspace",
            sessionID: nil,
            worktreeID: "worktree-a"
        ) == .workspace(workspaceID: "workspace-a", path: "media/demo.mp4", worktreeID: "worktree-a"))
        #expect(MarkdownVideoMediaSourceRoute.resolve(
            embed: hostEmbed,
            workspaceID: "workspace-a",
            sessionID: "session-a",
            worktreeID: nil
        ) == .host(path: "/tmp/demo.mov"))
        #expect(MarkdownVideoMediaSourceRoute.resolve(
            embed: hostEmbed,
            workspaceID: "workspace-a",
            sessionID: "session-a",
            worktreeID: nil,
            workspaceRuntime: .sandbox
        ) == .session(workspaceID: "workspace-a", sessionID: "session-a", path: "/tmp/demo.mov"))
        #expect(MarkdownVideoMediaSourceRoute.resolve(
            embed: hostEmbed,
            workspaceID: "workspace-a",
            sessionID: nil,
            worktreeID: "worktree-a",
            workspaceRuntime: .sandbox
        ) == .workspace(
            workspaceID: "workspace-a",
            path: "/tmp/demo.mov",
            worktreeID: "worktree-a"
        ))
        #expect(MarkdownVideoMediaSourceRoute.resolve(
            embed: hostEmbed,
            workspaceID: nil,
            sessionID: nil,
            worktreeID: nil,
            workspaceRuntime: .sandbox
        ) == nil)
    }

    @Test("video segments receive stable occurrence identities")
    func segmentIdentityIsStable() throws {
        let baseURL = try #require(URL(string: "https://server.example.com"))
        let initial = build("![[one.mp4]] ![[two.mov]]", baseURL: baseURL)
        let appended = build("![[one.mp4]] ![[two.mov]]\n\nTrailing text.", baseURL: baseURL)
        let videoIDs = zip(initial.segments, initial.identities).compactMap { segment, id in
            if case .video = segment { return id }
            return nil
        }

        #expect(videoIDs.count == 2)
        #expect(Set(videoIDs).count == 2)
        #expect(videoIDs.map(\.kind) == [.video, .video])
        #expect(videoIDs.map(\.occurrenceOrdinal) == [0, 1])
        #expect(Array(appended.identities.prefix(initial.identities.count)) == initial.identities)
    }

    @Test("fallback video geometry is deterministic and playback is opt-in")
    func deterministicGeometryAndPlaybackPolicy() {
        #expect(!MarkdownInlineVideoLayout.autoplay)
        #expect(abs(MarkdownInlineVideoLayout.fallbackAspectRatio - (16.0 / 9.0)) < 0.000_001)
        #expect(MarkdownInlineVideoLayout.reservedHeight(forWidth: 320) == 180)
        #expect(MarkdownInlineVideoLayout.reservedHeight(forWidth: 369) == 208)
        #expect(MarkdownInlineVideoLayout.reservedHeight(forWidth: .nan) == 180)
    }

    @Test("offscreen playback tears down unless fullscreen or PiP owns it")
    func lifecyclePolicy() {
        #expect(MediaPlaybackTeardownPolicy.shouldTeardown(
            isVisible: false,
            isFullScreen: false,
            isPictureInPicture: false
        ))
        #expect(!MediaPlaybackTeardownPolicy.shouldTeardown(
            isVisible: false,
            isFullScreen: true,
            isPictureInPicture: false
        ))
        #expect(!MediaPlaybackTeardownPolicy.shouldTeardown(
            isVisible: false,
            isFullScreen: false,
            isPictureInPicture: true
        ))
        var ending = MediaPlaybackTeardownPolicy.Ownership(
            isVisible: false,
            isFullScreen: true
        )
        MediaPlaybackTeardownPolicy.apply(.willEndFullScreen, to: &ending)
        #expect(!ending.shouldTeardown)
        MediaPlaybackTeardownPolicy.apply(.didEndFullScreen, to: &ending)
        #expect(ending.shouldTeardown)

        var stillAttached = MediaPlaybackTeardownPolicy.Ownership(
            isVisible: true,
            isFullScreen: true
        )
        MediaPlaybackTeardownPolicy.apply(.willEndFullScreen, to: &stillAttached)
        #expect(!stillAttached.shouldTeardown)
        MediaPlaybackTeardownPolicy.apply(.didEndFullScreen, to: &stillAttached)
        #expect(!stillAttached.shouldTeardown)
    }

    @MainActor
    @Test("assistant timeline mounts the native video segment")
    func assistantTimelineIntegration() throws {
        let baseURL = try #require(URL(string: "https://server.example.com"))
        let row = AssistantTimelineRowContentView(configuration: .init(
            text: "Before\n\n![[movie.mp4]]\n\nAfter",
            isStreaming: false,
            canFork: false,
            onFork: nil,
            sessionId: "session-a",
            serverID: "server-a",
            workspaceID: "workspace-a",
            serverBaseURL: baseURL,
            makeMarkdownVideoSource: { _ in throw CocoaError(.fileNoSuchFile) }
        ))
        row.frame = CGRect(x: 0, y: 0, width: 360, height: 500)
        row.layoutIfNeeded()

        #expect(timelineFirstView(ofType: NativeMarkdownVideoView.self, in: row) != nil)
    }

    @MainActor
    @Test("export uses a static fallback and never resolves media")
    func exportFallbackDoesNotResolveMedia() async throws {
        let baseURL = try #require(URL(string: "https://server.example.com"))
        let view = AssistantMarkdownContentView()
        var resolutionCount = 0
        view.makeMarkdownVideoSource = { _ in
            resolutionCount += 1
            throw CocoaError(.fileNoSuchFile)
        }
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 400)
        view.apply(configuration: .make(
            content: "![[movie.mp4]]",
            isStreaming: false,
            themeID: .dark,
            serverID: "server-a",
            workspaceID: "workspace-a",
            sessionID: "session-a",
            serverBaseURL: baseURL,
            renderingMode: .export
        ))
        view.layoutIfNeeded()
        await Task.yield()

        let videoView = try #require(timelineFirstView(ofType: NativeMarkdownVideoView.self, in: view))
        #expect(videoView.debugIsStaticFallbackForTesting)
        #expect(videoView.debugReservedHeightForTesting == 180)
        #expect(resolutionCount == 0)
    }

    @MainActor
    @Test("full-screen video is final before reveal and source preparation cannot move the viewport")
    func readerVideoGeometryIsFinalBeforeReveal() async throws {
        let baseURL = try #require(URL(string: "https://server.example.com"))
        let body = NativeFullScreenMarkdownBody(
            content: (0..<12).map { "Paragraph \($0)." }.joined(separator: "\n\n") + "\n\n![[movie.mp4]]\n\nAfter.",
            palette: ThemeID.dark.palette,
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil,
            serverID: "server-a",
            workspaceID: "workspace-a",
            sessionID: "session-a",
            serverBaseURL: baseURL,
            makeMarkdownVideoSource: { _ in throw CocoaError(.fileNoSuchFile) }
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 844))
        window.addSubview(body)
        body.frame = window.bounds
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        body.layoutIfNeeded()
        let videoItem = try #require(body.debugRenderedSegmentsForTesting.firstIndex {
            if case .video = $0 { return true }
            return false
        })
        #expect(body.debugHasFinalGeometryForTesting(videoItem))
        let before = body.debugLineAnchorScrollOffsetForTesting
        await Task.yield()
        await Task.yield()
        body.layoutIfNeeded()
        #expect(body.debugHasFinalGeometryForTesting(videoItem))
        #expect(body.debugLineAnchorScrollOffsetForTesting == before)
        #expect(!body.debugOffsetWriteReasonsForTesting.contains(.preserveAnchor))
    }

    @MainActor
    @Test("revealed video keeps 16:9 after a streaming re-apply")
    func revealedVideoKeepsSixteenByNineOnReapply() throws {
        let embed = try makeEmbed("![[movie.mp4]]")
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        let host = UIViewController()
        let video = NativeMarkdownVideoView()
        host.view.addSubview(video)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        video.apply(
            embed: embed,
            sourceProvider: { _ in throw CocoaError(.fileNoSuchFile) },
            renderingMode: .live,
            preferredDisplayWidth: 320
        )
        video.layoutIfNeeded()
        #expect(video.debugReservedHeightForTesting == 180)
        #expect(video.debugHasCommittedRevealGeometryForTesting)

        video.apply(
            embed: embed,
            sourceProvider: { _ in throw CocoaError(.fileNoSuchFile) },
            renderingMode: .live,
            preferredDisplayWidth: 320
        )
        video.layoutIfNeeded()
        #expect(video.debugReservedHeightForTesting == 180)
    }

    @MainActor
    @Test("in-place streaming apply keeps a revealed timeline video at 16:9")
    func streamingInPlaceApplyKeepsSixteenByNine() throws {
        let baseURL = try #require(URL(string: "https://server.example.com"))
        let view = AssistantMarkdownContentView()
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 400)
        view.apply(configuration: .make(
            content: "![[movie.mp4]]",
            isStreaming: true,
            themeID: .dark,
            serverID: "server-a",
            workspaceID: "workspace-a",
            sessionID: "session-a",
            serverBaseURL: baseURL
        ))
        view.layoutIfNeeded()
        let video = try #require(timelineFirstView(ofType: NativeMarkdownVideoView.self, in: view))
        let revealedHeight = video.debugReservedHeightForTesting
        #expect(revealedHeight == 180)

        view.apply(configuration: .make(
            content: "![[movie.mp4]]\n\nTrailing stream text.",
            isStreaming: true,
            themeID: .dark,
            serverID: "server-a",
            workspaceID: "workspace-a",
            sessionID: "session-a",
            serverBaseURL: baseURL
        ))
        view.layoutIfNeeded()
        let updated = try #require(timelineFirstView(ofType: NativeMarkdownVideoView.self, in: view))
        #expect(updated.debugReservedHeightForTesting == revealedHeight)
    }

    @MainActor
    @Test("unrevealed prepared video stays 16:9")
    func unrevealedPreparedVideoStaysSixteenByNine() throws {
        let embed = try makeEmbed("![[movie.mp4]]")
        let video = NativeMarkdownVideoView()
        video.apply(
            embed: embed,
            sourceProvider: { _ in throw CocoaError(.fileNoSuchFile) },
            renderingMode: .staticReader,
            preferredDisplayWidth: 320
        )
        #expect(!video.debugHasCommittedRevealGeometryForTesting)
        #expect(video.debugReservedHeightForTesting == 180)
    }

    @MainActor
    @Test("a later remount of the same embed stays 16:9")
    func remountKeepsSixteenByNine() throws {
        let embed = try makeEmbed("![[movie.mp4]]")
        let first = NativeMarkdownVideoView()
        first.apply(
            embed: embed,
            sourceProvider: { _ in throw CocoaError(.fileNoSuchFile) },
            renderingMode: .live,
            preferredDisplayWidth: 320
        )
        #expect(first.debugReservedHeightForTesting == 180)

        let remount = NativeMarkdownVideoView()
        remount.apply(
            embed: embed,
            sourceProvider: { _ in throw CocoaError(.fileNoSuchFile) },
            renderingMode: .staticReader,
            preferredDisplayWidth: 320
        )
        #expect(remount.debugReservedHeightForTesting == 180)
    }

    @MainActor
    @Test("revealed video keeps 16:9 when the display width changes")
    func revealedVideoKeepsSixteenByNineOnWidthChange() throws {
        let embed = try makeEmbed("![[movie.mp4]]")
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        let host = UIViewController()
        let video = NativeMarkdownVideoView()
        host.view.addSubview(video)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        video.apply(
            embed: embed,
            sourceProvider: { _ in throw CocoaError(.fileNoSuchFile) },
            renderingMode: .live,
            preferredDisplayWidth: 320
        )
        video.layoutIfNeeded()
        #expect(video.debugReservedHeightForTesting == 180)
        #expect(video.debugHasCommittedRevealGeometryForTesting)

        video.apply(
            embed: embed,
            sourceProvider: { _ in throw CocoaError(.fileNoSuchFile) },
            renderingMode: .live,
            preferredDisplayWidth: 640
        )
        #expect(video.debugReservedHeightForTesting == 360)
    }

    @MainActor
    @Test("real FileShareService markdown export emits the static video card without workspace context")
    func realFileShareServiceExportUsesStaticVideoCard() async throws {
        let view = FileShareService.makeMarkdownExportView("Watch this:\n\n![[movie.mp4]]")
        let exportWidth = FileShareService.markdownExportContentWidth
        view.frame = CGRect(x: 0, y: 0, width: exportWidth, height: 600)
        view.layoutIfNeeded()
        await Task.yield()

        let videoView = try #require(timelineFirstView(ofType: NativeMarkdownVideoView.self, in: view))
        #expect(videoView.debugIsStaticFallbackForTesting)
        #expect(videoView.debugReservedHeightForTesting == MarkdownInlineVideoLayout.reservedHeight(forWidth: exportWidth))
        #expect(abs((exportWidth / videoView.debugReservedHeightForTesting) - (16.0 / 9.0)) < 0.02)
        #expect(!videoView.debugHasPlayerForTesting)

        let item = await FileShareService.render(.markdown("![[movie.mp4]]"), as: .image)
        guard case .image(let image) = item else {
            Issue.record("Expected an image export, got \(item)")
            return
        }
        #expect(image.size.width > 10)
        #expect(image.size.height > 10)
        #expect(!FileShareService.isBlankImage(image))
    }

    @Test("relative video embeds parse without workspace scope")
    func exportParseWithoutWorkspaceProducesVideoEmbed() throws {
        let segments = FlatSegment.build(
            from: parseCommonMark("![[movie.mp4]]"),
            themeID: .dark,
            serverID: nil,
            workspaceID: nil,
            sessionID: nil,
            serverBaseURL: nil
        )
        let videos = segments.compactMap { segment -> MarkdownVideoEmbed? in
            guard case .video(let embed) = segment else { return nil }
            return embed
        }
        #expect(videos.count == 1)
        #expect(videos.first?.reference.fileCandidatePath == "movie.mp4")
    }

    @Test("standalone nested list and quote embeds become players; mixed inlines stay links")
    func nestedEmbedsArePlayersOrActionableLinks() throws {
        let baseURL = try #require(URL(string: "https://server.example.com"))
        let list = build("- ![[movie.mp4]]", baseURL: baseURL)
        #expect(list.segments.contains { if case .video = $0 { return true }; return false })

        let quote = build("> ![[movie.mp4]]", baseURL: baseURL)
        #expect(quote.segments.contains { if case .video = $0 { return true }; return false })

        let heading = build("# See ![[movie.mp4]]", baseURL: baseURL)
        let headingText = heading.segments.compactMap { segment -> AttributedString? in
            guard case .text(let text) = segment else { return nil }
            return text
        }
        let headingLinks = headingText.flatMap { $0.runs.compactMap(\.link) }
        #expect(!headingLinks.isEmpty)
        #expect(!headingText.map { String($0.characters) }.joined().contains("[Video:"))

        let mixed = build("- See ![[movie.mp4]] now", baseURL: baseURL)
        let mixedHasPlayer = mixed.segments.contains { if case .video = $0 { return true }; return false }
        let mixedText = mixed.segments.compactMap { segment -> AttributedString? in
            guard case .text(let text) = segment else { return nil }
            return text
        }
        let mixedLinks = mixedText.flatMap { $0.runs.compactMap(\.link) }
        #expect(mixedHasPlayer || !mixedLinks.isEmpty)
        #expect(!mixedText.map { String($0.characters) }.joined().contains("[Video:"))
    }

    @MainActor
    @Test("session markdown keeps the real source path for relative embeds")
    func sessionMarkdownPreservesSourcePath() throws {
        let baseURL = try #require(URL(string: "https://server.example.com"))
        let content = SessionFileFullScreenContentBuilder.content(
            text: "![[./demo.mp4]]",
            filePath: "docs/readme.md",
            workspaceID: "workspace-a",
            serverBaseURL: baseURL,
            workspaceHostMount: nil,
            workspaceRuntime: .sandbox,
            fetchSessionFileData: { _ in Data() },
            sessionID: "session-a"
        )
        guard case .markdown(let text, let path, _) = content else {
            Issue.record("Expected markdown content, got \(content)")
            return
        }
        #expect(path == "docs/readme.md")

        let segments = FlatSegment.build(
            from: parseCommonMark(text),
            themeID: .dark,
            serverID: "server-a",
            workspaceID: "workspace-a",
            sessionID: "session-a",
            serverBaseURL: baseURL,
            sourceDirectory: path.flatMap { filePath -> String? in
                let dir = (filePath as NSString).deletingLastPathComponent
                return dir.isEmpty || dir == "." ? nil : dir
            }
        )
        let videos = segments.compactMap { segment -> MarkdownVideoEmbed? in
            guard case .video(let embed) = segment else { return nil }
            return embed
        }
        #expect(videos.first?.reference.fileCandidatePath == "docs/demo.mp4")
    }

    @Test("fetch-time runtime refresh routes sandbox host paths through session raw")
    func fetchTimeRuntimeRefreshRoutesSandboxHostPaths() throws {
        let embed = try makeEmbed("![[/tmp/demo.mov]]")
        #expect(MarkdownVideoWorkspaceContext.resolvedRuntime(captured: nil, current: .sandbox) == .sandbox)
        #expect(MarkdownVideoWorkspaceContext.resolvedRuntime(captured: .host, current: .sandbox) == .sandbox)
        #expect(MarkdownVideoWorkspaceContext.runtime(
            workspaceId: "workspace-a",
            serverId: "server-a",
            workspacesByServer: [:],
            workspaces: []
        ) == nil)

        let refreshed = MarkdownVideoWorkspaceContext.resolvedRuntime(captured: nil, current: .sandbox)
        #expect(MarkdownVideoMediaSourceRoute.resolve(
            embed: embed,
            workspaceID: "workspace-a",
            sessionID: "session-a",
            worktreeID: nil,
            workspaceRuntime: refreshed
        ) == .session(workspaceID: "workspace-a", sessionID: "session-a", path: "/tmp/demo.mov"))

        #expect(MarkdownVideoMediaSourceRoute.resolve(
            embed: embed,
            workspaceID: nil,
            sessionID: nil,
            worktreeID: nil,
            workspaceRuntime: nil
        ) == .host(path: "/tmp/demo.mov"))
    }

    @MainActor
    @Test("player hosting controller is contained and removed from a real parent")
    func playerHostingControllerUsesValidContainment() async throws {
        let embed = try makeEmbed("![[movie.mp4]]")
        let source = dummyMediaSource()
        let parent = UIViewController()
        let video = NativeMarkdownVideoView()
        parent.view.addSubview(video)
        video.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            video.leadingAnchor.constraint(equalTo: parent.view.leadingAnchor),
            video.trailingAnchor.constraint(equalTo: parent.view.trailingAnchor),
            video.topAnchor.constraint(equalTo: parent.view.topAnchor),
        ])
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 844))
        window.rootViewController = parent
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        video.apply(
            embed: embed,
            sourceProvider: { _ in source },
            renderingMode: .live,
            preferredDisplayWidth: 320
        )
        var installed = false
        for _ in 0..<40 {
            if video.debugHasPlayerForTesting {
                installed = true
                break
            }
            await Task.yield()
        }
        #expect(installed)
        #expect(video.debugHostingParentForTesting === parent)
        #expect(parent.children.contains { $0 === video.debugHostingControllerForTesting })

        video.apply(
            embed: embed,
            sourceProvider: nil,
            renderingMode: .export,
            preferredDisplayWidth: 320
        )
        #expect(!video.debugHasPlayerForTesting)
        #expect(video.debugHostingParentForTesting == nil)
        #expect(parent.children.isEmpty)
    }

    @MainActor
    @Test("failure fallback is a 44pt Dynamic Type control with accessible semantics")
    func failureFallbackMeetsAccessibilityContract() throws {
        let embed = try makeEmbed("![[movie.mp4]]")
        let video = NativeMarkdownVideoView()
        video.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        video.apply(
            embed: embed,
            sourceProvider: nil,
            renderingMode: .live,
            preferredDisplayWidth: 320
        )
        video.layoutIfNeeded()

        #expect(video.debugFailureHitAreaForTesting.width >= 44)
        #expect(video.debugFailureHitAreaForTesting.height >= 44)
        #expect(video.debugStatusLabelAdjustsFontForTesting)
        #expect(video.debugOpenButtonAdjustsFontForTesting)
        #expect(!video.debugOpenButtonIsHiddenForTesting)

        video.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        video.setNeedsLayout()
        video.layoutIfNeeded()
        #expect(video.debugFailureHitAreaForTesting.height >= 44)
    }

    @MainActor
    @Test("reuse teardown removes the hosted player unless a later apply reinstalls it")
    func reuseTeardownRemovesHostedPlayer() async throws {
        let embed = try makeEmbed("![[movie.mp4]]")
        let source = dummyMediaSource()
        let parent = UIViewController()
        let video = NativeMarkdownVideoView()
        parent.view.addSubview(video)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 844))
        window.rootViewController = parent
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        video.apply(
            embed: embed,
            sourceProvider: { _ in source },
            renderingMode: .live,
            preferredDisplayWidth: 320
        )
        for _ in 0..<40 where !video.debugHasPlayerForTesting {
            await Task.yield()
        }
        #expect(video.debugHasPlayerForTesting)

        video.setPlaybackVisible(false)
        video.apply(
            embed: try makeEmbed("![[other.mov]]"),
            sourceProvider: nil,
            renderingMode: .live,
            preferredDisplayWidth: 320
        )
        #expect(!video.debugHasPlayerForTesting)
        #expect(video.debugHostingParentForTesting == nil)
    }

    @MainActor
    @Test("hiding playback tears down the player without replacing the host")
    func hidingPlaybackTearsDownWithoutReplacingHost() async throws {
        let embed = try makeEmbed("![[movie.mp4]]")
        let source = dummyMediaSource()
        let parent = UIViewController()
        let video = NativeMarkdownVideoView()
        parent.view.addSubview(video)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 844))
        window.rootViewController = parent
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        video.apply(
            embed: embed,
            sourceProvider: { _ in source },
            renderingMode: .live,
            preferredDisplayWidth: 320
        )
        for _ in 0..<40 where !video.debugHasPlayerForTesting {
            await Task.yield()
        }
        let host = video.debugHostingControllerForTesting
        #expect(host != nil)
        #expect(video.debugIsPlaybackVisibleForTesting)

        video.setPlaybackVisible(false)
        #expect(!video.debugIsPlaybackVisibleForTesting)
        #expect(video.debugHostingControllerForTesting === host)
        #expect(!video.debugHasActivePlayerForTesting)
    }

    @MainActor
    @Test("timeline content can hide video playback through the existing applier")
    func timelineContentForwardsPlaybackVisibility() throws {
        let baseURL = try #require(URL(string: "https://server.example.com"))
        let view = AssistantMarkdownContentView()
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 400)
        view.apply(configuration: .make(
            content: "![[movie.mp4]]",
            isStreaming: false,
            themeID: .dark,
            serverID: "server-a",
            workspaceID: "workspace-a",
            sessionID: "session-a",
            serverBaseURL: baseURL
        ))
        view.layoutIfNeeded()
        let video = try #require(timelineFirstView(ofType: NativeMarkdownVideoView.self, in: view))
        #expect(video.debugIsPlaybackVisibleForTesting)
        view.setVideoPlaybackVisible(false)
        #expect(!video.debugIsPlaybackVisibleForTesting)
    }

    @MainActor
    @Test("default FileBrowser player keeps one model across GeometryReader rebuilds")
    func defaultFileBrowserModelSurvivesGeometryRebuild() async {
        AuthenticatedMediaPlayerTesting.reset()
        defer { AuthenticatedMediaPlayerTesting.reset() }

        let source = dummyMediaSource()
        let knob = FileBrowserPlayerRebuildKnob()
        let host = UIHostingController(
            rootView: FileBrowserStylePlayerHost(source: source, knob: knob)
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        host.view.layoutIfNeeded()
        await Task.yield()
        let afterFirst = AuthenticatedMediaPlayerTesting.resolvedModels
        #expect(!afterFirst.isEmpty)

        knob.height = 560
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        await Task.yield()
        await Task.yield()

        let afterRebuild = AuthenticatedMediaPlayerTesting.resolvedModels
        #expect(afterRebuild.count >= 2)
        #expect(
            Set(afterRebuild).count == 1,
            "Geometry rebuild created a new player model: \(afterRebuild)"
        )
    }

    @MainActor
    @Test("injected markdown playback model is reused instead of a throwaway")
    func injectedMarkdownModelIsPreserved() async {
        AuthenticatedMediaPlayerTesting.reset()
        defer { AuthenticatedMediaPlayerTesting.reset() }

        let injected = AuthenticatedMediaPlayerModel()
        let source = dummyMediaSource()
        let host = UIHostingController(
            rootView: AuthenticatedMediaPlayerView(
                source: source,
                height: 180,
                model: injected
            )
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 220))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        await Task.yield()

        #expect(!AuthenticatedMediaPlayerTesting.resolvedModels.isEmpty)
        #expect(
            AuthenticatedMediaPlayerTesting.resolvedModels.allSatisfy {
                $0 == ObjectIdentifier(injected)
            }
        )
    }

    @MainActor
    @Test("full-screen and PiP keep the same player when AVKit detaches the inline host")
    func fullScreenAndPiPKeepPlayerAcrossInlineDetach() {
        let hiddenOffscreen = AuthenticatedMediaPlayerModel()
        hiddenOffscreen.handleDisappear()
        #expect(hiddenOffscreen.debugDidTeardownForTesting)
        #expect(!hiddenOffscreen.debugIsVisibleForTesting)

        let fullScreen = AuthenticatedMediaPlayerModel()
        let fullScreenPlayer = fullScreen.debugInstallStandalonePlayerForTesting()
        let fullScreenTime = fullScreenPlayer.currentTime()

        fullScreen.setFullScreen(true)
        fullScreen.handleDisappear()
        #expect(fullScreen.debugIsVisibleForTesting)
        #expect(!fullScreen.debugDidTeardownForTesting)
        #expect(fullScreen.player === fullScreenPlayer)

        fullScreen.handleWillEndFullScreen()
        #expect(fullScreen.debugIsVisibleForTesting)
        #expect(!fullScreen.debugDidTeardownForTesting)

        fullScreen.handleDidEndFullScreen(hostIsAttached: true)
        #expect(fullScreen.debugIsVisibleForTesting)
        #expect(!fullScreen.debugDidTeardownForTesting)
        #expect(fullScreen.player === fullScreenPlayer)
        #expect(fullScreen.player?.currentTime() == fullScreenTime)

        let detachedHost = AuthenticatedMediaPlayerModel()
        _ = detachedHost.debugInstallStandalonePlayerForTesting()
        detachedHost.setFullScreen(true)
        detachedHost.handleDisappear()
        detachedHost.handleWillEndFullScreen()
        detachedHost.handleDidEndFullScreen(hostIsAttached: false)
        #expect(detachedHost.debugDidTeardownForTesting)
        #expect(detachedHost.player == nil)

        let pictureInPicture = AuthenticatedMediaPlayerModel()
        let pipPlayer = pictureInPicture.debugInstallStandalonePlayerForTesting()
        let pipTime = pipPlayer.currentTime()
        pictureInPicture.setPictureInPicture(true)
        pictureInPicture.handleDisappear()
        #expect(pictureInPicture.debugIsVisibleForTesting)
        #expect(!pictureInPicture.debugDidTeardownForTesting)
        #expect(pictureInPicture.player === pipPlayer)
        pictureInPicture.handleDidStopPictureInPicture(hostIsAttached: true)
        #expect(pictureInPicture.debugIsVisibleForTesting)
        #expect(!pictureInPicture.debugDidTeardownForTesting)
        #expect(pictureInPicture.player === pipPlayer)
        #expect(pictureInPicture.player?.currentTime() == pipTime)
    }

    @MainActor
    @Test("willMove toSuperview nil must not teardown the hosted player")
    func willMoveToSuperviewNilDoesNotTeardownHostedPlayer() async throws {
        let embed = try makeEmbed("![[movie.mp4]]")
        let source = dummyMediaSource()
        let parent = UIViewController()
        let video = NativeMarkdownVideoView()
        parent.view.addSubview(video)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 844))
        window.rootViewController = parent
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        video.apply(
            embed: embed,
            sourceProvider: { _ in source },
            renderingMode: .live,
            preferredDisplayWidth: 320
        )
        for _ in 0..<40 where !video.debugHasPlayerForTesting {
            await Task.yield()
        }
        let installedPlayer = video.debugPlaybackModelForTesting.player
        #expect(video.debugHasPlayerForTesting)

        video.willMove(toSuperview: nil)
        #expect(video.debugHasPlayerForTesting)
        #expect(video.debugPlaybackModelForTesting.player === installedPlayer)

        video.debugPlaybackModelForTesting.setFullScreen(true)
        video.willMove(toSuperview: nil)
        #expect(video.debugHasPlayerForTesting)
        #expect(video.debugPlaybackModelForTesting.player === installedPlayer)

        video.debugPlaybackModelForTesting.setPictureInPicture(true)
        video.willMove(toSuperview: nil)
        #expect(video.debugHasPlayerForTesting)
        #expect(video.debugPlaybackModelForTesting.player === installedPlayer)

        video.prepareForRemoval()
        #expect(!video.debugHasPlayerForTesting)
        #expect(video.debugPlaybackModelForTesting.player == nil)
    }

    @MainActor
    @Test("cancel keeps the resource loader alive until an in-flight CFNetwork session becomes idle")
    func cancelKeepsResourceLoaderAliveUntilInFlightCallbacksFinish() async throws {
        let server = try HangingHTTPServer()
        defer { server.stop() }

        AuthenticatedMediaResourceLoaderTesting.lastCancelRetainedSelfForInFlightCallbacks = false
        var session: AuthenticatedMediaPlaybackSession? = AuthenticatedMediaPlaybackSession(
            source: dummyMediaSource()
        )
        let probe = try #require(session).debugResourceLoaderLifetimeProbe()
        try #require(session).debugStartInFlightResourceRequest(url: server.url)
        try await server.waitUntilAccepted()

        try #require(session).teardown()
        session = nil

        #expect(
            AuthenticatedMediaResourceLoaderTesting.lastCancelRetainedSelfForInFlightCallbacks,
            "secondary: cancelAll took the in-flight retain-self path"
        )
        if probe.isAlive {
            #expect(probe.retainsSelfUntilNetworkIdle)
        }

        server.stop()
        let released = await waitUntil(timeout: .seconds(2)) { !probe.isAlive }
        #expect(released)
    }

    @MainActor
    @Test("applier clear detaches hosted video controllers from the parent")
    func clearDetachesHostedPlayerFromParent() async throws {
        let baseURL = try #require(URL(string: "https://server.example.com"))
        let source = dummyMediaSource()
        let parent = UIViewController()
        let view = AssistantMarkdownContentView()
        view.makeMarkdownVideoSource = { _ in source }
        parent.view.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: parent.view.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: parent.view.trailingAnchor),
            view.topAnchor.constraint(equalTo: parent.view.topAnchor),
            view.bottomAnchor.constraint(equalTo: parent.view.bottomAnchor),
        ])
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 844))
        window.rootViewController = parent
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        view.apply(configuration: .make(
            content: "![[movie.mp4]]",
            isStreaming: false,
            themeID: .dark,
            serverID: "server-a",
            workspaceID: "workspace-a",
            sessionID: "session-a",
            serverBaseURL: baseURL
        ))
        view.layoutIfNeeded()

        var installed = false
        for _ in 0..<40 {
            if let video = timelineFirstView(ofType: NativeMarkdownVideoView.self, in: view),
               video.debugHasPlayerForTesting {
                installed = true
                break
            }
            await Task.yield()
        }
        #expect(installed)
        #expect(!parent.children.isEmpty)

        view.clearContent()
        #expect(timelineFirstView(ofType: NativeMarkdownVideoView.self, in: view) == nil)
        #expect(parent.children.isEmpty)
    }

    @Test("mixed quote text around a video keeps quote chrome")
    func mixedQuoteVideoKeepsQuoteChrome() throws {
        let baseURL = try #require(URL(string: "https://server.example.com"))
        let quote = build("> Watch this ![[movie.mp4]] clip", baseURL: baseURL)
        #expect(quote.segments.contains { if case .video = $0 { return true }; return false })

        let quoteText = quote.segments.compactMap { segment -> String? in
            guard case .text(let text) = segment else { return nil }
            return String(text.characters)
        }.joined()
        #expect(quoteText.contains("▎"))
        #expect(quoteText.contains("Watch this"))
        #expect(quoteText.contains("clip"))
    }

    @Test("quote chrome keeps the border color on the marker and quote color on the text")
    func quoteChromeKeepsDistinctMarkerAndTextColors() throws {
        let baseURL = try #require(URL(string: "https://server.example.com"))
        let palette = ThemeID.dark.palette
        let border = UIColor(palette.mdQuoteBorder)
        let quoteColor = UIColor(palette.mdQuote)
        #expect(!colorsMatch(border, quoteColor))

        let mixed = build("> Watch this ![[movie.mp4]] clip", baseURL: baseURL)
        let mixedTexts = mixed.segments.compactMap { segment -> AttributedString? in
            guard case .text(let text) = segment else { return nil }
            return text
        }
        let markerColor = mixedTexts.compactMap { color(in: $0, at: "▎") }.first
        let quotedColor = mixedTexts.compactMap { color(in: $0, at: "Watch this") }.first
        #expect(colorsMatch(markerColor, border))
        #expect(colorsMatch(quotedColor, quoteColor))
        #expect(!colorsMatch(markerColor, quotedColor))

        let plain = build("> Quoted line", baseURL: baseURL)
        let plainText = try #require(plain.segments.compactMap { segment -> AttributedString? in
            guard case .text(let text) = segment else { return nil }
            return text
        }.first)
        #expect(colorsMatch(color(in: plainText, at: "▎"), border))
        #expect(colorsMatch(color(in: plainText, at: "Quoted line"), quoteColor))
        #expect(!colorsMatch(color(in: plainText, at: "▎"), color(in: plainText, at: "Quoted line")))
    }

    @Test("task-list video embeds stay tappable file links")
    func taskListEmbedsStayActionableLinks() throws {
        let baseURL = try #require(URL(string: "https://server.example.com"))
        let task = build("- [ ] ![[movie.mp4]]", baseURL: baseURL)
        let hasPlayer = task.segments.contains { if case .video = $0 { return true }; return false }
        let taskText = task.segments.compactMap { segment -> AttributedString? in
            guard case .text(let text) = segment else { return nil }
            return text
        }
        let links = taskText.flatMap { $0.runs.compactMap(\.link) }
        #expect(!hasPlayer)
        #expect(!links.isEmpty)
        #expect(!taskText.map { String($0.characters) }.joined().contains("[Video:"))
    }

    @MainActor
    @Test("in-player failure control meets the 44pt Dynamic Type contract")
    func inPlayerFailureControlMeetsHitTarget() async {
        let model = AuthenticatedMediaPlayerModel()
        model.debugForceFailureForTesting("Media failed to load")
        let host = UIHostingController(
            rootView: AuthenticatedMediaPlayerView(
                source: dummyMediaSource(),
                height: 180,
                isActive: false,
                failureActionTitle: "Open video file",
                onFailureAction: {},
                model: model
            )
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 220))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        for _ in 0..<10 {
            if failureControl(in: host.view) != nil { break }
            await Task.yield()
            host.view.layoutIfNeeded()
        }

        let button = failureControl(in: host.view)
        #expect(button != nil)
        if let button {
            #expect(button.bounds.height >= 44)
            #expect(button.bounds.width >= 44)
        }

        host.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        await Task.yield()
        if let resized = failureControl(in: host.view) {
            #expect(resized.bounds.height >= 44)
        }
    }

    private func dummyMediaSource() -> AuthenticatedMediaSource {
        AuthenticatedMediaSource(
            url: URL(fileURLWithPath: "/tmp/oppi-missing-inline-video.mp4"),
            authorizationHeaderValue: "Bearer test",
            tlsCertFingerprint: nil,
            contentTypeHint: "video/mp4",
            sourceFileExtension: "mp4"
        )
    }

    private func makeEmbed(_ markdown: String) throws -> MarkdownVideoEmbed {
        let baseURL = try #require(URL(string: "https://server.example.com"))
        return try #require(build(markdown, baseURL: baseURL).segments.compactMap { segment -> MarkdownVideoEmbed? in
            guard case .video(let embed) = segment else { return nil }
            return embed
        }.first)
    }

    private func build(_ markdown: String, baseURL: URL) -> FlatSegment.BuildResult {
        FlatSegment.buildWithSourceLineRanges(
            from: parseCommonMarkLocated(markdown),
            themeID: .dark,
            serverID: "server-a",
            workspaceID: "workspace-a",
            sessionID: "session-a",
            serverBaseURL: baseURL,
            mergeAdjacentTextSegments: false
        )
    }

    private func color(in text: AttributedString, at substring: String) -> UIColor? {
        let ns = NSAttributedString(text)
        let range = (ns.string as NSString).range(of: substring)
        guard range.location != NSNotFound else { return nil }
        return ns.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? UIColor
    }

    private func colorsMatch(_ lhs: UIColor?, _ rhs: UIColor?) -> Bool {
        guard let lhs, let rhs else { return false }
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        lhs.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        rhs.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return abs(r1 - r2) < 0.02
            && abs(g1 - g2) < 0.02
            && abs(b1 - b2) < 0.02
            && abs(a1 - a2) < 0.02
    }

    @MainActor
    private func failureControl(in root: UIView) -> UIView? {
        timelineAllViews(in: root).first { view in
            if view.accessibilityIdentifier == "authenticated-media-failure-action" {
                return true
            }
            if let button = view as? UIButton {
                return button.currentTitle == "Open video file"
                    || button.configuration?.title == "Open video file"
                    || button.accessibilityIdentifier == "authenticated-media-failure-action"
            }
            return false
        }
    }
}

@MainActor
private final class FileBrowserPlayerRebuildKnob: ObservableObject {
    @Published var height: CGFloat = 400
}

private struct FileBrowserStylePlayerHost: View {
    let source: AuthenticatedMediaSource
    @ObservedObject var knob: FileBrowserPlayerRebuildKnob

    var body: some View {
        GeometryReader { geometry in
            AuthenticatedMediaPlayerView(
                source: source,
                height: min(max(geometry.size.height * 0.34, 220), 420),
                unavailableTitle: "Video preview unavailable",
                unavailableSystemImage: "film.slash"
            )
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: knob.height)
    }
}

private func waitUntil(
    timeout: Duration,
    _ condition: @escaping @Sendable () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// Accepts TCP clients and never writes a response so a URLSession task stays
/// in-flight until `stop()` closes the socket. Accept and stop share one
/// condition so a late `accept()` cannot leak an fd after `stop()` snapshots.
private final class HangingHTTPServer: @unchecked Sendable {
    private let listenFD: Int32
    private let acceptQueue = DispatchQueue(label: "dev.chenda.oppi.tests.hanging-http")
    private let condition = NSCondition()
    private var clientFDs: [Int32] = []
    private var stopped = false
    private var acceptedCount = 0
    let url: URL

    init() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw CocoaError(.fileWriteUnknown)
        }

        var reuse: Int32 = 1
        Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        addr.sin_port = 0

        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(fd, 16) == 0 else {
            Darwin.close(fd)
            throw CocoaError(.fileWriteUnknown)
        }

        var bound = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &boundLen)
            }
        }
        let port = UInt16(bigEndian: bound.sin_port)
        guard nameResult == 0,
              port > 0,
              let url = URL(string: "http://127.0.0.1:\(port)/video.mp4") else {
            Darwin.close(fd)
            throw CocoaError(.fileWriteUnknown)
        }

        listenFD = fd
        self.url = url
        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    func waitUntilAccepted(timeout: TimeInterval = 2) async throws {
        let accepted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                continuation.resume(returning: self.waitUntilAcceptedSync(timeout: timeout))
            }
        }
        guard accepted else {
            throw CocoaError(.fileReadUnknown)
        }
    }

    func stop() {
        condition.lock()
        let alreadyStopped = stopped
        stopped = true
        let clients = clientFDs
        clientFDs.removeAll()
        condition.broadcast()
        condition.unlock()
        guard !alreadyStopped else { return }
        Darwin.shutdown(listenFD, SHUT_RDWR)
        Darwin.close(listenFD)
        for client in clients {
            Darwin.close(client)
        }
    }

    deinit {
        stop()
    }

    private func waitUntilAcceptedSync(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        while acceptedCount == 0 && !stopped {
            if !condition.wait(until: deadline) {
                break
            }
        }
        let accepted = acceptedCount > 0
        condition.unlock()
        return accepted
    }

    private func acceptLoop() {
        while true {
            let client = Darwin.accept(listenFD, nil, nil)
            condition.lock()
            if stopped {
                condition.unlock()
                if client >= 0 {
                    Darwin.close(client)
                }
                return
            }
            if client < 0 {
                condition.unlock()
                return
            }
            clientFDs.append(client)
            acceptedCount += 1
            condition.broadcast()
            condition.unlock()
        }
    }
}
