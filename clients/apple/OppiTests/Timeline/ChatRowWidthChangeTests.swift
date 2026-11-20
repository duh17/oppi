import Testing
import UIKit
@testable import Oppi

/// A chat whose width changes (a pane opens beside it, then closes) gives
/// every row the height a fresh measurement takes at the new width, in both
/// directions: no row keeps a height from the width before, which left a gap
/// under a table reply after a widening and clipped a wrapped last line after
/// a narrowing.
@MainActor
@Suite("Chat row height across width changes")
struct ChatRowWidthChangeTests {
    private static let landscape = CGSize(width: 1133, height: 744)

    @Test("each row measures fresh after a pane opens beside the chat and after it closes")
    func rowsTakeFreshHeightsAcrossPaneOpenAndClose() async throws {
        let host = try await makeHost()
        defer { hideTestWindow(host.window) }
        let fullWidth = host.timeline.bounds.width
        try await expectFreshRowHeights(host, label: "before the pane opens")

        UIView.performWithoutAnimation {
            host.chat.showPanel(.outline)
            host.chat.updateAttachedLeaf()
        }
        let opened = await waitForMainActorCondition(timeout: .seconds(3)) {
            host.chat.attachedLeaf.mountedScreen != nil
        }
        try #require(opened, "the panel never mounted")
        settlePaneMotion(in: host.window)
        host.window.layoutIfNeeded()
        try #require(host.timeline.bounds.width < fullWidth - 200, "the pane must narrow the chat")
        try await expectFreshRowHeights(host, label: "with the pane open")

        // The divider dragged toward the chat narrows it further, as a pane
        // opened beside a narrower window does.
        let paneWidth = host.timeline.bounds.width
        let divider = try #require(PaneHostController.hosting(host.chat)?.divider)
        divider.onBegan?()
        divider.onChanged?(-250)
        host.window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        UIView.performWithoutAnimation { divider.onEnded?(CGPoint(x: -250, y: 0), .zero) }
        settlePaneMotion(in: host.window)
        host.window.layoutIfNeeded()
        try #require(host.timeline.bounds.width < paneWidth - 150, "the divider must narrow the chat")
        try await expectFreshRowHeights(host, label: "with the divider dragged")

        UIView.performWithoutAnimation {
            host.chat.showPanel(nil)
            host.chat.updateAttachedLeaf()
        }
        let closed = await waitForMainActorCondition(timeout: .seconds(3)) {
            abs(host.timeline.bounds.width - fullWidth) <= 1
        }
        try #require(closed, "the chat never took its width back")
        settlePaneMotion(in: host.window)
        host.window.layoutIfNeeded()
        try await expectFreshRowHeights(host, label: "after the pane closed")
    }

    // MARK: - Helpers

