import Foundation
import Testing
import UIKit
@testable import Oppi

@Suite("Markdown stress crash regressions")
@MainActor
struct MarkdownStressCrashRegressionTests {
    @Test("probe/async resolve does not create a host until visible in a window")
    func probeAsyncResolveDoesNotCreateHostUntilVisible() async throws {
        let embed = try makeEmbed("![[movie.mp4]]")
        let source = dummyMediaSource()
        let video = NativeMarkdownVideoView()
        video.setPlaybackVisible(false)

        var resume: CheckedContinuation<AuthenticatedMediaSource, Error>?
        video.apply(
            embed: embed,
            sourceProvider: { _ in
                try await withCheckedThrowingContinuation { continuation in
                    resume = continuation
                }
            },
            renderingMode: .staticReader,
            preferredDisplayWidth: 320
        )

        for _ in 0..<40 where resume == nil {
            await Task.yield()
        }
        let pending = try #require(resume)
        #expect(!video.debugHasPlayerForTesting)

        pending.resume(returning: source)
        for _ in 0..<40 where !video.debugHasCurrentSourceForTesting {
            await Task.yield()
        }

        #expect(video.debugHasCurrentSourceForTesting)
        #expect(
            !video.debugHasPlayerForTesting,
            "render-ahead resolve must store the source without AVPlayerViewController containment"
        )

