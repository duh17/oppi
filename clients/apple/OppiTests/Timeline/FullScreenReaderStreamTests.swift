import Foundation
import Testing
import UIKit
@testable import Oppi

/// A reader opened from a timeline row outlives that row. Opening it pushes a
/// page, so the chat leaves the window; the timeline keeps applying rows, but
/// only a row that still has a configured cell hears about them. A reader must
/// follow its item's text whether or not its cell exists.
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

        let reader = fixture.presentReader(content: content)
        let liveBody = try #require(
            reader.installedBodyViewForTesting as? NativeFullScreenThinkingBody
        )
        #expect(fixture.chatHost.view.window == nil, "the push must take the chat off screen")
        #expect(liveBody.debugTextViewForTesting.text == opening)

        // The answer below keeps growing, so the thinking row leaves the viewport
        // and UIKit stops configuring its cell.
        fixture.scrollToTail()
        #expect(
            fixture.collectionView.cellForItem(at: IndexPath(item: 0, section: 0)) == nil,
            "the thinking row must have no configured cell for this to be the freeze: \(fixture.geometryForTesting)"
        )

        let grown = opening + "\nReasoning line 31"
        fixture.apply(
            items: [.thinking(id: "think-1", preview: grown, hasMore: false, isDone: true)] + trailer,
            liveRowIDs: ["think-1"]
        )
        fixture.window.layoutIfNeeded()

        #expect(
            stream.snapshot.text == grown,
            "reader stream after the row lost its cell: \(stream.snapshot.text.suffix(60))"
        )
        #expect(liveBody.debugTextViewForTesting.text == grown)

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

        let reader = fixture.presentReader(content: content)
        fixture.scrollToTail()
        #expect(
            fixture.collectionView.cellForItem(at: IndexPath(item: 0, section: 0)) == nil,
            "the tool row must have no configured cell for this to be the freeze: \(fixture.geometryForTesting)"
        )

        fixture.apply(
            items: [runningTool(output: "Compiling module 1\nCompiling module 2\nBuild complete")] + trailer,
            liveRowIDs: []
        )
        fixture.window.layoutIfNeeded()
        await drainMainQueue()

        #expect(
            stream.snapshot.output.contains("Build complete"),
            "tool reader stream after the row lost its cell: \(stream.snapshot.output)"
        )
        let rendered = timelineAllTextViews(in: reader.view)
            .map(timelineRenderedText)
            .joined(separator: "\n")
        #expect(rendered.contains("Build complete"))
        #expect(!stream.snapshot.isDone, "a running call's reader is still live")

        // The call finishing reaches the reader once, even without its cell, and
        // the reader mounts the finished body.
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

    @Test("a folded row keeps its reader instead of being treated as gone")
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
        guard case .document(let content, _) = payload.kind else {
            Issue.record("expected a document reader, got \(payload.kind)")
            return
        }
        _ = fixture.presentReader(content: content)

        // Quiet mode folds the finished turn: the row leaves the rendered rows
        // but its item is still in the timeline, so its reader survives.
        fixture.apply(
            items: trailer,
            fullTimelineItemIDs: ["think-1"] + trailer.map(\.id),
            liveRowIDs: ["think-1"]
        )

        #expect(fixture.controller.readerTraces.openItemIDs == ["think-1"])
    }

    @Test("a reader that closes is released and stops being fed")
    func closedReaderIsReleased() async throws {
        let fixture = ReaderTimelineFixture(sessionId: "session-reader-closed")
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

        var reader: FullScreenCodeViewController? = fixture.presentReader(content: content)
        #expect(stream.hasObservers)

        // The timeline keeps applying while the reader is up: the entry is live
        // and observed, not pending a mount.
        fixture.apply(
            items: [.thinking(id: "think-1", preview: opening, hasMore: false, isDone: true)] + trailer,
            liveRowIDs: ["think-1"]
        )
        #expect(fixture.controller.readerTraces.openItemIDs == ["think-1"])

        fixture.closeReader(reader)
        reader = nil
        let released = await waitForMainActorCondition(timeout: .seconds(2)) {
            !stream.hasObservers
        }
        #expect(released, "the popped reader must let go of the trace")

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

    /// Moves the viewport to the tail so the opened row's cell is recycled.
    func scrollToTail() {
        settleTimelineLayout(collectionView)
        let insets = collectionView.adjustedContentInset
        let maxY = max(
            -insets.top,
            collectionView.contentSize.height - collectionView.bounds.height + insets.bottom
        )
        collectionView.setContentOffset(CGPoint(x: 0, y: maxY), animated: false)
        settleTimelineLayout(collectionView)
    }

    var geometryForTesting: String {
        "contentSize=\(collectionView.contentSize) bounds=\(collectionView.bounds) "
            + "offset=\(collectionView.contentOffset) items=\(itemCount)"
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
