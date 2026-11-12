import Testing
import UIKit
@testable import Oppi

/// The chat's timeline beside today's trailing column while its divider moves
/// (`PaneLiveResizing`): no row layout while the divider moves, one bounded
/// reflow where it rests at the same reading position, and no row measured
/// again when a divider brings a width back.
@MainActor
@Suite("Pane live resize: timeline")
struct PaneLiveResizeTimelineTests {
    private static let landscape = CGSize(width: 1133, height: 744)

    @Test("a divider drag lays no rows out while it moves, then settles once at the tail")
    func dragHoldsThenSettlesAtTheTail() async throws {
        let host = try await makeHostWithOpenPanel()
        defer { host.hide() }
        let timeline = host.timeline
        let startWidth = timeline.bounds.width
        let column = try #require(host.chat.trailingColumn.resizeHandleForTesting)

        let rebuildsBefore = ChatTimelinePerf.layoutRebuildCount
        let measuredBefore = ChatTimelinePerf.rowMeasureCount
        column.onBegan?()
        for step in 1...20 {
            column.onChanged?(CGFloat(-6 * step))
            host.window.layoutIfNeeded()
        }
        #expect(ChatTimelinePerf.layoutRebuildCount == rebuildsBefore, "the timeline laid its rows out while the divider moved")
        #expect(ChatTimelinePerf.rowMeasureCount == measuredBefore, "rows were measured while the divider moved")
        #expect(timeline.bounds.width == startWidth, "the held timeline must keep its width")

        let settled = try await endDrag(column, translation: -120, host: host)
        #expect(timeline.bounds.width < startWidth - 100, "the timeline settles at the narrower width")
        #expect(settled.measured <= 12, "the settle measured \(settled.measured) rows")
        #expect(isAtTail(timeline), "a timeline on its tail stays on it")

        // Back to where it started: every visible row has a height at that width.
        column.onBegan?()
        column.onChanged?(120)
        host.window.layoutIfNeeded()
        let back = try await endDrag(column, translation: 120, host: host)
        #expect(abs(timeline.bounds.width - startWidth) <= 1)
        #expect(back.measured == 0, "the width toggled back measured \(back.measured) rows")
        #expect(isAtTail(timeline))
    }

    @Test("a reader scrolled up keeps the row it reads across the settle")
    func detachedReaderKeepsItsRow() async throws {
        let host = try await makeHostWithOpenPanel()
        defer { host.hide() }
        let timeline = host.timeline
        timeline.setContentOffset(CGPoint(x: 0, y: timeline.contentOffset.y - 1_500), animated: false)
        host.chat.timeline.scrollController?.setUserInteracting(false)
        host.window.layoutIfNeeded()
        host.chat.timeline.updateScrollState(timeline, preserveDetachedState: false)
        try #require(!(host.chat.timeline.scrollController?.isCurrentlyNearBottom ?? true), "the timeline must be off its tail")
        let before = try #require(firstReadRow(timeline, controller: host.chat.timeline))

        let column = try #require(host.chat.trailingColumn.resizeHandleForTesting)
        column.onBegan?()
        column.onChanged?(-150)
        host.window.layoutIfNeeded()
        _ = try await endDrag(column, translation: -150, host: host)

        let item = try #require(host.chat.timeline.currentIDs.firstIndex(of: before.id))
        let attributes = try #require(timeline.layoutAttributesForItem(at: IndexPath(item: item, section: 0)))
        #expect(abs(attributes.frame.minY - timeline.contentOffset.y - before.screenY) <= 1, "the row read moved")
    }

    @Test("a second rotation measures no rows")
    func rotationBackMeasuresNothing() async throws {
        let host = try await makeHostWithOpenPanel()
        defer { host.hide() }
        let portrait = CGSize(width: Self.landscape.height, height: Self.landscape.width)
        func rotate(to size: CGSize) async throws -> Int {
            // A turn of the main queue first: the width change before is over.
            try await Task.sleep(for: .milliseconds(30))
            let measured = ChatTimelinePerf.rowMeasureCount
            host.window.frame = CGRect(origin: .zero, size: size)
            host.window.layoutIfNeeded()
            // UIKit asks the cells for their sizes again in later passes, as a
            // rotation's animation does; those count too.
            try await Task.sleep(for: .milliseconds(150))
            host.window.layoutIfNeeded()
            return ChatTimelinePerf.rowMeasureCount - measured
        }
        // The first round trip may meet rows at a width they never had (more of
        // the chat shows in portrait); the second has a height for every row.
        #expect(try await rotate(to: portrait) > 0, "the first portrait width is new to every row")
        _ = try await rotate(to: Self.landscape)
        #expect(try await rotate(to: portrait) == 0, "the second rotation to portrait measured rows")
        #expect(try await rotate(to: Self.landscape) == 0, "the second rotation back measured rows")
    }

