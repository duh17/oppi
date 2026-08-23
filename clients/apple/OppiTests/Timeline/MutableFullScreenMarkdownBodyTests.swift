import Foundation
import Testing
import UIKit
@testable import Oppi

@Suite("Mutable full-screen Markdown body", .serialized)
@MainActor
struct MutableFullScreenMarkdownBodyTests {
    @Test("live Markdown routes through the assistant incremental renderer")
    func liveMarkdownUsesSharedIncrementalRenderer() throws {
        let source = "# Streaming\n\nA provisional tail"
        let stream = SourceTraceStream(
            text: source,
            filePath: "Draft.md",
            isDone: false,
            finalContent: .markdown(content: source, filePath: "Draft.md")
        )
        let controller = makeController(
            content: .liveSource(snapshot: stream.snapshot, stream: stream)
        )

        #expect(controller.installedBodyViewForTesting is NativeMutableFullScreenMarkdownBody)
        #expect(timelineFirstView(ofType: AssistantMarkdownContentView.self, in: controller.view) != nil)
        #expect(timelineFirstView(ofType: UICollectionView.self, in: controller.view) == nil)
    }

    @Test("thinking uses the same mutable engine while its trace is live")
    func thinkingUsesSharedMutableRenderer() throws {
        let stream = ThinkingTraceStream(text: "**Considering** the first option", isDone: false)
        let controller = makeController(
            content: .thinking(content: stream.snapshot.text, stream: stream)
        )

        #expect(controller.installedBodyViewForTesting is NativeMutableFullScreenMarkdownBody)
        let markdown = try #require(
            timelineFirstView(ofType: AssistantMarkdownContentView.self, in: controller.view)
        )
        let rendered = timelineAllTextViews(in: markdown).map(timelineRenderedText).joined()
        #expect(rendered.contains("Considering"))
        #expect(!rendered.contains("**Considering**"))
    }

    @Test("thinking completion flushes immediately into the immutable reader")
    func thinkingCompletionTransitionsOnce() async throws {
        let stream = ThinkingTraceStream(text: "Considering", isDone: false)
        let controller = makeController(
            content: .thinking(content: stream.snapshot.text, stream: stream)
        )
        let wrapper = try #require(
            controller.installedBodyViewForTesting as? NativeMutableFullScreenMarkdownBody
        )

        stream.update(text: "Considering\n\nFinal answer.", isDone: true)
        await drainMutableMarkdownQueue()
        controller.view.layoutIfNeeded()

        #expect(wrapper.debugIsShowingImmutableReaderForTesting)
        #expect(wrapper.debugTransitionCountForTesting == 1)
        let rendered = timelineAllTextViews(in: wrapper).map(timelineRenderedText).joined(separator: "\n")
        #expect(rendered.contains("Final answer"))
    }

    @Test("append updates retain committed prefix views and update only the provisional tail")
    func appendRetainsCommittedPrefixViews() throws {
        let initial = "# Stable heading\n\n```swift\nlet stable = true\n```\n\nProvisional"
        let body = makeBody(content: initial)
        let fixture = attach(body)
        defer { fixture.window.isHidden = true }

        let prefixBefore = try #require(timelineAllTextViews(in: body).first)
        let codeBefore = try #require(timelineFirstView(ofType: NativeCodeBlockView.self, in: body))

        body.update(content: initial + " tail grows.", isStreaming: true)
        body.debugFlushPendingMutableApplyForTesting()
        fixture.window.layoutIfNeeded()

        #expect(timelineAllTextViews(in: body).first === prefixBefore)
        #expect(timelineFirstView(ofType: NativeCodeBlockView.self, in: body) === codeBefore)
        let rendered = timelineAllTextViews(in: body).map(timelineRenderedText).joined(separator: "\n")
        #expect(rendered.contains("Provisional tail grows."))
    }

    @Test("tail following and detached reading remain viewport-owner decisions")
    func viewportTailAndDetachedIntent() async throws {
        let initial = tallMarkdown(paragraphs: 65)
        let body = makeBody(content: initial)
        let fixture = attach(body)
        defer { fixture.window.isHidden = true }
        let scroll = body.debugMutableScrollViewForTesting

        await drainMutableMarkdownQueue()
        fixture.window.layoutIfNeeded()
        let firstBottom = maximumOffsetY(scroll)
        #expect(abs(scroll.contentOffset.y - firstBottom) < 1)

        body.update(content: initial + "\n\nA new live tail paragraph.", isStreaming: true)
        body.debugFlushPendingMutableApplyForTesting()
        await drainMutableMarkdownQueue()
        fixture.window.layoutIfNeeded()
        #expect(abs(scroll.contentOffset.y - maximumOffsetY(scroll)) < 1)

        body.scrollViewWillBeginDragging(scroll)
        let detachedY = max(80, maximumOffsetY(scroll) / 2)
        scroll.contentOffset.y = detachedY
        body.scrollViewDidEndDragging(scroll, willDecelerate: false)
        body.update(content: initial + "\n\nA new live tail paragraph grows again.", isStreaming: true)
        body.debugFlushPendingMutableApplyForTesting()
        await drainMutableMarkdownQueue()
        fixture.window.layoutIfNeeded()

        #expect(abs(scroll.contentOffset.y - detachedY) < 1)
        #expect(maximumOffsetY(scroll) - scroll.contentOffset.y > 28)
    }

    @Test("live bursts coalesce while completion flushes immediately")
    func liveBurstCadenceAndCompletionFlush() throws {
        let body = makeBody(content: "Initial")
        let initialApplyCount = body.debugMutableApplyCountForTesting

        for index in 0..<12 {
            body.update(content: "Initial \(index)", isStreaming: true)
        }

        #expect(body.debugHasPendingMutableApplyForTesting)
        #expect(body.debugMutableApplyCountForTesting == initialApplyCount)
        body.debugFlushPendingMutableApplyForTesting()
        #expect(body.debugMutableApplyCountForTesting == initialApplyCount + 1)

        body.update(content: "Final bytes", isStreaming: false)
        #expect(!body.debugHasPendingMutableApplyForTesting)
        #expect(body.debugIsShowingImmutableReaderForTesting)
    }

    @Test("completion flushes once and defers immutable swap during UIKit interaction")
    func completionDefersSwapAndTransitionsOnce() async throws {
        let initial = tallMarkdown(paragraphs: 40)
        let body = makeBody(content: initial)
        let fixture = attach(body)
        defer { fixture.window.isHidden = true }

        body.debugSetViewportInteractingForTesting(true)
        let final = initial + "\n\n## Final section"
        body.update(content: final, isStreaming: false)
        fixture.window.layoutIfNeeded()

        #expect(!body.debugIsShowingImmutableReaderForTesting)
        let mutableText = timelineAllTextViews(in: body).map(timelineRenderedText).joined(separator: "\n")
        #expect(mutableText.contains("Final section"))

        body.debugSetViewportInteractingForTesting(false)
        await drainMutableMarkdownQueue()
        fixture.window.layoutIfNeeded()

        #expect(body.debugIsShowingImmutableReaderForTesting)
        #expect(body.debugTransitionCountForTesting == 1)
        #expect(timelineFirstView(ofType: NativeFullScreenMarkdownBody.self, in: body) != nil)

        body.update(content: final, isStreaming: false)
        #expect(body.debugTransitionCountForTesting == 1)
    }

    @Test("live-source completion keeps the wrapper and installs the immutable reader once")
    func liveSourceCompletionUsesOneWayTransition() async throws {
        let initial = tallMarkdown(paragraphs: 35)
        let context = FullScreenCodeContent.WorkspaceContext(
            workspaceID: "workspace-1",
            serverID: "server-1",
            serverBaseURL: try #require(URL(string: "https://server.example.com")),
            fetchWorkspaceFile: { _, _ in Data() },
            sessionID: "session-1"
        )
        let stream = SourceTraceStream(
            text: initial,
            filePath: "docs/Draft.md",
            isDone: false,
            finalContent: .markdown(content: initial, filePath: "docs/Draft.md", workspaceContext: context)
        )
        let controller = makeController(content: .liveSource(snapshot: stream.snapshot, stream: stream))
        let wrapper = try #require(
            controller.installedBodyViewForTesting as? NativeMutableFullScreenMarkdownBody
        )

        let final = initial + "\n\nDone."
        stream.update(
            text: final,
            filePath: "docs/Draft.md",
            isDone: true,
            finalContent: .markdown(content: final, filePath: "docs/Draft.md", workspaceContext: context)
        )
        await drainMutableMarkdownQueue()
        controller.view.layoutIfNeeded()

        #expect(controller.installedBodyViewForTesting === wrapper)
        #expect(wrapper.debugIsShowingImmutableReaderForTesting)
        #expect(wrapper.debugTransitionCountForTesting == 1)
    }

    @Test("tail intent survives a large final completion burst")
    func completionPreservesTailIntent() async throws {
        let initial = tallMarkdown(paragraphs: 45)
        let body = makeBody(content: initial)
        let fixture = attach(body)
        defer { fixture.window.isHidden = true }
        await drainMutableMarkdownQueue()
        fixture.window.layoutIfNeeded()
        #expect(abs(body.debugMutableScrollViewForTesting.contentOffset.y - maximumOffsetY(body.debugMutableScrollViewForTesting)) < 1)

        let final = initial + "\n\n" + tallMarkdown(paragraphs: 20)
        body.update(content: final, isStreaming: false)
        await drainMutableMarkdownQueue()
        fixture.window.layoutIfNeeded()
        await drainMutableMarkdownQueue()

        let collection = try #require(timelineFirstView(ofType: UICollectionView.self, in: body))
        collection.layoutIfNeeded()
        #expect(abs(collection.contentOffset.y - maximumOffsetY(collection)) < 1)
        #expect(timelineAllTextViews(in: body.debugMarkdownViewForTesting).isEmpty)
    }

    @Test("deferred large immutable render reapplies captured tail intent")
    func deferredImmutableRenderRestoresTail() async throws {
        let large = String(repeating: "Large completed paragraph with stable Markdown text. ", count: 4_500)
        #expect(large.utf8.count > 200 * 1024)
        let body = NativeFullScreenMarkdownBody(
            content: large,
            palette: ThemeID.dark.palette,
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil
        )
        body.restoreViewportAfterMutableTransition(.tail)
        let fixture = attach(body)
        defer { fixture.window.isHidden = true }

        let rendered = await waitForTimelineCondition(timeoutMs: 4_000) { @MainActor in
            fixture.window.layoutIfNeeded()
            return body.debugRenderedSegmentCountForTesting > 0
        }
        #expect(rendered)
        await drainMutableMarkdownQueue()
        fixture.window.layoutIfNeeded()
        let collection = try #require(timelineFirstView(ofType: UICollectionView.self, in: body))
        collection.layoutIfNeeded()
        #expect(abs(collection.contentOffset.y - maximumOffsetY(collection)) < 1)
    }

    @Test("completion uses final file and workspace context")
    func completionUsesFinalSourceContext() async throws {
        let initialContext = FullScreenCodeContent.WorkspaceContext(
            workspaceID: "workspace-a",
            serverBaseURL: try #require(URL(string: "https://server.example.com")),
            fetchWorkspaceFile: { _, _ in Data() }
        )
        let initial = "# Draft\n\nProvisional"
        let stream = SourceTraceStream(
            text: initial,
            filePath: "old/Draft.md",
            isDone: false,
            finalContent: .markdown(content: initial, filePath: "old/Draft.md", workspaceContext: initialContext)
        )
        let controller = makeController(content: .liveSource(snapshot: stream.snapshot, stream: stream))
        let wrapper = try #require(controller.installedBodyViewForTesting as? NativeMutableFullScreenMarkdownBody)
        let finalContext = FullScreenCodeContent.WorkspaceContext(
            workspaceID: "workspace-b",
            serverBaseURL: try #require(URL(string: "https://server.example.com")),
            fetchWorkspaceFile: { _, _ in Data() }
        )
        let final = initial + "\n\n![final](images/final.png)"
        stream.update(
            text: final,
            filePath: "new/Final.md",
            isDone: true,
            finalContent: .markdown(content: final, filePath: "new/Final.md", workspaceContext: finalContext)
        )
        await drainMutableMarkdownQueue()
        controller.view.layoutIfNeeded()

        let reader = try #require(timelineFirstView(ofType: NativeFullScreenMarkdownBody.self, in: wrapper))
        let imageURL = try #require(reader.debugRenderedSegmentsForTesting.compactMap { segment -> URL? in
            guard case .image(_, let url) = segment else { return nil }
            return url
        }.first)
        #expect(imageURL.path.contains("/workspaces/workspace-b/"))
        #expect(imageURL.path.hasSuffix("/new/images/final.png"))
    }

    @Test("source toggle restores detached mutable viewport policy")
    func sourceTogglePreservesDetachedIntent() async throws {
        let content = tallMarkdown(paragraphs: 55)
        let stream = SourceTraceStream(
            text: content,
            filePath: "Draft.md",
            isDone: false,
            finalContent: .markdown(content: content, filePath: "Draft.md")
        )
        let controller = makeController(content: .liveSource(snapshot: stream.snapshot, stream: stream))
        let first = try #require(controller.installedBodyViewForTesting as? NativeMutableFullScreenMarkdownBody)
        let firstScroll = first.debugMutableScrollViewForTesting
        first.scrollViewWillBeginDragging(firstScroll)
        firstScroll.contentOffset.y = maximumOffsetY(firstScroll) / 2
        first.scrollViewDidEndDragging(firstScroll, willDecelerate: false)

        controller.toggleSourceForTesting()
        controller.toggleSourceForTesting()
        controller.view.layoutIfNeeded()
        let restored = try #require(controller.installedBodyViewForTesting as? NativeMutableFullScreenMarkdownBody)
        let restoredScroll = restored.debugMutableScrollViewForTesting
        #expect(maximumOffsetY(restoredScroll) - restoredScroll.contentOffset.y > 28)

        stream.update(
            text: content + "\n\nA further live append.",
            filePath: "Draft.md",
            isDone: false,
            finalContent: .markdown(content: content, filePath: "Draft.md")
        )
        await drainMutableMarkdownQueue()
        controller.view.layoutIfNeeded()
        #expect(maximumOffsetY(restoredScroll) - restoredScroll.contentOffset.y > 28)
    }

    @Test("mutable mixed blocks do not overlap and retain remote-image policy")
    func mixedBlocksAndRemoteImagePolicy() async throws {
        let content = """
        # Live plan

        - [ ] First task
        - [x] Stable task

        ```mermaid
        graph TD
        A-->B
        ```

        ![remote](https://example.invalid/chart.png)

        Tail.
        """
        let body = makeBody(content: content)
        let fixture = attach(body)
        defer { fixture.window.isHidden = true }
        await drainMutableMarkdownQueue()
        fixture.window.layoutIfNeeded()

        let markdown = body.debugMarkdownViewForTesting
        #expect(markdown.debugMaxRenderedSegmentOverlapPoints <= 0.5)
        let rendered = timelineAllTextViews(in: markdown).map(timelineRenderedText).joined(separator: "\n")
        #expect(rendered.contains("First task"))
        #expect(timelineFirstView(ofType: NativeMermaidBlockView.self, in: markdown) != nil)
        let loadRemote = timelineAllViews(in: markdown).compactMap { $0 as? UIButton }.first {
            $0.configuration?.title == "Load remote image"
        }
        #expect(loadRemote != nil)
    }

    @Test("mutable context preserves image fetch, reader preferences, and review comments")
    func contextFlowsThroughSharedRenderer() async throws {
        let sourceContext = ReviewCommentSourceContext(
            sessionId: "session-1",
            surface: .fullScreenMarkdown,
            sourceLabel: "Draft",
            filePath: "docs/Draft.md",
            languageHint: "markdown"
        )
        var fetched: (String, String)?
        let body = NativeMutableFullScreenMarkdownBody(
            content: "# Draft\n\nReview this paragraph.\n\n![local](images/local.png)",
            isStreaming: true,
            themeID: .dark,
            palette: ThemeID.dark.palette,
            reviewCommentSelectionRouter: ReviewCommentSelectionRouter { _ in },
            reviewCommentSourceContext: sourceContext,
            workspaceID: "workspace-1",
            serverBaseURL: try #require(URL(string: "https://server.example.com")),
            sourceFilePath: "docs/Draft.md",
            readerPreferences: .init(textScale: 1.25, spacing: .relaxed),
            fetchWorkspaceFile: { workspaceID, path in
                fetched = (workspaceID, path)
                return try #require(Self.pngData())
            }
        )
        let fixture = attach(body)
        defer { fixture.window.isHidden = true }

        let fetchedLocal = await waitForTimelineCondition(timeoutMs: 2_000) { @MainActor in
            fetched != nil
        }
        #expect(fetchedLocal)
        #expect(fetched?.0 == "workspace-1")
        #expect(fetched?.1 == "docs/images/local.png")

        let textView = try #require(timelineAllTextViews(in: body).first {
            timelineRenderedText(of: $0).contains("Review this paragraph")
        })
        #expect((textView.font?.pointSize ?? 0) > AppFont.messageBody.pointSize)
        let menu = try #require(textView.delegate?.textView?(
            textView,
            editMenuForTextIn: NSRange(location: 0, length: 6),
            suggestedActions: [UIAction(title: "Copy") { _ in }]
        ))
        #expect((menu.children.first as? UIAction)?.title == "Comment")
    }

    private func makeController(content: FullScreenCodeContent) -> FullScreenCodeViewController {
        let controller = FullScreenCodeViewController.makeHarnessController(
            content: content,
            reviewCommentSelectionContext: ReviewCommentSelectionContext(
                dispatcher: ReviewCommentSelectionRouter { _ in },
                sessionId: "session-1",
                sourceLabel: "Full Screen"
            )
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 844)
        controller.view.layoutIfNeeded()
        return controller
    }

    private func makeBody(content: String) -> NativeMutableFullScreenMarkdownBody {
        NativeMutableFullScreenMarkdownBody(
            content: content,
            isStreaming: true,
            themeID: .dark,
            palette: ThemeID.dark.palette,
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil
        )
    }

    private func attach(_ body: UIView) -> (window: UIWindow, host: UIViewController) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 844))
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        body.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
            body.topAnchor.constraint(equalTo: host.view.topAnchor),
            body.bottomAnchor.constraint(equalTo: host.view.bottomAnchor),
        ])
        host.view.layoutIfNeeded()
        return (window, host)
    }

    private func tallMarkdown(paragraphs: Int) -> String {
        (0..<paragraphs).map { index in
            "Paragraph \(index) with enough streaming Markdown text to wrap across several lines in the full-screen viewport."
        }.joined(separator: "\n\n")
    }

    private func maximumOffsetY(_ scrollView: UIScrollView) -> CGFloat {
        max(
            -scrollView.adjustedContentInset.top,
            scrollView.contentSize.height - scrollView.bounds.height
                + scrollView.adjustedContentInset.bottom
        )
    }

    private func drainMutableMarkdownQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    private static func pngData() -> Data? {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        return renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }.pngData()
    }
}
