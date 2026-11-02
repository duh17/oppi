import Foundation
import Testing
import UIKit
@testable import Oppi

/// A reader opened from a timeline row outlives that row. Opening it pushes a
/// page, so the chat leaves the window; the timeline keeps applying rows, but a
/// row that left the viewport is not configured again, so its own cell stops
/// hearing about them. A reader must follow its item's text whether or not the
/// timeline still configures a cell for it.
@Suite("Full-screen reader stream", .serialized)
@MainActor
struct FullScreenReaderStreamTests {
    @Test("a thinking reader keeps streaming after its row scrolls out of view")
    func thinkingReaderKeepsStreamingWithoutItsCell() async throws {
        let fixture = ReaderTimelineFixture(sessionId: "session-reader-thinking")
        defer { fixture.window.isHidden = true }

        let opening = thinkingText(lines: 30)
        let trailer = trailerRows(count: 60)
        fixture.apply(
            items: [.thinking(id: "think-1", preview: opening, hasMore: false, isDone: true)] + trailer,
            liveRowIDs: ["think-1"]
        )

        let row = try fixture.thinkingRow(at: 0)
        row.showFullScreen()

        let payload = try #require(fixture.opened)
        guard case .document(let content, _) = payload.kind,
              case let .thinking(openedText, openedStream) = content else {
            Issue.record("expected a thinking reader, got \(payload.kind)")
            return
        }
        #expect(openedText == opening)
        let stream = try #require(openedStream)

        let rowIndexPath = IndexPath(item: 0, section: 0)
        // The row renders its own preview, so "never saw the new line" below is a
        // real read rather than an empty string.
        #expect(
            fixture.rowText(at: rowIndexPath)?.contains("Reasoning line") == true,
            "the row renders its text before it scrolls away: \(fixture.rowText(at: rowIndexPath) ?? "no cell")"
        )

