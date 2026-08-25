import Foundation
import SwiftUI
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

    @Test("thinking stays in one plain text view while its trace is live")
    func thinkingStaysPlainText() throws {
        let stream = ThinkingTraceStream(text: "**Considering** the first option", isDone: false)
        let controller = makeController(
            content: .thinking(content: stream.snapshot.text, stream: stream)
        )

        let body = try #require(controller.installedBodyViewForTesting as? NativeFullScreenThinkingBody)
        #expect(timelineFirstView(ofType: AssistantMarkdownContentView.self, in: body) == nil)
        #expect(body.debugTextViewForTesting.text == "**Considering** the first option")
        #expect(body.debugFollowsTailForTesting)
    }

    @Test("thinking selection and review menu detach live tail following")
    func thinkingSelectionDetachesTailFollow() throws {
        let stream = ThinkingTraceStream(
            text: tallMarkdown(paragraphs: 45),
            isDone: false
        )
        let controller = makeController(
            content: .thinking(content: stream.snapshot.text, stream: stream)
        )
        let body = try #require(controller.installedBodyViewForTesting as? NativeFullScreenThinkingBody)
        let textView = body.debugTextViewForTesting
        textView.selectedRange = NSRange(location: 12, length: 18)

        let menu = body.textView(
            textView,
            editMenuForTextIn: textView.selectedRange,
            suggestedActions: [UIAction(title: "Copy") { _ in }]
        )

        #expect(menu != nil)
        #expect(!body.debugFollowsTailForTesting)
    }

    @Test("thinking layout never follows tail while selection owns the text view")
    func thinkingSelectionRejectsLayoutOffsetWrites() async throws {
        let initial = tallMarkdown(paragraphs: 55)
        let stream = ThinkingTraceStream(text: initial, isDone: false)
        let controller = makeController(
            content: .thinking(content: stream.snapshot.text, stream: stream)
        )
        let body = try #require(controller.installedBodyViewForTesting as? NativeFullScreenThinkingBody)
        let textView = body.debugTextViewForTesting
        let detachedY = max(80, maximumOffsetY(textView) / 2)
        textView.contentOffset.y = detachedY
        textView.selectedRange = NSRange(location: 10, length: 20)

        stream.update(text: initial + "\n\nA further live thought.", isDone: false)
        await drainMutableMarkdownQueue()
        controller.view.layoutIfNeeded()

        #expect(abs(textView.contentOffset.y - detachedY) < 1)
        #expect(!body.debugFollowsTailForTesting)
        #expect(textView.selectedRange.length == 20)
    }

    @Test("thinking completion swaps the live plain text body for immutable Markdown")
    func thinkingCompletionSwapsToImmutableMarkdown() async throws {
        let stream = ThinkingTraceStream(text: "Considering", isDone: false)
        let controller = makeController(
            content: .thinking(content: stream.snapshot.text, stream: stream)
        )
        let liveBody = try #require(controller.installedBodyViewForTesting as? NativeFullScreenThinkingBody)

        stream.update(text: "Considering\n\nFinal **answer**.", isDone: true)
        await drainMutableMarkdownQueue()
        controller.view.layoutIfNeeded()

        #expect(controller.installedBodyViewForTesting !== liveBody)
        let completedBody = try #require(
            controller.installedBodyViewForTesting as? NativeFullScreenMarkdownBody
        )
        #expect(timelineFirstView(ofType: NativeFullScreenThinkingBody.self, in: completedBody) == nil)
        let rendered = timelineAllTextViews(in: completedBody).map(timelineRenderedText).joined(separator: "\n")
        #expect(rendered.contains("Final answer."))
        #expect(!rendered.contains("**answer**"))
    }

    @Test("thinking completion waits for viewport interaction and restores detached intent")
    func thinkingCompletionDefersDuringInteraction() async throws {
        let initial = tallMarkdown(paragraphs: 55)
        let stream = ThinkingTraceStream(text: initial, isDone: false)
        let controller = makeController(
            content: .thinking(content: stream.snapshot.text, stream: stream)
        )
        let liveBody = try #require(
            controller.installedBodyViewForTesting as? NativeFullScreenThinkingBody
        )
        let textView = liveBody.debugTextViewForTesting
        liveBody.scrollViewWillBeginDragging(textView)
        let detachedY = max(80, maximumOffsetY(textView) / 2)
        textView.contentOffset.y = detachedY

        let final = initial + "\n\n" + tallMarkdown(paragraphs: 20)
        stream.update(text: final, isDone: true)
        controller.view.layoutIfNeeded()

        #expect(controller.installedBodyViewForTesting === liveBody)
        #expect(abs(textView.contentOffset.y - detachedY) < 1)

        liveBody.scrollViewDidEndDragging(textView, willDecelerate: true)
        #expect(controller.installedBodyViewForTesting === liveBody)
        liveBody.scrollViewDidEndDecelerating(textView)
        await drainMutableMarkdownQueue()
        controller.view.layoutIfNeeded()
        await drainMutableMarkdownQueue()

        let completedBody = try #require(
            controller.installedBodyViewForTesting as? NativeFullScreenMarkdownBody
        )
        let collection = try #require(
            timelineFirstView(ofType: UICollectionView.self, in: completedBody)
        )
        collection.layoutIfNeeded()
        #expect(collection.contentOffset.y > 28)
        #expect(maximumOffsetY(collection) - collection.contentOffset.y > 28)
    }

    @Test("markdown viewport restore is keyed by file path")
    func markdownViewportRestoreIsKeyedByFilePath() {
        #expect(FullScreenMarkdownViewportRestoreState.key(filePath: "docs/README.md") == "docs/README.md")

        var store = FullScreenMarkdownViewportRestoreState()
        let detached = FullScreenMarkdownViewportIntent.detached(
            FullScreenMarkdownViewportAnchor(
                segmentID: nil,
                offsetInItem: 12,
                absoluteOffset: 240
            )
        )
        store["docs/README.md"] = detached

        #expect(store["docs/README.md"] == detached)
        #expect(store["docs/other.md"] == nil)

        store["docs/README.md"] = .top
        store["docs/other.md"] = detached

        #expect(store["docs/README.md"] == .top)
        #expect(store["docs/other.md"] == detached)
    }

    @Test("unlaid-out remake top does not clobber a stored mid-document intent")
    func unlaidOutRemakeTopDoesNotClobberStoredMidDocumentIntent() {
        let filePath = ".pi/markdown-rendering-stress-test.md"
        var store = FullScreenMarkdownViewportRestoreState()
        let detached = FullScreenMarkdownViewportIntent.detached(
            FullScreenMarkdownViewportAnchor(
                segmentID: nil,
                offsetInItem: 18,
                absoluteOffset: 640
            )
        )
        store[filePath] = detached

        let remake = FullScreenCodeViewController(
            content: .markdown(content: "# Stress\n\nParagraph", filePath: filePath),
            presentationMode: .embedded(onDismiss: {}),
            markdownViewportIntent: store[filePath],
            onMarkdownViewportIntentChange: { store[filePath] = $0 }
        )
        remake.loadViewIfNeeded()
        #expect(remake.installedBodyViewForTesting is NativeFullScreenMarkdownBody)
        remake.viewWillDisappear(false)

        #expect(store[filePath] == detached)
        #expect(store[filePath] != .top)
    }

    @Test("unsettled laid-out remake does not clobber a stored mid-document intent")
    func unsettledLaidOutRemakeDoesNotClobberStoredMidDocumentIntent() async throws {
        let content = tallMarkdown(paragraphs: 48)
        let filePath = "docs/README.md"
        var store = FullScreenMarkdownViewportRestoreState()
        let detached = FullScreenMarkdownViewportIntent.detached(
            FullScreenMarkdownViewportAnchor(
                segmentID: nil,
                offsetInItem: 18,
                absoluteOffset: 640
            )
        )
        store[filePath] = detached

        let fixture = attachMarkdownController(
            content: content,
            filePath: filePath,
            intent: store[filePath],
            onIntentChange: { store[filePath] = $0 }
        )
        defer { fixture.window.isHidden = true }

        let body = try #require(
            fixture.controller.installedBodyViewForTesting as? NativeFullScreenMarkdownBody
        )
        // One layout pass can size the collection view at offset 0 before
        // `scheduleExplicitFocus` applies the stored mid-document restore.
        fixture.controller.viewWillDisappear(false)
        #expect(store[filePath] == detached)
        #expect(store[filePath] != .top)

        await body.debugWaitForDocumentPreparationForTesting()
        let settled = await waitForMainActorCondition(timeout: .seconds(2)) {
            fixture.controller.view.layoutIfNeeded()
            return body.currentViewportIntent() != .top
        }
        #expect(settled)

        let collection = try #require(
            timelineFirstView(ofType: UICollectionView.self, in: body)
        )
        collection.setContentOffset(
            CGPoint(x: collection.contentOffset.x, y: -collection.adjustedContentInset.top),
            animated: false
        )
        fixture.controller.view.layoutIfNeeded()
        #expect(body.currentViewportIntent() == .top)

        fixture.controller.viewWillDisappear(false)
        #expect(store[filePath] == .top)
    }

    @Test("laid-out top replaces a stored mid-document restore")
    func laidOutTopReplacesStoredMidDocumentIntent() async throws {
        let content = tallMarkdown(paragraphs: 48)
        let filePath = "docs/README.md"
        var store = FullScreenMarkdownViewportRestoreState()

        let fixture = attachMarkdownController(
            content: content,
            filePath: filePath,
            intent: store[filePath],
            onIntentChange: { store[filePath] = $0 }
        )
        defer { fixture.window.isHidden = true }

        let body = try #require(
            fixture.controller.installedBodyViewForTesting as? NativeFullScreenMarkdownBody
        )
        await body.debugWaitForDocumentPreparationForTesting()
        fixture.controller.view.layoutIfNeeded()
        body.debugScrollItemIntoViewForTesting(
            max(0, body.debugRenderedSegmentCountForTesting / 2)
        )
        fixture.controller.view.layoutIfNeeded()

        #expect(body.currentViewportIntent() != .top)
        fixture.controller.viewWillDisappear(false)
        #expect(store[filePath] != nil)
        #expect(store[filePath] != .top)

        let collection = try #require(
            timelineFirstView(ofType: UICollectionView.self, in: body)
        )
        collection.setContentOffset(
            CGPoint(x: collection.contentOffset.x, y: -collection.adjustedContentInset.top),
            animated: false
        )
        fixture.controller.view.layoutIfNeeded()
        #expect(body.currentViewportIntent() == .top)

        fixture.controller.viewWillDisappear(false)
        #expect(store[filePath] == .top)
    }

    @Test("file browser and destination hosts wire the keyed markdown restore store")
    func fileBrowserAndDestinationHostsWireKeyedMarkdownViewportRestore() throws {
        var store = FullScreenMarkdownViewportRestoreState()
        let binding = Binding(
            get: { store },
            set: { store = $0 }
        )
        let filePath = ".pi/markdown-rendering-stress-test.md"
        let fileName = "markdown-rendering-stress-test.md"
        let detached = FullScreenMarkdownViewportIntent.detached(
            FullScreenMarkdownViewportAnchor(
                segmentID: nil,
                offsetInItem: 18,
                absoluteOffset: 640
            )
        )
        let browser = FileBrowserView(workspaceId: "workspace-1", initialPath: "")
        let workspaceDestination = WorkspaceLinkedFileDestinationView(
            target: .workspaceFile(
                serverId: "server-1",
                workspaceId: "workspace-1",
                path: filePath,
                fileName: fileName
            )
        )
        let hostDestination = WorkspaceLinkedFileDestinationView(
            target: .hostFile(
                serverId: "server-1",
                workspaceId: "workspace-1",
                path: filePath,
                fileName: fileName
            )
        )
        let contents: [(String, FileBrowserContentView)] = [
            (
                "treePaneSelectedFile",
                browser.debugTreePaneSelectedFileContentForTesting(
                    selection: FileBrowserSelection(path: filePath, name: fileName, size: nil),
                    store: binding
                )
            ),
            (
                "compactNavigationLink",
                browser.debugCompactNavigationFileContentForTesting(
                    path: filePath,
                    name: fileName,
                    size: nil,
                    store: binding
                )
            ),
            (
                "workspaceLinkedDestination.workspaceFile",
                workspaceDestination.debugWorkspaceFileContentForTesting(store: binding)
            ),
            (
                "workspaceLinkedDestination.hostFile",
                hostDestination.debugHostFileContentForTesting(store: binding)
            ),
        ]

        for (name, content) in contents {
            store = FullScreenMarkdownViewportRestoreState()
            #expect(
                content.debugHasMarkdownViewportRestoreForTesting,
                "\(name) dropped the restore store"
            )
            let restore = try #require(
                content.debugMarkdownViewportRestoreForTesting,
                "\(name) dropped the restore store"
            )
            restore.wrappedValue[filePath] = detached
            #expect(
                store[filePath] == detached,
                "\(name) did not write through the host store"
            )
            restore.wrappedValue[filePath] = .top
            #expect(
                store[filePath] == .top,
                "\(name) blocked a laid-out top from replacing the stored intent"
            )
        }
    }

    @Test("Markdown reader restores its viewport after a linked-file push rebuild")
    func markdownReaderRestoresViewportAfterLinkedFilePushRebuild() async throws {
        let content = tallMarkdown(paragraphs: 48)
        let filePath = "docs/README.md"
        var store = FullScreenMarkdownViewportRestoreState()

        let first = attachMarkdownController(
            content: content,
            filePath: filePath,
            intent: store[filePath],
            onIntentChange: { store[filePath] = $0 }
        )
        defer { first.window.isHidden = true }

        let firstBody = try #require(
            first.controller.installedBodyViewForTesting as? NativeFullScreenMarkdownBody
        )
        await firstBody.debugWaitForDocumentPreparationForTesting()
        first.controller.view.layoutIfNeeded()
        firstBody.debugScrollItemIntoViewForTesting(
            max(0, firstBody.debugRenderedSegmentCountForTesting / 2)
        )
        first.controller.view.layoutIfNeeded()

        let firstCollection = try #require(
            timelineFirstView(ofType: UICollectionView.self, in: firstBody)
        )
        let detachedY = firstCollection.contentOffset.y
        #expect(detachedY > 28)
        #expect(firstBody.currentViewportIntent() != .top)

        first.controller.viewWillDisappear(false)
        #expect(store[filePath] != nil)
        #expect(store[filePath] != .top)
        #expect(store["docs/other.md"] == nil)

        let second = attachMarkdownController(
            content: content,
            filePath: filePath,
            intent: store[filePath]
        )
        defer { second.window.isHidden = true }

        let secondBody = try #require(
            second.controller.installedBodyViewForTesting as? NativeFullScreenMarkdownBody
        )
        await secondBody.debugWaitForDocumentPreparationForTesting()
        second.controller.view.layoutIfNeeded()

        let restored = await waitForMainActorCondition(timeout: .seconds(2)) {
            second.controller.view.layoutIfNeeded()
            guard let collection = timelineFirstView(
                ofType: UICollectionView.self,
                in: secondBody
            ) else { return false }
            return abs(collection.contentOffset.y - detachedY) < 2
        }
        let secondCollection = try #require(
            timelineFirstView(ofType: UICollectionView.self, in: secondBody)
        )
        #expect(restored)
        #expect(abs(secondCollection.contentOffset.y - detachedY) < 2)
        #expect(secondCollection.contentOffset.y > 28)
    }

    @Test("already-completed thinking opens directly in immutable Markdown")
    func completedThinkingOpensInImmutableMarkdown() {
        let stream = ThinkingTraceStream(text: "Final **reasoning**.", isDone: true)
        let controller = makeController(
            content: .thinking(content: stream.snapshot.text, stream: stream)
        )

        #expect(controller.installedBodyViewForTesting is NativeFullScreenMarkdownBody)
        #expect(!(controller.installedBodyViewForTesting is NativeFullScreenThinkingBody))
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
        await drainMutableMarkdownQueue()
        fixture.window.layoutIfNeeded()
        #expect(abs(scroll.contentOffset.y - maximumOffsetY(scroll)) < 1)

        body.scrollViewWillBeginDragging(scroll)
        let detachedY = max(80, maximumOffsetY(scroll) / 2)
        scroll.contentOffset.y = detachedY
        body.scrollViewDidEndDragging(scroll, willDecelerate: false)
        body.update(content: initial + "\n\nA new live tail paragraph grows again.", isStreaming: true)
        await drainMutableMarkdownQueue()
        fixture.window.layoutIfNeeded()

        #expect(abs(scroll.contentOffset.y - detachedY) < 1)
        #expect(maximumOffsetY(scroll) - scroll.contentOffset.y > 28)
    }

    @Test("live bursts apply immediately while completion still swaps once")
    func liveBurstCadenceAndCompletionFlush() throws {
        let body = makeBody(content: "Initial")
        let initialApplyCount = body.debugMutableApplyCountForTesting

        for index in 0..<12 {
            body.update(content: "Initial \(index)", isStreaming: true)
        }

        #expect(body.debugMutableApplyCountForTesting == initialApplyCount + 12)

        body.update(content: "Final bytes", isStreaming: false)
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

    @Test("attached short viewport captures tail instead of top")
    func capturingPrefersFollowsTailOverTop() {
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 393, height: 844))
        scroll.contentSize = CGSize(width: 393, height: 220)
        scroll.contentOffset = .zero

        let intent = FullScreenMarkdownViewportIntent.capturing(
            scrollView: scroll,
            followsTail: true
        )

        #expect(intent == .tail)
        #expect(scroll.contentSize.height < scroll.bounds.height)
    }

    @Test("detached short viewport that still fits is not classified as tail")
    func capturingPrefersTopWhenDetachedShortViewportFits() {
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 393, height: 844))
        scroll.contentSize = CGSize(width: 393, height: 220)
        scroll.contentOffset = .zero

        let intent = FullScreenMarkdownViewportIntent.capturing(
            scrollView: scroll,
            followsTail: false
        )

        #expect(intent == .top)
        #expect(scroll.contentSize.height < scroll.bounds.height)
    }

    @Test("detached mid-document position survives a large final append")
    func completionPreservesDetachedContentAnchor() async throws {
        let initial = tallMarkdown(paragraphs: 45)
        let body = makeBody(content: initial)
        let fixture = attach(body)
        defer { fixture.window.isHidden = true }
        await drainMutableMarkdownQueue()
        fixture.window.layoutIfNeeded()

        let scroll = body.debugMutableScrollViewForTesting
        body.scrollViewWillBeginDragging(scroll)
        let detachedY = max(80, maximumOffsetY(scroll) / 2)
        scroll.contentOffset.y = detachedY
        body.scrollViewDidEndDragging(scroll, willDecelerate: false)
        fixture.window.layoutIfNeeded()

        let visibleBefore = try #require(firstVisibleParagraphLabel(in: body, scrollView: scroll))
        let oldMinimumY = -scroll.adjustedContentInset.top
        let oldMaximumY = maximumOffsetY(scroll)
        let oldProgress = (detachedY - oldMinimumY) / max(oldMaximumY - oldMinimumY, 1)

        let final = initial + "\n\n" + tallMarkdown(paragraphs: 40)
        body.update(content: final, isStreaming: false)
        await drainMutableMarkdownQueue()
        fixture.window.layoutIfNeeded()
        await drainMutableMarkdownQueue()

        let collection = try #require(timelineFirstView(ofType: UICollectionView.self, in: body))
        collection.layoutIfNeeded()
        let visibleAfter = try #require(firstVisibleParagraphLabel(in: body, scrollView: collection))
        let progressRestoredY = -collection.adjustedContentInset.top
            + (maximumOffsetY(collection) + collection.adjustedContentInset.top) * oldProgress

        #expect(visibleAfter == visibleBefore)
        #expect(abs(collection.contentOffset.y - progressRestoredY) > 40)
        #expect(maximumOffsetY(collection) - collection.contentOffset.y > 28)
    }

    @Test("detached completion keeps a content anchor after a mixed relative-image paragraph")
    func detachedCompletionKeepsAnchorAfterMixedRelativeImage() async throws {
        let mixedPrefix = "See the chart ![chart](images/chart.png) before the rest.\n\n"
        let initial = mixedPrefix + tallMarkdown(paragraphs: 45)
        let body = NativeMutableFullScreenMarkdownBody(
            content: initial,
            isStreaming: true,
            themeID: .dark,
            palette: ThemeID.dark.palette,
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil,
            serverID: "server-1",
            workspaceID: "workspace-1",
            sessionID: "session-1",
            serverBaseURL: try #require(URL(string: "https://server.example.com")),
            sourceFilePath: "docs/Draft.md",
            fetchWorkspaceFile: { _, _ in try #require(Self.pngData()) }
        )
        let fixture = attach(body)
        defer { fixture.window.isHidden = true }
        await drainMutableMarkdownQueue()
        fixture.window.layoutIfNeeded()

        let scroll = body.debugMutableScrollViewForTesting
        body.scrollViewWillBeginDragging(scroll)
        let detachedY = max(80, maximumOffsetY(scroll) / 2)
        scroll.contentOffset.y = detachedY
        body.scrollViewDidEndDragging(scroll, willDecelerate: false)
        fixture.window.layoutIfNeeded()

        let capturedAnchor = try #require({
            if case .detached(let anchor) = body.currentViewportIntent() { return anchor }
            return nil
        }())
        let capturedID = try #require(capturedAnchor.segmentID)
        let visibleBefore = try #require(firstVisibleParagraphLabel(in: body, scrollView: scroll))

        let final = initial + "\n\n" + tallMarkdown(paragraphs: 40)
        body.update(content: final, isStreaming: false)
        await drainMutableMarkdownQueue()
        fixture.window.layoutIfNeeded()
        await drainMutableMarkdownQueue()

        let collection = try #require(timelineFirstView(ofType: UICollectionView.self, in: body))
        collection.layoutIfNeeded()
        let visibleAfter = try #require(firstVisibleParagraphLabel(in: body, scrollView: collection))
        let reader = try #require(timelineFirstView(ofType: NativeFullScreenMarkdownBody.self, in: body))

        #expect(visibleAfter == visibleBefore)
        #expect(reader.debugRenderedSegmentIDsForTesting.contains(capturedID))
        #expect(maximumOffsetY(collection) - collection.contentOffset.y > 28)
    }

    @Test("attached short stream that still fits hands off as tail")
    func attachedShortCompletionHandsOffAsTail() async throws {
        let initial = "Short live paragraph that still fits the viewport."
        let body = makeBody(content: initial)
        let fixture = attach(body)
        defer { fixture.window.isHidden = true }
        await drainMutableMarkdownQueue()
        fixture.window.layoutIfNeeded()

        let scroll = body.debugMutableScrollViewForTesting
        #expect(scroll.contentSize.height <= scroll.bounds.height + 1)
        #expect(body.currentViewportIntent() == .tail)

        let final = initial + "\n\n" + tallMarkdown(paragraphs: 30)
        body.update(content: final, isStreaming: false)
        await drainMutableMarkdownQueue()
        fixture.window.layoutIfNeeded()
        await drainMutableMarkdownQueue()

        let collection = try #require(timelineFirstView(ofType: UICollectionView.self, in: body))
        collection.layoutIfNeeded()
        #expect(abs(collection.contentOffset.y - maximumOffsetY(collection)) < 1)
        #expect(collection.contentOffset.y > 80)
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

    @Test("mutable context preserves markdown video source through live render and immutable handoff")
    func videoSourceFlowsThroughSharedRenderer() async throws {
        var resolved = 0
        let provider: MarkdownVideoMediaSourceProvider = { _ in
            resolved += 1
            throw CocoaError(.fileNoSuchFile)
        }
        let body = NativeMutableFullScreenMarkdownBody(
            content: "Before\n\n![[movie.mp4]]\n\nAfter",
            isStreaming: true,
            themeID: .dark,
            palette: ThemeID.dark.palette,
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil,
            serverID: "server-1",
            workspaceID: "workspace-1",
            sessionID: "session-1",
            serverBaseURL: try #require(URL(string: "https://server.example.com")),
            sourceFilePath: "docs/Draft.md",
            makeMarkdownVideoSource: provider
        )
        let fixture = attach(body)
        defer { fixture.window.isHidden = true }

        let liveVideoMounted = await waitForTimelineCondition(timeoutMs: 2_000) { @MainActor in
            timelineFirstView(ofType: NativeMarkdownVideoView.self, in: body) != nil
        }
        #expect(liveVideoMounted)
        let liveResolved = await waitForTimelineCondition(timeoutMs: 2_000) { @MainActor in
            resolved > 0
        }
        #expect(liveResolved)
        #expect(resolved >= 1)

        let resolvedBeforeHandoff = resolved
        body.update(
            content: "Before\n\n![[movie.mp4]]\n\nAfter\n\nDone.",
            isStreaming: false,
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil,
            serverID: "server-1",
            workspaceID: "workspace-1",
            sessionID: "session-1",
            serverBaseURL: try #require(URL(string: "https://server.example.com")),
            sourceFilePath: "docs/Draft.md",
            fetchWorkspaceFile: nil,
            fetchSessionFile: nil,
            makeMarkdownVideoSource: provider
        )
        await drainMutableMarkdownQueue()
        fixture.window.layoutIfNeeded()

        #expect(body.debugIsShowingImmutableReaderForTesting)
        let immutableVideoMounted = await waitForTimelineCondition(timeoutMs: 2_000) { @MainActor in
            timelineFirstView(ofType: NativeMarkdownVideoView.self, in: body) != nil
        }
        #expect(immutableVideoMounted)
        let handoffResolved = await waitForTimelineCondition(timeoutMs: 2_000) { @MainActor in
            resolved > resolvedBeforeHandoff
        }
        #expect(handoffResolved)
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

    private func attachMarkdownController(
        content: String,
        filePath: String,
        intent: FullScreenMarkdownViewportIntent? = nil,
        onIntentChange: ((FullScreenMarkdownViewportIntent) -> Void)? = nil
    ) -> (controller: FullScreenCodeViewController, window: UIWindow) {
        let controller = FullScreenCodeViewController(
            content: .markdown(content: content, filePath: filePath),
            presentationMode: .embedded(onDismiss: {}),
            markdownViewportIntent: intent,
            onMarkdownViewportIntentChange: onIntentChange
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        return (controller, window)
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

    private func firstVisibleParagraphLabel(in root: UIView, scrollView: UIScrollView) -> String? {
        let visibleTop = scrollView.contentOffset.y + 8
        let visibleBottom = scrollView.contentOffset.y + scrollView.bounds.height
        for textView in timelineAllTextViews(in: root) {
            let frame = textView.convert(textView.bounds, to: scrollView)
            guard frame.maxY > visibleTop, frame.minY < visibleBottom else { continue }
            let point = CGPoint(x: 8, y: max(0, visibleTop - frame.minY))
            guard let position = textView.closestPosition(to: point),
                  let range = textView.tokenizer.rangeEnclosingPosition(
                    position,
                    with: .paragraph,
                    inDirection: .layout(.right)
                  ),
                  let paragraph = textView.text(in: range),
                  let match = paragraph.range(of: #"Paragraph \d+"#, options: .regularExpression)
            else { continue }
            return String(paragraph[match])
        }
        return nil
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