        let parent = UIViewController()
        parent.view.addSubview(video)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 844))
        window.rootViewController = parent
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        video.setPlaybackVisible(true)
        #expect(await waitUntil { video.debugHasPlayerForTesting })
        try expectPlayerScrollsWithHost(video, screenParent: parent)
    }

    enum LinkedFileSourceTiming: String, CaseIterable, Sendable {
        /// Source resolves as soon as render-ahead asks, before the reader is revealed.
        case beforeReveal
        /// Source resolves while the navigation push animation is running.
        case duringPush
    }

    @Test(
        "animated linked-file push mounts the inline video player after the reader appears",
        arguments: LinkedFileSourceTiming.allCases
    )
    func linkedFilePushMountsVideoAfterAppearance(timing: LinkedFileSourceTiming) async throws {
        let gate = VideoSourceGate()
        let reader = try makeLinkedFileReader(gate: gate)
        let root = UIViewController()
        let navigation = UINavigationController(rootViewController: root)
        let window = try makeSceneWindow(root: navigation)
        defer { window.isHidden = true }
        await settleRunLoop()

        if timing == .beforeReveal {
            gate.resolveImmediately = true
        }
        navigation.pushViewController(reader, animated: true)
        if timing == .duringPush {
            #expect(await waitUntil { gate.pendingCount > 0 }, "reader never asked for the video source")
            #expect(navigation.transitionCoordinator != nil, "source must resolve while the push is in flight")
            gate.resolveAll()
        }

        #expect(await waitUntil {
            navigation.transitionCoordinator == nil && reader.view.window != nil
        }, "push did not finish")
        #expect(await waitUntil { visibleVideo(in: reader)?.debugHasPlayerForTesting == true },
                "visible reader video never mounted its player after appearance")
        let video = try #require(visibleVideo(in: reader))
        try expectPlayerContained(in: video, reader: reader)
    }

    @Test("a reader popped before its video source resolves never mounts a late player")
    func poppedLinkedFileReaderDoesNotMountLatePlayer() async throws {
        let gate = VideoSourceGate()
        let reader = try makeLinkedFileReader(gate: gate)
        let root = UIViewController()
        let navigation = UINavigationController(rootViewController: root)
        let window = try makeSceneWindow(root: navigation)
        defer { window.isHidden = true }
        await settleRunLoop()

        navigation.pushViewController(reader, animated: true)
        #expect(await waitUntil { gate.pendingCount > 0 }, "reader never asked for the video source")
        #expect(await waitUntil {
            navigation.transitionCoordinator == nil && reader.view.window != nil
        }, "push did not finish")
        let videos = allVideos(in: reader)
        #expect(!videos.isEmpty)

        navigation.popViewController(animated: true)
        #expect(await waitUntil {
            navigation.transitionCoordinator == nil && reader.view.window == nil
        }, "pop did not finish")
        gate.resolveAll()
        await settleRunLoop()

        for video in videos {
            #expect(!video.debugHasPlayerForTesting, "removed reader mounted a late player")
            #expect(video.debugPlayerSlotForTesting?.parent == nil)
        }
    }

    @Test("prepareForRemoval before a scheduled first mount leaves no player")
    func prepareForRemovalCancelsScheduledFirstMount() async throws {
        let embed = try makeEmbed("![[movie.mp4]]")
        let parent = UIViewController()
        let video = NativeMarkdownVideoView()
        parent.view.addSubview(video)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 844))
        window.rootViewController = parent
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        var resume: CheckedContinuation<AuthenticatedMediaSource, Error>?
        video.apply(
            embed: embed,
            sourceProvider: { _ in
                try await withCheckedThrowingContinuation { resume = $0 }
            },
            renderingMode: .live,
            preferredDisplayWidth: 320
        )
        for _ in 0..<40 where resume == nil {
            await Task.yield()
        }
        try #require(resume).resume(returning: dummyMediaSource())
        // Resolve lands on the next main-actor turn; remove right after it,
        // before the reveal/window-arrival mount attempt has run.
        for _ in 0..<40 where !video.debugHasCurrentSourceForTesting {
            await Task.yield()
        }
        #expect(video.debugHasCurrentSourceForTesting)
        video.prepareForRemoval()
        await settleRunLoop()

        #expect(!video.debugHasPlayerForTesting)
        #expect(parent.children.isEmpty, "a cancelled first mount must not adopt a slot controller")
    }

    @Test("prepareForRemoval cancels a pending resolve so it cannot install a host")
    func prepareForRemovalCancelsPendingResolve() async throws {
        let embed = try makeEmbed("![[movie.mp4]]")
        let source = dummyMediaSource()
        let video = NativeMarkdownVideoView()

        var resume: CheckedContinuation<AuthenticatedMediaSource, Error>?
        video.apply(
            embed: embed,
            sourceProvider: { _ in
                try await withCheckedThrowingContinuation { continuation in
                    resume = continuation
                }
            },
            renderingMode: .live,
            preferredDisplayWidth: 320
        )
        for _ in 0..<40 where resume == nil {
            await Task.yield()
        }
        let pending = try #require(resume)

        video.prepareForRemoval()
        pending.resume(returning: source)
        for _ in 0..<20 {
            await Task.yield()
        }

        #expect(!video.debugHasCurrentSourceForTesting)
        #expect(!video.debugHasPlayerForTesting)
    }

    @Test("streaming apply does not re-touch frozen prefix tables or mermaid")
    func streamingApplyDoesNotRetouchFrozenPrefix() throws {
        let prefix = """
        | H |
        | - |
        | 1 |

        ```mermaid
        graph TD
        A-->B
        ```

        ```mermaid
        graph TD
        X-->
        """
        let next = prefix + "Y"

        let stack = UIStackView()
        let applier = AssistantMarkdownSegmentApplier(
            stackView: stack,
            textViewDelegate: StreamingApplyTextViewDelegate()
        )
        applier.apply(
            segments: makeSegments(prefix),
            config: makeStreamingConfig(prefix)
        )

        let prefixMermaid = try #require(
            stack.arrangedSubviews.compactMap { $0 as? NativeMermaidBlockView }.first
        )
        let prefixDiagramApplies = prefixMermaid.debugApplyAsDiagramCallCountForTesting
        #expect(prefixDiagramApplies >= 1)
        #expect(applier.debugInPlaceTableApplyCountForTesting == 0)
        #expect(stack.arrangedSubviews.contains { $0 is NativeTableBlockView })

        applier.apply(
            segments: makeSegments(next),
            config: makeStreamingConfig(next)
        )

        let prefixMermaidAfter = try #require(
            stack.arrangedSubviews.compactMap { $0 as? NativeMermaidBlockView }.first
        )
        #expect(prefixMermaidAfter === prefixMermaid)
        #expect(applier.debugInPlaceTableApplyCountForTesting == 0)
        #expect(
            prefixMermaidAfter.debugApplyAsDiagramCallCountForTesting == prefixDiagramApplies,
            "closed prefix mermaid must stay frozen while the open tail fence grows"
        )
        #expect(
            applier.debugInPlaceMermaidApplyCountForTesting == 1,
            "only the open tail mermaid may be updated in place while streaming"
        )
    }

    @Test("reserved layout height force-invalidates once; matching raster does not")
    func mermaidHeightUnchangedDoesNotForceInvalidate() async throws {
        let code = "graph TD\n    A-->B"
        let availableWidth: CGFloat = 360
        let layout = DocumentRenderPipeline.layoutGraphical(
            parser: MermaidParser(),
            renderer: MermaidRenderer(),
            text: code,
            config: DocumentRenderPipeline.mermaidConfiguration(
                theme: ThemeID.dark.palette.renderTheme
            )
        )
        let scale = min(1.0, availableWidth / max(layout.size.width, 1))
        let expectedHeight = max(1, min(layout.size.height * scale, 400))
        let result = NativeMermaidBlockView.RasterResult(
            image: solidImage(color: .red),
            size: layout.size
        )
        let view = NativeMermaidBlockView(rasterizer: .init(
            renderSync: { _, _, _ in result },
            renderAsync: { _, _, _ in result }
        ))
        // Existing force-invalidate hook only fires with a collection ancestor.
        let collectionView = UICollectionView(
            frame: CGRect(x: 0, y: 0, width: 360, height: 400),
            collectionViewLayout: UICollectionViewFlowLayout()
        )
        collectionView.addSubview(view)
        view.frame = CGRect(x: 0, y: 0, width: availableWidth, height: 200)
        view.layoutIfNeeded()

        var hostedInvalidations = 0
        var invalidationSawInactiveConstraint = false
        var invalidationSawHiddenDiagram = false
        var hostedHeightAtInvalidation: CGFloat?
        ToolTimelineRowPresentationHelpers.forcedEnclosingLayoutInvalidationHookForTesting = { target in
            guard target === collectionView else { return }
            hostedInvalidations += 1
            if view.debugDiagramHeightConstraintIsActiveForTesting != true {
                invalidationSawInactiveConstraint = true
            }
            if !view.debugIsShowingDiagramForTesting {
                invalidationSawHiddenDiagram = true
            }
            hostedHeightAtInvalidation = view.debugDiagramHeightConstantForTesting
        }
        defer {
            ToolTimelineRowPresentationHelpers.forcedEnclosingLayoutInvalidationHookForTesting = nil
        }

        view.applyAsDiagram(
            code: code,
            palette: ThemeID.dark.palette,
            availableWidth: availableWidth
        )
        for _ in 0..<40 where !view.debugIsShowingDiagramForTesting {
            await Task.yield()
        }
        #expect(view.debugIsShowingDiagramForTesting)
        #expect(view.debugDiagramHeightConstraintIsActiveForTesting)
        #expect(abs((view.debugDiagramHeightConstantForTesting ?? 0) - expectedHeight) <= 0.5)
        let invalidationsAfterFirst = view.debugInvalidateTimelineLayoutCountForTesting
        #expect(
            invalidationsAfterFirst >= 1,
            "reserving layout height must force-invalidate the timeline"
        )
        #expect(
            hostedInvalidations >= 1,
            "reserving layout height must force-invalidate the enclosing collection view"
        )
        #expect(
            !invalidationSawInactiveConstraint && !invalidationSawHiddenDiagram,
            "force-invalidation must wait until the diagram constraint is active and the placeholder is gone"
        )
        #expect(abs((hostedHeightAtInvalidation ?? 0) - expectedHeight) <= 0.5)

        view.applyAsDiagram(
            code: code,
            palette: ThemeID.dark.palette,
            availableWidth: availableWidth
        )
        for _ in 0..<40 where view.debugRenderedImageForTesting == nil {
            await Task.yield()
        }
        await Task.yield()
        await Task.yield()

        #expect(
            view.debugInvalidateTimelineLayoutCountForTesting == invalidationsAfterFirst,
            "a same-height raster must not force-invalidate the enclosing timeline layout"
        )
        #expect(
            hostedInvalidations == invalidationsAfterFirst,
            "a same-height already-displayed raster must not force-invalidate the collection host"
        )
    }

    private func makeLinkedFileReader(gate: VideoSourceGate) throws -> FullScreenCodeViewController {
        let context = MarkdownResourceAccess(
            identity: .init(
                serverID: "server-a",
                workspaceID: "workspace-a",
                sessionID: "session-a",
                serverBaseURL: testUnwrap(URL(string: "https://server.example.com"))
            ),
            fetchWorkspaceFile: { _, _ in Data() },
            makeMarkdownVideoSource: { _ in try await gate.source() }
        )
        return FullScreenCodeViewController(
            content: .markdown(
                content: "# Corpus\n\nIntro paragraph.\n\n![[clip.mp4]]\n\nAfter the clip.",
                filePath: ".internal/qa/markdown-viewer-corpus.md",
                resourceAccess: context
            ),
            presentationMode: .embedded(onDismiss: {})
        )
    }

    /// Navigation transitions only animate and complete in a scene-backed window.
    private func makeSceneWindow(root: UIViewController) throws -> UIWindow {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "animated push needs the test host's window scene"
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 844)
        window.rootViewController = root
        window.makeKeyAndVisible()
        return window
    }

    private func allVideos(in reader: UIViewController) -> [NativeMarkdownVideoView] {
        timelineAllViews(in: reader.view).compactMap { $0 as? NativeMarkdownVideoView }
    }

    /// The video actually shown in a collection cell, not a parked render-ahead copy.
    private func visibleVideo(in reader: UIViewController) -> NativeMarkdownVideoView? {
        allVideos(in: reader).first { $0.window != nil && timelineViewIsVisible($0) }
    }

    /// UIKit containment: the slot hangs off a view controller whose view
    /// encloses the video, and AVKit's view lives inside the video host.
    private func expectPlayerContained(
        in video: NativeMarkdownVideoView,
        reader: UIViewController
    ) throws {
        let player = try #require(video.debugPlayerControllerForTesting)
        let slot = try #require(video.debugPlayerSlotForTesting)
        let slotParent = try #require(slot.parent)
        #expect(player.parent === slot)
        #expect(player.view.isDescendant(of: video))
        #expect(slot.view.superview === video)
        #expect(video.isDescendant(of: slotParent.view))
        var ancestor: UIViewController? = slotParent
        while let node = ancestor, node !== reader { ancestor = node.parent }
        #expect(ancestor === reader, "slot must be contained inside the reader's controller tree")
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// Lets queued main-queue work, CATransaction completions, and any
    /// deferred mount attempt run before asserting absence.
    private func settleRunLoop() async {
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func makeEmbed(_ markdown: String) throws -> MarkdownVideoEmbed {
        let baseURL = testUnwrap(URL(string: "https://server.example.com"))
        return try #require(makeSegments(markdown, baseURL: baseURL).compactMap { segment -> MarkdownVideoEmbed? in
            guard case .video(let embed) = segment else { return nil }
            return embed
        }.first)
    }

    private func makeSegments(
        _ markdown: String,
        baseURL: URL? = URL(string: "https://server.example.com")
    ) -> [FlatSegment] {
        FlatSegment.build(
            from: parseCommonMark(markdown),
            themeID: .dark,
            serverID: "server-a",
            workspaceID: "workspace-a",
            sessionID: "session-a",
            serverBaseURL: baseURL
        )
    }

    private func makeStreamingConfig(_ content: String) -> AssistantMarkdownContentView.Configuration {
        .make(
            content: content,
            isStreaming: true,
            themeID: .dark,
            resourceAccess: MarkdownResourceAccess(
                identity: .init(
                    serverID: "server-a",
                    workspaceID: "workspace-a",
                    sessionID: "session-a",
                    serverBaseURL: URL(string: "https://server.example.com")
                )
            )
        )
    }

    @MainActor
    private func expectPlayerScrollsWithHost(
        _ video: NativeMarkdownVideoView,
        screenParent: UIViewController
    ) throws {
        let player = try #require(video.debugPlayerControllerForTesting)
        let slot = try #require(video.debugPlayerSlotForTesting)
        #expect(player.view.isDescendant(of: video))
        #expect(slot.view.isDescendant(of: video))
        #expect(player.parent === slot)
        #expect(slot !== screenParent)
        #expect(screenParent.children.contains { $0 === slot })
        #expect(slot.children.contains { $0 === player })
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

    private func solidImage(color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }
}

@MainActor
private final class StreamingApplyTextViewDelegate: NSObject, UITextViewDelegate {}

/// Controlled media-source resolution for the reader's video provider.
@MainActor
private final class VideoSourceGate {
    var resolveImmediately = false
    private var pending: [CheckedContinuation<AuthenticatedMediaSource, Error>] = []

    var pendingCount: Int { pending.count }

    func source() async throws -> AuthenticatedMediaSource {
        if resolveImmediately {
            return Self.source
        }
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }

    /// Resolves every waiter and answers later requests immediately.
    func resolveAll() {
        resolveImmediately = true
        let waiting = pending
        pending.removeAll()
        waiting.forEach { $0.resume(returning: Self.source) }
    }

    private static let source = AuthenticatedMediaSource(
        url: URL(fileURLWithPath: "/tmp/oppi-missing-inline-video.mp4"),
        authorizationHeaderValue: "Bearer test",
        tlsCertFingerprint: nil,
        contentTypeHint: "video/mp4",
        sourceFileExtension: "mp4"
    )
}
