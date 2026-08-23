import Testing
import UIKit
import WebKit
@testable import Oppi

@Suite("Full-screen markdown async rendering")
struct FullScreenMarkdownAsyncRenderTests {
    /// Regression: the full-screen markdown reader renders LaTeX (and Mermaid)
    /// blocks synchronously so self-sizing cells measure their final height on
    /// the first layout pass. Previously the async formula settlement called
    /// `forceInvalidateEnclosingCollectionViewLayout`, which — inside the
    /// reader's plain collection view — invalidated layout with no viewport
    /// anchor, re-estimated off-screen cells at the 44pt placeholder height,
    /// and visibly jumped the scroll position while reading near a formula.
    @MainActor
    @Test("reader LaTeX settlement must not shift scroll offset or content size")
    func staticReaderLatexSettlementKeepsScrollStable() async throws {
        let before = (0..<3).map { "Filler prose before the formula, paragraph \($0), long enough to build scroll height." }
            .joined(separator: "\n\n")
        let after = (0..<30).map { "Filler prose after the formula, paragraph \($0), long enough to build scroll height." }
            .joined(separator: "\n\n")
        let formula = #"""
        $$
        \begin{bmatrix}1\\2\\3\\4\end{bmatrix}
        $$
        """#
        let content = "# Orchestration\n\n\(before)\n\n\(formula)\n\n\(after)"

        let body = NativeFullScreenMarkdownBody(
            content: content,
            stream: nil,
            palette: ThemeID.dark.palette,
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.addSubview(body)
        body.frame = window.bounds
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        body.layoutIfNeeded()
        let collectionView = try #require(timelineFirstView(ofType: UICollectionView.self, in: body))
        collectionView.layoutIfNeeded()
        await drainMarkdownHeightFlush()
        body.layoutIfNeeded()
        collectionView.layoutIfNeeded()

        // The formula cell sits near the top of the document, so it is on
        // screen from the initial layout pass.
        let latexView = timelineFirstView(ofType: NativeLatexBlockView.self, in: collectionView)
        let formulaView = try #require(
            latexView,
            "formula cell was not instantiated at initial layout"
        )

        // Core assertion: the reader renders LaTeX synchronously, so the
        // formula is fully settled at first self-sizing. An async render
        // (.live) would leave the placeholder code block here and resize the
        // cell later — the source of the reader's scroll jumps.
        #expect(
            formulaView.accessibilityIdentifier == "latex.formula.open",
            "LaTeX block was not rendered synchronously in the full-screen reader"
        )

        // Behavioral guard: after draining any pending async settlement, the
        // viewport must not have moved and the document must not have resized.
        let offsetBefore = collectionView.contentOffset.y
        let contentSizeBefore = collectionView.contentSize.height
        try await Task.sleep(for: .milliseconds(600))
        body.layoutIfNeeded()
        collectionView.layoutIfNeeded()

        #expect(
            abs(collectionView.contentOffset.y - offsetBefore) < 1,
            "scroll offset jumped after LaTeX settlement: \(offsetBefore) -> \(collectionView.contentOffset.y)"
        )
        #expect(
            abs(collectionView.contentSize.height - contentSizeBefore) < 1,
            "content size changed after LaTeX settlement: \(contentSizeBefore) -> \(collectionView.contentSize.height)"
        )

        // Cell reuse: scroll the formula off screen and back. The reused cell
        // must re-settle synchronously (render cache hit, no async resize),
        // otherwise every re-entry into the LaTeX region repeats the jump.
        collectionView.contentOffset.y = max(
            -collectionView.adjustedContentInset.top,
            collectionView.contentSize.height
                - collectionView.bounds.height
                + collectionView.adjustedContentInset.bottom
        )
        collectionView.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        collectionView.contentOffset.y = -collectionView.adjustedContentInset.top
        collectionView.layoutIfNeeded()

        let reusedLatexView = try #require(
            timelineFirstView(ofType: NativeLatexBlockView.self, in: collectionView),
            "formula cell was not re-created after scrolling back"
        )
        #expect(
            reusedLatexView.accessibilityIdentifier == "latex.formula.open",
            "reused LaTeX cell did not settle synchronously after scrolling back"
        )
        #expect(
            abs(collectionView.contentOffset.y - (-collectionView.adjustedContentInset.top)) < 1,
            "scroll offset jumped after formula cell reuse"
        )
    }

    /// Mermaid blocks share the reader's synchronous height-changing render
    /// path with LaTeX; pin the same settlement contract for diagrams.
    @MainActor
    @Test("reader Mermaid diagram must render synchronously")
    func staticReaderMermaidSettlementIsSynchronous() async throws {
        let after = (0..<6).map { "Prose after the diagram, paragraph \($0)." }
            .joined(separator: "\n\n")
        let content = """
        # Diagrams

        ```mermaid
        graph TD
        A-->B
        ```

        \(after)
        """

        let body = NativeFullScreenMarkdownBody(
            content: content,
            stream: nil,
            palette: ThemeID.dark.palette,
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.addSubview(body)
        body.frame = window.bounds
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        body.layoutIfNeeded()
        let collectionView = try #require(timelineFirstView(ofType: UICollectionView.self, in: body))
        collectionView.layoutIfNeeded()
        await drainMarkdownHeightFlush()
        body.layoutIfNeeded()
        collectionView.layoutIfNeeded()

        let mermaidView = try #require(
            timelineFirstView(ofType: NativeMermaidBlockView.self, in: collectionView),
            "diagram cell was not instantiated at initial layout"
        )
        let diagramImageView = try #require(
            timelineAllImageViews(in: mermaidView).first(where: { !$0.isHidden }),
            "diagram image view was not visible after synchronous render"
        )
        #expect(
            diagramImageView.image != nil,
            "Mermaid diagram was not rendered synchronously in the full-screen reader"
        )

        // Behavioral guard: draining the runloop must not resize the document.
        let contentSizeBefore = collectionView.contentSize.height
        let offsetBefore = collectionView.contentOffset.y
        try await Task.sleep(for: .milliseconds(600))
        body.layoutIfNeeded()
        collectionView.layoutIfNeeded()
        #expect(
            abs(collectionView.contentSize.height - contentSizeBefore) < 1,
            "content size changed after Mermaid settlement: \(contentSizeBefore) -> \(collectionView.contentSize.height)"
        )
        #expect(
            abs(collectionView.contentOffset.y - offsetBefore) < 1,
            "scroll offset jumped after Mermaid settlement"
        )

        // Shared park/reuse guard: scroll the diagram off screen and back.
        // The segment views must survive leave-and-return whether the cell was
        // recycled (park host reinstall) or kept alive by UIKit (no dequeue).
        collectionView.contentOffset.y = max(
            -collectionView.adjustedContentInset.top,
            collectionView.contentSize.height
                - collectionView.bounds.height
                + collectionView.adjustedContentInset.bottom
        )
        collectionView.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        collectionView.contentOffset.y = -collectionView.adjustedContentInset.top
        collectionView.layoutIfNeeded()

        let reusedMermaidView = try #require(
            timelineFirstView(ofType: NativeMermaidBlockView.self, in: collectionView),
            "diagram view did not survive scrolling away and back"
        )
        let reusedDiagramImage = try #require(
            timelineAllImageViews(in: reusedMermaidView).first(where: { !$0.isHidden }),
            "reused diagram image view was not visible after scrolling back"
        )
        #expect(
            reusedDiagramImage.image != nil,
            "reused Mermaid diagram did not stay rendered after scrolling back"
        )
    }

    /// Regression: embedded rendered visuals must be able to drill down from
    /// the already-presented Markdown reader without replacing or rebuilding it.
    @MainActor
    @Test("reader Mermaid and LaTeX taps open one focused preview and preserve position")
    func readerVisualTapsOpenFocusedPreviewWithoutStacking() async throws {
        let animationsWereEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(animationsWereEnabled) }

        let before = (0..<2)
            .map { "Reader-position filler paragraph \($0), long enough to offset the visual blocks." }
            .joined(separator: "\n\n")
        let after = (0..<24)
            .map { "Trailing filler paragraph \($0), long enough to keep the document scrollable." }
            .joined(separator: "\n\n")
        let content = """
        # Visual previews

        \(before)

        ```mermaid
        graph TD
        A-->B
        ```

        $$
        \\int_0^1 x^2 \\, dx = \\frac{1}{3}
        $$

        \(after)
        """
        let fixture = makeWindowedReader(content: content)
        defer { fixture.window.isHidden = true }

        let collectionView = try #require(
            timelineFirstView(ofType: UICollectionView.self, in: fixture.reader.view)
        )
        collectionView.layoutIfNeeded()
        let readingOffset = min(
            280,
            max(
                -collectionView.adjustedContentInset.top,
                collectionView.contentSize.height
                    - collectionView.bounds.height
                    + collectionView.adjustedContentInset.bottom
            )
        )
        collectionView.setContentOffset(
            CGPoint(x: collectionView.contentOffset.x, y: readingOffset),
            animated: false
        )
        collectionView.layoutIfNeeded()
        let preservedReadingOffset = collectionView.contentOffset.y

        let mermaid = try #require(
            timelineFirstView(ofType: NativeMermaidBlockView.self, in: fixture.reader.view)
        )
        #expect(
            UIApplication.shared.sendAction(
                NSSelectorFromString("handleTap"),
                to: mermaid,
                from: nil,
                for: nil
            )
        )
        let mermaidPreview = try #require(
            fixture.reader.presentedViewController as? FullScreenCodeViewController,
            "Mermaid tap from the full-screen Markdown reader did not open a focused preview"
        )
        mermaidPreview.loadViewIfNeeded()
        let mermaidAppeared = await waitForTimelineCondition(timeoutMs: 500) { @MainActor in
            mermaidPreview.view.window != nil && mermaidPreview.transitionCoordinator == nil
        }
        #expect(mermaidAppeared)

        // Replaying the source action while the focused viewer is already open
        // must not grow another modal layer.
        _ = UIApplication.shared.sendAction(
            NSSelectorFromString("handleTap"),
            to: mermaid,
            from: nil,
            for: nil
        )
        #expect(mermaidPreview.presentedViewController == nil)
        fixture.reader.dismiss(animated: false)
        let mermaidDismissed = await waitForTimelineCondition(timeoutMs: 500) { @MainActor in
            fixture.reader.presentedViewController == nil
        }
        #expect(mermaidDismissed)
        #expect(abs(collectionView.contentOffset.y - preservedReadingOffset) < 1)

        let latex = try #require(
            timelineFirstView(ofType: NativeLatexBlockView.self, in: fixture.reader.view)
        )
        #expect(
            UIApplication.shared.sendAction(
                NSSelectorFromString("handleTap"),
                to: latex,
                from: nil,
                for: nil
            )
        )
        let latexPreview = try #require(
            fixture.reader.presentedViewController as? FullScreenCodeViewController,
            "LaTeX tap from the full-screen Markdown reader did not open a focused preview"
        )
        #expect(latexPreview !== mermaidPreview)
        latexPreview.loadViewIfNeeded()
        let latexAppeared = await waitForTimelineCondition(timeoutMs: 500) { @MainActor in
            latexPreview.view.window != nil && latexPreview.transitionCoordinator == nil
        }
        #expect(latexAppeared)
        fixture.reader.dismiss(animated: false)
        let latexDismissed = await waitForTimelineCondition(timeoutMs: 500) { @MainActor in
            fixture.reader.presentedViewController == nil
        }
        #expect(latexDismissed)
        #expect(abs(collectionView.contentOffset.y - preservedReadingOffset) < 1)
    }

    @MainActor
    @Test("image inspection derives MIME from bytes without a usable extension")
    func imageInspectionDerivesMimeTypeFromBytes() throws {
        let gif = try #require(Data(
            base64Encoded: "R0lGODlhAgACAIEAAP8AAAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAAAgACAAAIBgABCAQQEAAh+QQBCgABACwAAAAAAgACAIEAAP8AAAAAAAAAAAAIBgABCAQQEAA7"
        ))
        let webP = try #require(Data(
            base64Encoded: "UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEADsD+JaQAA3AAAAAA"
        ))
        let png = try #require(makePreviewTestImage().pngData())

        #expect(ImageMediaInspector.inspect(data: gif, mimeType: nil).normalizedMimeType == "image/gif")
        #expect(ImageMediaInspector.inspect(data: webP, mimeType: nil).normalizedMimeType == "image/webp")
        #expect(
            ImageMediaInspector.inspect(data: png, mimeType: "image/gif").normalizedMimeType == "image/png",
            "PNG/APNG bytes must override a stale extension-derived GIF hint"
        )
    }

    @MainActor
    @Test("reader image taps route raster, animated, and SVG previews")
    func readerImageTapsRouteToZoomablePreviewFamilies() async throws {
        let raster = try #require(makePreviewTestImage().pngData())
        let animated = try #require(Data(
            base64Encoded: "R0lGODlhAgACAIEAAP8AAAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAAAgACAAAIBgABCAQQEAAh+QQBCgABACwAAAAAAgACAIEAAP8AAAAAAAAAAAAIBgABCAQQEAA7"
        ))
        let svg = Data("""
        <svg xmlns="http://www.w3.org/2000/svg" width="320" height="180">
          <rect width="320" height="180" fill="#111827"/>
        </svg>
        """.utf8)
        let cases: [(path: String, data: Data, expectedMimeType: String?)] = [
            ("preview.png", raster, nil),
            ("preview-without-extension", animated, "image/gif"),
            ("preview.svg", svg, "image/svg+xml"),
        ]

        let animationsWereEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(animationsWereEnabled) }

        for previewCase in cases {
            let fixture = makeWindowedReader(
                content: "# Image preview\n\n![Visual](\(previewCase.path))",
                workspaceFiles: [previewCase.path: previewCase.data]
            )
            let imageView = try #require(
                timelineFirstView(ofType: NativeMarkdownImageView.self, in: fixture.reader.view)
            )
            let loaded = await waitForTimelineCondition(timeoutMs: 10_000) { @MainActor in
                fixture.reader.view.layoutIfNeeded()
                return previewCase.expectedMimeType == nil
                    ? imageView.debugHasRasterPreviewForTesting
                    : imageView.debugWebRendererSettledForTesting
            }
            #expect(loaded, "\(previewCase.path) did not settle into its tappable Markdown image renderer")

            if let expectedMimeType = previewCase.expectedMimeType {
                #expect(imageView.debugDataPreviewMimeTypeForTesting == expectedMimeType)
                let renderer = try #require(imageView.debugWebRendererForTesting)
                #expect(
                    await webImageElementDecoded(renderer),
                    "\(previewCase.path) finished navigation but WebKit did not decode the image element"
                )
                let tapTarget = try #require(imageView.debugDataPreviewTapTargetForTesting)
                tapTarget.sendActions(for: .touchUpInside)
            } else {
                imageView.debugOpenRasterPreviewForTesting()
            }

            let opened = await waitForTimelineCondition(timeoutMs: 500) { @MainActor in
                presentedController(in: fixture.reader) is UINavigationController
            }
            #expect(opened, "\(previewCase.path) tap did not open image preview chrome")
            let navigation = try #require(
                presentedController(in: fixture.reader) as? UINavigationController
            )
            if previewCase.expectedMimeType != nil {
                #expect(navigation.viewControllers.first is FullScreenImageDataPreviewViewController)
            } else {
                #expect(navigation.viewControllers.first is FullScreenImageViewController)
            }

            navigation.loadViewIfNeeded()
            _ = await waitForTimelineCondition(timeoutMs: 500) { @MainActor in
                navigation.view.window != nil && navigation.transitionCoordinator == nil
            }
            navigation.presentingViewController?.dismiss(animated: false)
            _ = await waitForTimelineCondition(timeoutMs: 500) { @MainActor in
                presentedController(in: fixture.reader) == nil
            }
            fixture.window.isHidden = true
        }
    }

    @MainActor
    @Test("extensionless session GIF keeps byte-detected MIME on cache hit")
    func extensionlessSessionAnimatedImageKeepsMimeTypeOnCacheHit() async throws {
        let animated = try #require(Data(
            base64Encoded: "R0lGODlhAgACAIEAAP8AAAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAAAgACAAAIBgABCAQQEAAh+QQBCgABACwAAAAAAgACAIEAAP8AAAAAAAAAAAAIBgABCAQQEAA7"
        ))
        let sessionID = "session-\(UUID().uuidString)"
        let url = try #require(SessionFileURL.make(
            workspaceID: "workspace-visual-preview",
            sessionID: sessionID,
            filePath: "generated/animation"
        ))
        let host = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        var fetchCount = 0
        let fetch: NativeMarkdownImageView.FetchSessionFile = { _, _, _ in
            fetchCount += 1
            return animated
        }

        let first = makeWindowedMarkdownImageView(in: host.view)
        first.apply(
            url: url,
            alt: "Animated preview",
            fetchWorkspaceFile: nil,
            fetchSessionFile: fetch
        )
        let firstSettled = await waitForTimelineCondition(timeoutMs: 10_000) { @MainActor in
            host.view.layoutIfNeeded()
            return first.debugWebRendererSettledForTesting
        }
        #expect(firstSettled)
        #expect(first.debugDataPreviewMimeTypeForTesting == "image/gif")
        let firstRenderer = try #require(first.debugWebRendererForTesting)
        #expect(await webImageElementDecoded(firstRenderer))
        #expect(fetchCount == 1)

        first.removeFromSuperview()
        let cached = makeWindowedMarkdownImageView(in: host.view)
        cached.apply(
            url: url,
            alt: "Animated preview",
            fetchWorkspaceFile: nil,
            fetchSessionFile: fetch
        )
        let cacheHitSettled = await waitForTimelineCondition(timeoutMs: 10_000) { @MainActor in
            host.view.layoutIfNeeded()
            return cached.debugWebRendererSettledForTesting
        }
        #expect(cacheHitSettled)
        #expect(fetchCount == 1, "Cache hit unexpectedly fetched the session image again")
        #expect(cached.debugDataPreviewMimeTypeForTesting == "image/gif")
        let cachedRenderer = try #require(cached.debugWebRendererForTesting)
        #expect(await webImageElementDecoded(cachedRenderer))

        let tapTarget = try #require(cached.debugDataPreviewTapTargetForTesting)
        tapTarget.sendActions(for: .touchUpInside)
        let opened = await waitForTimelineCondition(timeoutMs: 500) { @MainActor in
            host.presentedViewController is UINavigationController
        }
        #expect(opened, "The real animated-image tap control did not open focused preview chrome")
        host.dismiss(animated: false)
    }

    /// Regression: entering a Mermaid cell can schedule a layout pass while a
    /// streaming reader is still following the tail. If the user starts an
    /// upward drag at the bottom before that queued follow executes, the queued
    /// block must yield to the user's new viewport instead of snapping back.
    @MainActor
    @Test("queued tail follow must not override an upward scroll near Mermaid")
    func queuedTailFollowYieldsToUpwardScroll() async {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        scrollView.contentSize = CGSize(width: 390, height: 4_000)
        let bottomY = scrollView.contentSize.height - scrollView.bounds.height
        scrollView.contentOffset.y = bottomY

        let coordinator = TailFollowScrollCoordinator(
            scrollView: scrollView,
            shouldAutoFollowTail: true,
            performLayout: {}
        )

        // Model the Mermaid cell's visible-height reconciliation queuing a
        // follow from a layout pass just before the upward drag takes control.
        coordinator.scheduleAutoFollowToBottomIfNeeded()
        coordinator.handleWillBeginDragging()
        // UIKit may report an initial didScroll while the finger is still
        // inside the near-bottom threshold. That must not re-arm following
        // before the upward drag has moved far enough to leave the threshold.
        coordinator.handleDidScroll(isUserDriven: true, isStreaming: true)
        let upwardY = bottomY - 240
        scrollView.contentOffset.y = upwardY

        // The queued block can run before UIKit delivers the next
        // user-driven didScroll callback, so drag-begin itself must revoke it.
        await drainMarkdownHeightFlush()

        #expect(
            abs(scrollView.contentOffset.y - upwardY) < 1,
            "queued tail follow snapped the upward scroll back to the bottom"
        )
        #expect(!coordinator.shouldAutoFollowTail)

        // Reaching the live tail and releasing should still opt back into the
        // normal streaming follow behavior.
        scrollView.contentOffset.y = bottomY
        coordinator.handleDidEndDragging(willDecelerate: false, isStreaming: true)
        #expect(coordinator.shouldAutoFollowTail)
    }

    @MainActor
    @Test("completed Markdown immediately stops following the tail")
    func completedMarkdownStopsTailFollowImmediately() async throws {
        let content = (0..<80)
            .map { "Streaming paragraph \($0) with enough text to make the reader scroll." }
            .joined(separator: "\n\n")
        let stream = ThinkingTraceStream(text: content, isDone: false)
        let body = NativeFullScreenMarkdownBody(
            content: content,
            stream: stream,
            palette: ThemeID.dark.palette,
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.addSubview(body)
        body.frame = window.bounds
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        body.layoutIfNeeded()
        let collectionView = try #require(timelineFirstView(ofType: UICollectionView.self, in: body))
        collectionView.layoutIfNeeded()
        await drainMarkdownHeightFlush()

        let bottomY = max(
            -collectionView.adjustedContentInset.top,
            collectionView.contentSize.height
                - collectionView.bounds.height
                + collectionView.adjustedContentInset.bottom
        )
        collectionView.contentOffset.y = bottomY

        // Queue a follow while the snapshot is still live, then settle the
        // document before that queued main-turn work executes.
        body.setNeedsLayout()
        body.layoutIfNeeded()
        stream.update(text: content, isDone: true)
        let readingY = bottomY - 240
        collectionView.contentOffset.y = readingY

        await drainMarkdownHeightFlush()

        #expect(
            abs(collectionView.contentOffset.y - readingY) < 1,
            "completed Markdown still executed queued tail-follow work"
        )
    }

    @MainActor
    @Test("async graphical placeholders configure code-block accessibility")
    func asyncGraphicalPlaceholdersConfigureCodeBlockAccessibility() throws {
        let graphicalViews: [UIView] = [
            NativeMermaidBlockView(),
            NativeLatexBlockView(),
        ]

        for graphicalView in graphicalViews {
            let codeBlock = try #require(
                timelineFirstView(ofType: NativeCodeBlockView.self, in: graphicalView)
            )
            #expect(codeBlock.debugWrapButtonAccessibilityLabelForTesting == "Wrap code lines")
            #expect(codeBlock.debugWrapButtonAccessibilityValueForTesting == "Off")
        }
    }

    @MainActor
    private func makeWindowedReader(
        content: String,
        workspaceFiles: [String: Data] = [:]
    ) -> (window: UIWindow, reader: FullScreenCodeViewController) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else {
            fatalError("Missing UIWindowScene for FullScreenMarkdownAsyncRenderTests")
        }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let workspaceContext: FullScreenCodeContent.WorkspaceContext? = workspaceFiles.isEmpty ? nil : .init(
            workspaceID: "workspace-visual-preview",
            serverBaseURL: URL(string: "https://example.com/api")!,
            fetchWorkspaceFile: { _, path in
                guard let data = workspaceFiles[path] else {
                    throw CocoaError(.fileNoSuchFile)
                }
                return data
            }
        )
        let reader = FullScreenCodeViewController(
            content: .markdown(
                content: content,
                filePath: "preview.md",
                workspaceContext: workspaceContext
            )
        )
        window.rootViewController = reader
        window.makeKeyAndVisible()
        reader.loadViewIfNeeded()
        reader.view.frame = window.bounds
        reader.view.layoutIfNeeded()
        return (window, reader)
    }

    @MainActor
    private func presentedController(in root: UIViewController) -> UIViewController? {
        if let presented = root.presentedViewController {
            return presented
        }
        for child in root.children {
            if let presented = presentedController(in: child) {
                return presented
            }
        }
        return nil
    }

    @MainActor
    private func makeWindowedMarkdownImageView(in host: UIView) -> NativeMarkdownImageView {
        let view = NativeMarkdownImageView()
        view.frame = CGRect(x: 20, y: 100, width: 350, height: 220)
        host.addSubview(view)
        host.layoutIfNeeded()
        return view
    }

    @MainActor
    private func webImageElementDecoded(_ webView: WKWebView) async -> Bool {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(
                "document.images.length === 1 && document.images[0].complete && document.images[0].naturalWidth > 0 && document.images[0].naturalHeight > 0"
            ) { value, error in
                continuation.resume(returning: error == nil && (value as? Bool) == true)
            }
        }
    }

    @MainActor
    private func makePreviewTestImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 100))
        return renderer.image { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 160, height: 100))
        }
    }

    @MainActor
    @Test("cancelling the parent render task cancels the detached build")
    func cancellingParentRenderTaskCancelsDetachedBuild() async {
        let probe = DetachedCancellationProbe()

        let parent = Task { @MainActor in
            let _: Void? = await withCancellableDetachedTask(priority: .userInitiated) {
                await probe.markStarted()
                for _ in 0..<25 where !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                if Task.isCancelled {
                    await probe.markCancelled()
                }
                return nil
            }
        }

        await probe.waitUntilStarted()
        parent.cancel()
        _ = await parent.value

        #expect(await probe.wasCancelled)
    }
}

private func drainMarkdownHeightFlush() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.main.async {
            continuation.resume()
        }
    }
}

private actor DetachedCancellationProbe {
    private var started = false
    private var cancelled = false
    private var startedContinuations: [CheckedContinuation<Void, Never>] = []

    var wasCancelled: Bool { cancelled }

    func markStarted() {
        started = true
        let continuations = startedContinuations
        startedContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func markCancelled() {
        cancelled = true
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startedContinuations.append(continuation)
        }
    }
}