    /// Shows each row in turn (bottom up, the way a reader scrolls back) and
    /// compares the height the layout gives it with a measurement of the same
    /// row's configuration in a new cell at the row's width.
    private func expectFreshRowHeights(_ host: Host, label: String) async throws {
        let ids = host.chat.timeline.currentIDs
        for item in ids.indices.reversed() {
            let indexPath = IndexPath(item: item, section: 0)
            host.timeline.scrollToItem(at: indexPath, at: .top, animated: false)
            host.window.layoutIfNeeded()
            // A turn of the main queue: invalidations a row posts after its
            // layout at the new width land.
            try await Task.sleep(for: .milliseconds(30))
            host.window.layoutIfNeeded()
            let cell = try #require(host.timeline.cellForItem(at: indexPath) as? SafeSizingCell, "\(ids[item]) has no cell")
            let frame = try #require(host.timeline.layoutAttributesForItem(at: indexPath)?.frame)
            let fresh = try freshHeight(of: cell, width: frame.width, in: host.window)
            #expect(
                abs(frame.height - fresh) <= 1,
                "\(label): \(ids[item]) is \(frame.height) pt tall at \(frame.width) pt; a fresh measurement is \(fresh) pt"
            )
            #expect(abs(cell.bounds.height - frame.height) <= 1, "\(label): \(ids[item])'s cell is not at its layout height")
        }
    }

    private func freshHeight(of cell: SafeSizingCell, width: CGFloat, in window: UIWindow) throws -> CGFloat {
        let configuration = try #require(cell.contentConfiguration)
        let fresh = SafeSizingCell(frame: CGRect(x: 0, y: -10_000, width: width, height: 100))
        window.addSubview(fresh)
        defer { fresh.removeFromSuperview() }
        fresh.contentConfiguration = configuration
        // Laid out at the width first: a new row's Markdown has no bounds
        // until then, and measures at a fallback width.
        var height = fresh.frame.height
        for _ in 0..<3 {
            fresh.layoutIfNeeded()
            let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: 0))
            attributes.frame = fresh.frame
            let measured = fresh.preferredLayoutAttributesFitting(attributes).size.height
            if abs(measured - height) <= 0.5 { break }
            height = measured
            fresh.frame.size.height = measured
            fresh.setNeedsLayout()
        }
        return height
    }

    // MARK: - Fixture

    @MainActor
    private struct Host {
        let chat: ChatViewController
        let navigation: UINavigationController
        let timeline: AnchoredCollectionView
        let window: UIWindow
        // Held for the test: the chat and the window trait do not own them.
        let appNavigation: SceneNavigation
        let appRoot: AppRootEnvironment
    }

    /// The chat at regular width in an iPad mini landscape window with a
    /// long wrapping reply and a reply that ends in a Markdown table.
    private func makeHost() async throws -> Host {
        let sessionId = "row-width-\(UUID().uuidString)"
        let (connection, _) = await makeTestConnection(sessionId: sessionId)
        connection.sessionStore.upsert(makeTestSession(id: sessionId, status: .ready))
        let appNavigation = SceneNavigation()
        let appRoot = makeTestAppRoot()
        let chat = ChatViewController(sessionId: sessionId, connection: connection, navigation: appNavigation)
        let navigation = UINavigationController(rootViewController: chat)
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "row width tests need the test host's window scene"
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: Self.landscape)
        window.traitOverrides.appRootEnvironment = appRoot
        window.traitOverrides.horizontalSizeClass = .regular
        window.rootViewController = PaneHostController(primary: navigation)
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
        let events = [
            traceEvent(id: "ask-text", type: .user, text: "Summarize what changed in the pane work."),
            traceEvent(id: "reply-text", type: .assistant, text: Self.longReply),
            traceEvent(id: "ask-table", type: .user, text: "What should I try on the new build?"),
            traceEvent(id: "reply-table", type: .assistant, text: Self.tableReply),
        ]
        let seeded = await waitForMainActorCondition(timeout: .seconds(5)) {
            // The chat's connect, which has no server here, resets its reducer.
            if !chat.reducer.items.contains(where: { $0.id == "reply-table" }) { chat.reducer.loadSession(events) }
            window.layoutIfNeeded()
            return host.timeline.visibleCells.count >= 2
        }
        if !seeded { hideTestWindow(window) }
        try #require(seeded, "the timeline never showed its rows")
        window.layoutIfNeeded()
        return host
    }

    private func traceEvent(id: String, type: TraceEventType, text: String) -> TraceEvent {
        TraceEvent(
            id: id, type: type, timestamp: "2026-11-15T18:00:00.000Z", text: text,
            tool: nil, args: nil, output: nil, toolCallId: nil, toolName: nil, isError: nil, thinking: nil
        )
    }

    private static let longReply = """
    The pane work landed in three parts. Links you tap in a chat now open beside it on a wide window, \
    right of the chat in landscape and below it in portrait, and a pane already showing that kind of \
    thing takes the link first so the chat keeps its room.

    The divider between the chat and a pane holds the chat's rows at their width while it moves and \
    lays them out once where it comes to rest, so dragging stays smooth even with a long reply on screen.

    Godot games run in a pane of their own, and the camera button sends a snapshot of the game's state \
    to the chat, where an agent can read the scene tree and the last errors before it suggests a fix.
    """

    private static let tableReply = """
    Build 58 is on your iPad. Here is what to try:

    | Area | What to try |
    | --- | --- |
    | Games | Open Sword Lab, then Spark Drift: no relaunch. Try the camera button (Snapshot to Chat), and Ask Agent on an error |
    | Links | Tap a file, folder or web link in a chat: it opens beside the chat. Long-press for Right, Below or Here |
    | Panes | Drag a pane to the bottom edge: the highlight now shows the full bottom half |
    | Schedules (iPad) | Month view fills the card, with only the top-right arrows |
    | MCP Servers | Opens instantly |
    | Rex pane | New pane → Rex |
    | Live Activity | Off unless you turn it on under Settings → Experiments |
    """
}