        // The answer below keeps growing, so the thinking row leaves the viewport
        // and the timeline stops showing it.
        let leftViewport = await fixture.scrollToTailLeavingViewport(at: 0)
        #expect(
            leftViewport,
            "the thinking row must have left the viewport for this to be the freeze: \(fixture.geometryForTesting)"
        )

        let reader = fixture.presentReader(content: content)
        let liveBody = try #require(
            reader.installedBodyViewForTesting as? NativeFullScreenThinkingBody
        )
        #expect(fixture.chatHost.view.window == nil, "the push must take the chat off screen")
        #expect(liveBody.debugTextViewForTesting.text == opening)

        let grown = opening + "\nReasoning line 31"
        fixture.apply(
            items: [.thinking(id: "think-1", preview: grown, hasMore: false, isDone: true)] + trailer,
            liveRowIDs: ["think-1"]
        )
        fixture.window.layoutIfNeeded()

        #expect(
            stream.snapshot.text == grown,
            "reader stream after the row left the viewport: \(stream.snapshot.text.suffix(60))"
        )
        #expect(liveBody.debugTextViewForTesting.text == grown)
        // The row itself never heard about the new line: whatever cell the timeline
        // still holds for it was not configured, which is the freeze the reader has
        // to survive on its own.
        let rowTextAfterGrowth = fixture.rowText(at: rowIndexPath)
        #expect(
            rowTextAfterGrowth?.contains("Reasoning line 31") != true,
            "the row that left the viewport was configured with the new line: \(rowTextAfterGrowth ?? "no cell")"
        )

        // The turn ending still completes the reader.
        fixture.apply(
            items: [.thinking(id: "think-1", preview: grown, hasMore: false, isDone: true)] + trailer,
            liveRowIDs: [],
            isBusy: false
        )
        await drainMainQueue()
        fixture.window.layoutIfNeeded()

        #expect(stream.snapshot.isDone)
        #expect(reader.installedBodyViewForTesting is NativeFullScreenMarkdownBody)
    }

    @Test("a live tool reader follows its running call, not a reused cell")
    func toolReaderKeepsStreamingWithoutItsCell() async throws {
        let fixture = ReaderTimelineFixture(sessionId: "session-reader-tool")
        defer { fixture.window.isHidden = true }

        let trailer = trailerRows(count: 60)
        fixture.reducer.expandedItemIDs.insert("tool-1")
        fixture.apply(items: [runningTool(output: "Compiling module 1")] + trailer, liveRowIDs: [])

        let cell = try configuredTimelineCell(in: fixture.collectionView, item: 0)
        let row = try #require(
            ChatTimelineController.firstSubview(
                ofType: ToolTimelineRowContentView.self,
                in: cell.contentView
            )
        )
        row.showFullScreenContent()

        let payload = try #require(fixture.opened)
        guard case .document(let content, _) = payload.kind,
              case let .terminal(_, _, openedStream, _) = content else {
            Issue.record("expected a running terminal reader, got \(payload.kind)")
            return
        }
        let stream = try #require(openedStream)

        let rowIndexPath = IndexPath(item: 0, section: 0)
        #expect(
            fixture.rowText(at: rowIndexPath)?.contains("Compiling module 1") == true,
            "the row renders its output before it scrolls away: \(fixture.rowText(at: rowIndexPath) ?? "no cell")"
        )
        let leftViewport = await fixture.scrollToTailLeavingViewport(at: 0)
        #expect(
            leftViewport,
            "the tool row must have left the viewport for this to be the freeze: \(fixture.geometryForTesting)"
        )

        let reader = fixture.presentReader(content: content)

        fixture.apply(
            items: [runningTool(output: "Compiling module 1\nCompiling module 2\nBuild complete")] + trailer,
            liveRowIDs: []
        )
        fixture.window.layoutIfNeeded()
        await drainMainQueue()

        #expect(
            stream.snapshot.output.contains("Build complete"),
            "tool reader stream after the row left the viewport: \(stream.snapshot.output)"
        )
        let rendered = timelineAllTextViews(in: reader.view)
            .map(timelineRenderedText)
            .joined(separator: "\n")
        #expect(rendered.contains("Build complete"))
        #expect(!stream.snapshot.isDone, "a running call's reader is still live")
        // The row itself was not configured with the new output either: the reader
        // followed the call without it.
        let rowTextAfterGrowth = fixture.rowText(at: rowIndexPath)
        #expect(
            rowTextAfterGrowth?.contains("Build complete") != true,
            "the row that left the viewport was configured with the new output: \(rowTextAfterGrowth ?? "no cell")"
        )

        // The call finishing reaches the reader once, even with the row out of the
        // viewport, and the reader mounts the finished body.
        fixture.apply(
            items: [completedTool(output: "Compiling module 1\nBuild complete")] + trailer,
            liveRowIDs: [],
            isBusy: false
        )
        await drainMainQueue()
        fixture.window.layoutIfNeeded()

        #expect(stream.snapshot.isDone)
        #expect(stream.snapshot.output.contains("Build complete"))
        let finished = timelineAllTextViews(in: reader.view)
            .map(timelineRenderedText)
            .joined(separator: "\n")
        #expect(finished.contains("Build complete"), "the reader shows the finished call's output")
    }

    @Test("a folded row's reader keeps streaming once the row is shown again")
    func foldedRowKeepsItsReader() throws {
        let fixture = ReaderTimelineFixture(sessionId: "session-reader-folded")
        defer { fixture.window.isHidden = true }

        let opening = thinkingText(lines: 30)
        let trailer = trailerRows(count: 60)
        fixture.apply(
            items: [.thinking(id: "think-1", preview: opening, hasMore: false, isDone: true)] + trailer,
            liveRowIDs: ["think-1"]
        )
        let row = try fixture.thinkingRow(at: 0)
        row.showFullScreen()
        let payload = try #require(fixture.opened)
        guard case .document(let content, _) = payload.kind,
              case let .thinking(_, openedStream) = content else {
            Issue.record("expected a thinking reader, got \(payload.kind)")
            return
        }
        let stream = try #require(openedStream)
        _ = fixture.presentReader(content: content)

        // A collapsed work line folds this row out of the rendered rows while
        // its item is still in the timeline: the reader must survive that.
        fixture.apply(
            items: trailer,
            fullTimelineItemIDs: ["think-1"] + trailer.map(\.id),
            liveRowIDs: ["think-1"]
        )
        #expect(
            fixture.controller.readerTraces.openItemIDs == ["think-1"],
            "folding must not end the reader"
        )

        // Unfolded again with more text: the reader follows it.
        let grown = opening + "\nReasoning line 31"
        fixture.apply(
            items: [.thinking(id: "think-1", preview: grown, hasMore: false, isDone: true)] + trailer,
            liveRowIDs: ["think-1"]
        )
        #expect(stream.snapshot.text == grown)
    }

    @Test("a stored payload keeps its trace for a reader rebuilt from it")
    func storedPayloadKeepsTheTraceAlive() throws {
        let fixture = ReaderTimelineFixture(sessionId: "session-reader-store")
        defer { fixture.window.isHidden = true }

        let opening = thinkingText(lines: 30)
        let trailer = trailerRows(count: 60)
        fixture.apply(
            items: [.thinking(id: "think-1", preview: opening, hasMore: false, isDone: true)] + trailer,
            liveRowIDs: ["think-1"]
        )
        let row = try fixture.thinkingRow(at: 0)
        row.showFullScreen()
        // A split or stack swap rebuilds the reader from the store's payload, so
        // the store is the owner that keeps the trace alive in between.
        let store = ChatReaderPayloadStore()
        let target = store.store(try #require(fixture.opened))
        fixture.discardOpenedPayload()

        let grown = opening + "\nReasoning line 31"
        fixture.apply(
            items: [.thinking(id: "think-1", preview: grown, hasMore: false, isDone: true)] + trailer,
            liveRowIDs: ["think-1"]
        )

        #expect(
            fixture.controller.readerTraces.openItemIDs == ["think-1"],
            "the store's payload still holds the trace"
        )
        // Scoped so this test holds no reference of its own: the store is the
        // only owner the trace has left.
        var rebuiltText: String?
        do {
            guard case .document(let rebuilt, _)? = store.payload(for: target.id)?.kind,
                  case let .thinking(_, stream) = rebuilt else {
                Issue.record("expected the stored payload to still be a thinking reader")
                return
            }
            rebuiltText = stream?.snapshot.text
        }
        #expect(rebuiltText == grown, "a rebuilt reader observes the same live trace")

        store.remove(target)
        fixture.apply(
            items: [.thinking(id: "think-1", preview: grown, hasMore: false, isDone: true)] + trailer,
            liveRowIDs: ["think-1"]
        )
        #expect(fixture.controller.readerTraces.isEmpty, "no owner left, no reader to feed")
    }

    @Test("a reader that closes releases its trace and is not fed again")
    func closedReaderIsReleased() async throws {
        let fixture = ReaderTimelineFixture(sessionId: "session-reader-closed")
        defer { fixture.window.isHidden = true }

        let opening = thinkingText(lines: 30)
        let trailer = trailerRows(count: 60)
        fixture.apply(
            items: [.thinking(id: "think-1", preview: opening, hasMore: false, isDone: true)] + trailer,
            liveRowIDs: ["think-1"]
        )
        // The payload a reader was opened from is what keeps its trace alive, so
        // closing the reader and dropping the payload is the exact release.
        weak var releasedTrace: ReaderTrace<ThinkingSnapshot>?
        var reader: FullScreenCodeViewController?
        do {
            let row = try fixture.thinkingRow(at: 0)
            row.showFullScreen()
            let payload = try #require(fixture.opened)
            guard case .document(let content, _) = payload.kind,
                  case let .thinking(_, openedStream) = content else {
                Issue.record("expected a thinking reader, got \(payload.kind)")
                return
            }
            releasedTrace = openedStream
            reader = fixture.presentReader(content: content)

            // The timeline keeps applying while the reader is up.
            fixture.apply(
                items: [.thinking(id: "think-1", preview: opening, hasMore: false, isDone: true)] + trailer,
                liveRowIDs: ["think-1"]
            )
            #expect(fixture.controller.readerTraces.openItemIDs == ["think-1"])
            fixture.closeReader(reader)
        }
        reader = nil
        fixture.discardOpenedPayload()

        let released = await waitForMainActorCondition(timeout: .seconds(2)) {
            releasedTrace == nil
        }
        #expect(released, "closing the reader and dropping its payload releases the trace")

        fixture.apply(
            items: [.thinking(id: "think-1", preview: opening, hasMore: false, isDone: true)] + trailer,
            liveRowIDs: ["think-1"]
        )
        #expect(fixture.controller.readerTraces.isEmpty, "a closed reader is not fed")
    }

    private func completedTool(output: String) -> ChatItem {
        .toolCall(
            id: "tool-1",
            tool: "bash",
            argsSummary: "swift build",
            outputPreview: output,
            outputByteCount: output.utf8.count,
            isError: false,
            isDone: true
        )
    }

    private func runningTool(output: String) -> ChatItem {
        .toolCall(
            id: "tool-1",
            tool: "bash",
            argsSummary: "swift build",
            outputPreview: output,
            outputByteCount: output.utf8.count,
            isError: false,
            isDone: false
        )
    }

    private func thinkingText(lines: Int) -> String {
        (1...lines).map { "Reasoning line \($0): weighing the options" }
            .joined(separator: "\n")
    }

    /// Rows below the one a reader follows, so the timeline scrolls and that
    /// row's cell is recycled.
    private func trailerRows(count: Int) -> [ChatItem] {
        (1...count).map { .systemEvent(id: "trailer-\($0)", message: "step \($0) finished") }
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

/// The chat and its timeline on one side, the pushed reader on the other, so a
/// test sees both what the timeline applied and what the reader shows.
@MainActor
private final class ReaderTimelineFixture {
    let window: UIWindow
    let navigation: UINavigationController
    let chatHost = UIViewController()
    let collectionView: UICollectionView
    let controller = ChatTimelineController()
    let reducer = TimelineReducer()
    let toolOutputStore = ToolOutputStore()
    let toolArgsStore = ToolArgsStore()
    let connection = ServerConnection()
    let scrollController = ChatScrollController()
    let audioPlayer = AudioPlayerService()
    private let sessionId: String
    private(set) var opened: ChatReaderPayload?
    private var itemCount = 0

    init(sessionId: String) {
        self.sessionId = sessionId
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        navigation = UINavigationController(rootViewController: chatHost)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        collectionView = UICollectionView(
            frame: window.bounds,
            collectionViewLayout: ChatTimelineController.makeTestLayout()
        )
        chatHost.view.addSubview(collectionView)
        collectionView.frame = chatHost.view.bounds
        controller.configureDataSource(collectionView: collectionView)
        window.layoutIfNeeded()
    }

    /// The push every row's full-screen action performs: the chat leaves the window.
    func presentReader(content: FullScreenCodeContent) -> FullScreenCodeViewController {
        let reader = FullScreenCodeViewController.makeHarnessController(
            content: content,
            reviewCommentSelectionContext: nil
        )
        navigation.pushViewController(reader, animated: false)
        window.layoutIfNeeded()
        return reader
    }

    /// Drops the payload a reader was opened from. With it goes the last owner
    /// of the trace (`ChatReaderPayloadStore` holds one the same way).
    func discardOpenedPayload() {
        opened = nil
    }

    /// The reader's own back action: the page pops and its body is released.
    func closeReader(_ reader: FullScreenCodeViewController?) {
        navigation.popViewController(animated: false)
        reader?.view.removeFromSuperview()
        window.layoutIfNeeded()
    }

    func apply(
        items: [ChatItem],
        fullTimelineItemIDs: [String]? = nil,
        liveRowIDs: Set<String>,
        isBusy: Bool = true
    ) {
        itemCount = items.count
        let configuration = makeTimelineConfiguration(
            items: items,
            fullTimelineItemIDs: fullTimelineItemIDs,
            isBusy: isBusy,
            liveRowIDs: liveRowIDs,
            onOpenChatReader: { [weak self] in self?.opened = $0 },
            sessionId: sessionId,
            reducer: reducer,
            toolOutputStore: toolOutputStore,
            toolArgsStore: toolArgsStore,
            connection: connection,
            scrollController: scrollController,
            audioPlayer: audioPlayer
        )
        controller.apply(configuration: configuration, to: collectionView)
        settleTimelineLayout(collectionView)
    }

    /// Renders the row at `indexPath` from the cell the timeline holds for it, or
    /// nil when there is no cell.
    func rowText(at indexPath: IndexPath) -> String? {
        collectionView.cellForItem(at: indexPath).map { cell in
            (timelineAllLabels(in: cell.contentView).map(timelineRenderedText)
                + timelineAllTextViews(in: cell.contentView).map(timelineRenderedText))
                .joined(separator: "\n")
        }
    }

    /// Scrolls the viewport to the tail and waits until the timeline stops showing
    /// the row at `index`.
    ///
    /// The row leaving the visible set is the whole precondition this timeline can
    /// reach, and it is the one that matters: once it is out, no configuration
    /// reaches the row again until it comes back on screen (asserted where these
    /// tests apply the next text). `cellForItem(at:)` does not go nil here — UIKit
    /// keeps the cell for a row that left the viewport, hidden and still laid out
    /// at that row's frame, and hands it back to no wait: measured with the
    /// timeline still windowed, after two seconds of run-loop turns and layout
    /// passes it was `hidden=true inCollection=true frame=(16 8; 358 200)` with 49
    /// cells under a 17-row viewport. Asserting the nil instead made the
    /// precondition depend on a recycle that never came, while the reader's own
    /// behaviour was fine.
    func scrollToTailLeavingViewport(at index: Int) async -> Bool {
        settleTimelineLayout(collectionView)
        let insets = collectionView.adjustedContentInset
        let maxY = max(
            -insets.top,
            collectionView.contentSize.height - collectionView.bounds.height + insets.bottom
        )
        collectionView.setContentOffset(CGPoint(x: 0, y: maxY), animated: false)
        settleTimelineLayout(collectionView)
        let timeline = collectionView
        let row = IndexPath(item: index, section: 0)
        return await waitForTimelineCondition(timeoutMs: 2_000) { @MainActor in
            settleTimelineLayout(timeline)
            return !timeline.indexPathsForVisibleItems.contains(row)
        }
    }

    var geometryForTesting: String {
        let row = IndexPath(item: 0, section: 0)
        let cell = collectionView.cellForItem(at: row)
        let cellState = cell.map {
            "hidden=\($0.isHidden) inCollection=\($0.superview === collectionView) frame=\($0.frame)"
        } ?? "none"
        return "contentSize=\(collectionView.contentSize) bounds=\(collectionView.bounds) "
            + "offset=\(collectionView.contentOffset) items=\(itemCount) "
            + "visible=\(collectionView.indexPathsForVisibleItems.count) "
            + "row0Visible=\(collectionView.indexPathsForVisibleItems.contains(row)) "
            + "row0Cell=\(cellState) windowed=\(collectionView.window != nil) "
            + "subviews=\(collectionView.subviews.count)"
    }

    func thinkingRow(at index: Int) throws -> ThinkingTimelineRowContentView {
        let cell = try configuredTimelineCell(in: collectionView, item: index)
        return try #require(
            ChatTimelineController.firstSubview(
                ofType: ThinkingTimelineRowContentView.self,
                in: cell.contentView
            )
        )
    }
}