    // MARK: - Helpers

    private func endDrag(
        _ handle: TrailingColumnResizeHandle,
        translation: CGFloat,
        host: Host
    ) async throws -> (rebuilds: Int, measured: Int) {
        // A turn of the main queue first: the width change before is over.
        try await Task.sleep(for: .milliseconds(30))
        let rebuilds = ChatTimelinePerf.layoutRebuildCount
        let measured = ChatTimelinePerf.rowMeasureCount
        handle.onEnded?(translation, 0)
        host.chat.trailingColumn.finishSettleForTesting()
        host.window.layoutIfNeeded()
        return (ChatTimelinePerf.layoutRebuildCount - rebuilds, ChatTimelinePerf.rowMeasureCount - measured)
    }

    private func isAtTail(_ timeline: UICollectionView) -> Bool {
        let maxY = timeline.contentSize.height - timeline.bounds.height + timeline.adjustedContentInset.bottom
        return abs(timeline.contentOffset.y - max(maxY, -timeline.adjustedContentInset.top)) <= 1
    }

    private func firstReadRow(
        _ timeline: UICollectionView,
        controller: ChatTimelineController
    ) -> (id: String, screenY: CGFloat)? {
        let top = timeline.contentOffset.y + timeline.adjustedContentInset.top
        return timeline.indexPathsForVisibleItems
            .compactMap { indexPath -> (String, CGRect)? in
                guard let frame = timeline.layoutAttributesForItem(at: indexPath)?.frame, frame.maxY > top else { return nil }
                return (controller.currentIDs[indexPath.item], frame)
            }
            .min { $0.1.minY < $1.1.minY }
            .map { ($0.0, $0.1.minY - timeline.contentOffset.y) }
    }

    // MARK: - Fixture

    @MainActor
    private struct Host {
        let chat: ChatViewController
        let navigation: UINavigationController
        let timeline: AnchoredCollectionView
        let window: UIWindow
        // Held for the test: the chat and the window trait do not own them.
        let appNavigation: AppNavigation
        let appRoot: AppRootEnvironment

        func hide() {
            hideTestWindow(window)
        }
    }

    /// The chat at regular width in an iPad mini landscape window, 160 rows of
    /// wrapping prose at its tail, with Outline open in the trailing column.
    private func makeHostWithOpenPanel() async throws -> Host {
        let sessionId = "pane-resize-\(UUID().uuidString)"
        let (connection, _) = await makeTestConnection(sessionId: sessionId)
        connection.sessionStore.upsert(makeTestSession(id: sessionId, status: .ready))
        let appNavigation = AppNavigation()
        let appRoot = makeTestAppRoot()
        let chat = ChatViewController(sessionId: sessionId, connection: connection, navigation: appNavigation)
        let navigation = UINavigationController(rootViewController: chat)
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "live resize tests need the test host's window scene"
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: Self.landscape)
        window.traitOverrides.appRootEnvironment = appRoot
        window.traitOverrides.horizontalSizeClass = .regular
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        let host = Host(
            chat: chat,
            navigation: navigation,
            timeline: try #require(timelineFirstView(ofType: AnchoredCollectionView.self, in: chat.view)),
            window: window,
            appNavigation: appNavigation,
            appRoot: appRoot
        )
        let paragraph = "The divider moves and the rows keep the width they had; where it stops they wrap once. "
        let events = (0..<160).map { index in
            traceEvent(
                id: "row-\(index)",
                type: index.isMultiple(of: 4) ? .user : .assistant,
                text: String(repeating: paragraph, count: 1 + index % 4)
            )
        }
        let seeded = await waitForMainActorCondition(timeout: .seconds(5)) {
            // The chat's connect, which has no server here, resets its reducer.
            if !chat.reducer.items.contains(where: { $0.id == "row-0" }) { chat.reducer.loadSession(events) }
            window.layoutIfNeeded()
            return host.timeline.visibleCells.count > 3
        }
        if !seeded { host.hide() }
        try #require(seeded, "the timeline never showed its rows")

        chat.showSidePanel(.outline)
        let opened = await waitForMainActorCondition(timeout: .seconds(3)) {
            chat.trailingColumn.mountedScreenForTesting != nil
        }
        if !opened { host.hide() }
        try #require(opened, "the panel never mounted")
        chat.trailingColumn.finishSettleForTesting()
        window.layoutIfNeeded()
        // Measured at this width, and on the tail.
        window.layoutIfNeeded()
        return host
    }

    private func traceEvent(id: String, type: TraceEventType, text: String) -> TraceEvent {
        TraceEvent(
            id: id, type: type, timestamp: "2026-10-15T18:00:00.000Z", text: text,
            tool: nil, args: nil, output: nil, toolCallId: nil, toolName: nil, isError: nil, thinking: nil
        )
    }
}
