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
            "render-ahead resolve must store the source without UIHostingController containment"
        )

        let parent = UIViewController()
        parent.view.addSubview(video)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 844))
        window.rootViewController = parent
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        video.setPlaybackVisible(true)
        #expect(video.debugHasPlayerForTesting)
        #expect(video.debugHostingParentForTesting === parent)
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

    @Test("first mermaid reveal at the inactive default height force-invalidates; same-height second raster does not")
    func mermaidHeightUnchangedDoesNotForceInvalidate() async throws {
        // Natural width is 1 so scale stays 1 for any real bounds. That pins
        // the first reveal to the inactive 200pt default instead of a
        // bounds-scaled height that would already look like a change.
        let result = NativeMermaidBlockView.RasterResult(
            image: solidImage(color: .red),
            size: CGSize(width: 1, height: 200)
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
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 200)
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
            code: "graph TD\n    A-->B",
            palette: ThemeID.dark.palette
        )
        for _ in 0..<40 where !view.debugIsShowingDiagramForTesting {
            await Task.yield()
        }
        #expect(view.debugIsShowingDiagramForTesting)
        #expect(view.debugDiagramHeightConstraintIsActiveForTesting)
        #expect(abs((view.debugDiagramHeightConstantForTesting ?? 0) - 200) <= 0.5)
        let invalidationsAfterFirst = view.debugInvalidateTimelineLayoutCountForTesting
        #expect(
            invalidationsAfterFirst >= 1,
            "first reveal must force-invalidate even when the raster height matches the inactive 200pt default"
        )
        #expect(
            hostedInvalidations >= 1,
            "first reveal must force-invalidate the enclosing collection view"
        )
        #expect(
            !invalidationSawInactiveConstraint && !invalidationSawHiddenDiagram,
            "force-invalidation must wait until the diagram constraint is active and the placeholder is gone"
        )
        #expect(abs((hostedHeightAtInvalidation ?? 0) - 200) <= 0.5)

        view.applyAsDiagram(
            code: "graph TD\n    A-->C",
            palette: ThemeID.dark.palette
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

    private func makeEmbed(_ markdown: String) throws -> MarkdownVideoEmbed {
        let baseURL = try #require(URL(string: "https://server.example.com"))
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
            serverID: "server-a",
            workspaceID: "workspace-a",
            sessionID: "session-a",
            serverBaseURL: URL(string: "https://server.example.com")
        )
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
