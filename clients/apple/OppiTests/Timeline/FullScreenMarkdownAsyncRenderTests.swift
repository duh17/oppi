import Testing
import UIKit
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
