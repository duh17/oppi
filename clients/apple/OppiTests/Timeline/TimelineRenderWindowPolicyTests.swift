import CoreGraphics
import Testing
import UIKit
@testable import Oppi

@Suite("Timeline render window policy")
struct TimelineRenderWindowPolicyTests {
    @Test func showEarlierControlRemainsVisibleWhenOnlyServerRowsRemain() {
        #expect(TimelineRenderWindowPolicy.showsShowEarlierControl(hiddenCount: 0, hasOlderServerPage: true))
        #expect(!TimelineRenderWindowPolicy.showsShowEarlierControl(hiddenCount: 0, hasOlderServerPage: false))
    }

    @Test func showEarlierRevealsLocalHiddenRowsBeforeFetchingOlderPage() {
        let action = TimelineRenderWindowPolicy.showEarlierAction(
            currentWindow: 80,
            totalItems: 200,
            step: 60,
            hasOlderServerPage: true
        )

        #expect(action == .revealLocal(newWindow: 140))
    }

    @Test func showEarlierFetchesOlderServerPageWhenLocalRowsAreExhausted() {
        let action = TimelineRenderWindowPolicy.showEarlierAction(
            currentWindow: 80,
            totalItems: 80,
            step: 60,
            hasOlderServerPage: true
        )

        #expect(action == .fetchOlderPage)
    }

    @Test func showEarlierDoesNothingWhenNoLocalOrServerRowsRemain() {
        let action = TimelineRenderWindowPolicy.showEarlierAction(
            currentWindow: 80,
            totalItems: 80,
            step: 60,
            hasOlderServerPage: false
        )

        #expect(action == .none)
    }
}

@Suite("Chat timeline chrome overlap")
struct ChatTimelineChromeOverlapTests {
    @Test func topInsetUsesHeaderBottomNotBarHeight() {
        let timeline = CGRect(x: 0, y: 0, width: 390, height: 844)
        let header = CGRect(x: 16, y: 103, width: 358, height: 48)

        #expect(ChatTimelineChromeOverlap.topInset(timelineFrame: timeline, headerFrame: header) == 151)
        #expect(
            ChatTimelineChromeOverlap.topInset(timelineFrame: timeline, headerFrame: header) != header.height,
            "Bar height alone leaves the first rows under the navigation bar"
        )
    }

    @Test func emptyHeaderStillCoversNavigationGap() {
        let timeline = CGRect(x: 0, y: 0, width: 390, height: 844)
        // Empty context bar: zero height, sitting at the safe-area top below
        // the nav bar while the timeline starts at the window top.
        let emptyHeaderAtSafeArea = CGRect(x: 0, y: 103, width: 390, height: 0)

        #expect(
            ChatTimelineChromeOverlap.topInset(
                timelineFrame: timeline,
                headerFrame: emptyHeaderAtSafeArea
            ) == 103
        )
    }

    @Test func unmeasuredFramesDoNotInventInset() {
        #expect(
            ChatTimelineChromeOverlap.topInset(timelineFrame: .zero, headerFrame: .zero) == 0
        )
    }
}

/// Where the chat's timeline lays its rows out, measured on the real chat
/// screen in a navigation controller, the way the app shows it. The chat pins
/// the timeline to its safe-area guide, so the timeline's own width is the one
/// input to the row column.
@MainActor
@Suite("Chat timeline row column")
struct ChatTimelineRowColumnTests {
    private static let window = CGSize(width: 1032, height: 1376)
    private static let margin = ChatTimelineCachedHeightLayout.sectionInsets.leading

    /// Opening a panel grows the navigation controller's trailing safe area and
    /// narrows the chat beside it in one animated layout pass, in which UIKit
    /// lays the timeline out once with its new bounds but its old center, and
    /// with its own `safeAreaInsets` still those of its old full-width frame.
    /// Rows measured from either were laid out in a column that did not exist:
    /// 200 pt wide beside a 400 pt list panel, and none at all beside Share and
    /// the reader at 520 pt, where a height was never kept and UIKit trapped in
    /// a self-sizing loop. Rows lay out at the full width before and at the
    /// narrowed column after, nothing between.
    @Test(
        "a panel opening beside the timeline lays its rows out only at the old or the narrowed column",
        arguments: [ChatPanel.outline, .share]
    )
    func openingAPanelNeverLaysRowsOutInAStaleColumn(panel: ChatPanel) async throws {
        let host = try await makeSeededHost()
        defer { host.hide() }
        let timeline = host.timeline
        let fullColumn = Self.columnWidth(in: timeline.bounds.width)

        var rowWidths: Set<CGFloat> = []
        timeline.didCaptureAnchorForTesting = { [weak timeline] in
            for cell in timeline?.visibleCells ?? [] { rowWidths.insert(cell.bounds.width) }
        }
        defer { timeline.didCaptureAnchorForTesting = nil }
        host.chat.showPanel(panel)
        let opened = await waitForMainActorCondition(timeout: .seconds(3)) {
            host.chat.attachedLeaf.mountedScreen != nil
        }
        try #require(opened, "the panel never mounted")
        settlePaneMotion(in: host.window)
        host.window.layoutIfNeeded()
        for cell in timeline.visibleCells { rowWidths.insert(cell.bounds.width) }

        let narrowedColumn = Self.columnWidth(in: timeline.bounds.width)
        #expect(narrowedColumn < fullColumn, "the timeline must narrow beside the panel")
        #expect(
            rowWidths.isSubset(of: [fullColumn, narrowedColumn]),
            "rows laid out at \(rowWidths.sorted()), expected only \(fullColumn) and \(narrowedColumn)"
        )
        #expect(timeline.visibleCells.count == 5)
        #expect(timeline.visibleCells.allSatisfy { $0.bounds.width == narrowedColumn })
    }

    /// Rows keep the margin on a narrow timeline and stop at the readable width
    /// on a wide one, centred, so a reply on an iPad in landscape keeps a
    /// reading measure.
    private static func columnWidth(in timelineWidth: CGFloat) -> CGFloat {
        min(timelineWidth - 2 * margin, ReadableContentWidth.column)
    }

    /// The column centred in the timeline between `left` and `right` window insets.
    private static func centredColumn(left: CGFloat, right: CGFloat) -> ClosedRange<CGFloat> {
        let available = window.width - left - right
        let width = columnWidth(in: available)
        let minX = left + ((available - width) / 2).rounded(.down)
        return minX...(minX + width)
    }

    /// A wide chat caps its rows at the readable width, centred, and a
    /// vertical rail on one edge (the Duo's control rail) is safe area on that
    /// side only: the column centres in what is left and comes back when it goes.
    @Test("rows centre in a readable column clear of a side rail on either edge")
    func rowsCentreInAReadableColumnClearOfASideRail() async throws {
        let host = try await makeSeededHost()
        defer { host.hide() }
        let rail: CGFloat = 83

        /// The rows' spans, after checking the footer (composer and strip) spans the same
        /// column plus its margins, so the bottom stack lines up with the replies.
        func rowSpans(sourceLocation: SourceLocation = #_sourceLocation) -> Set<ClosedRange<CGFloat>> {
            host.window.layoutIfNeeded()
            let spans = Set(host.timeline.visibleCells.map {
                let frame = $0.convert($0.bounds, to: host.window)
                return frame.minX...frame.maxX
            })
            let footer = host.chat.footerStack.convert(host.chat.footerStack.bounds, to: host.window)
            if let row = spans.first {
                #expect(abs(footer.minX + Self.margin - row.lowerBound) <= 1, "footer \(footer) vs rows \(row)", sourceLocation: sourceLocation)
                #expect(abs(footer.maxX - Self.margin - row.upperBound) <= 1, "footer \(footer) vs rows \(row)", sourceLocation: sourceLocation)
            }
            return spans
        }

        // The window is wide enough that the cap, not the margin, sets the column.
        try #require(Self.window.width - 2 * Self.margin - 2 * rail > ReadableContentWidth.column)
        #expect(rowSpans() == [Self.centredColumn(left: 0, right: 0)])
        #expect(host.timeline.visibleCells.allSatisfy { $0.bounds.width == ReadableContentWidth.column })
        host.navigation.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: rail, bottom: 0, right: 0)
        #expect(rowSpans() == [Self.centredColumn(left: rail, right: 0)])
        host.navigation.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: rail)
        #expect(rowSpans() == [Self.centredColumn(left: 0, right: rail)])
        host.navigation.additionalSafeAreaInsets = .zero
        #expect(rowSpans() == [Self.centredColumn(left: 0, right: 0)])
    }

    // MARK: - Fixture

    private struct Host {
        let chat: ChatViewController
        let navigation: UINavigationController
        let timeline: AnchoredCollectionView
        let window: UIWindow
        // Held for the test: the chat and the window trait do not own them.
        let appNavigation: SceneNavigation
        let appRoot: AppRootEnvironment

        func hide() {
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    /// The chat at regular width on an iPad-sized window, showing a user
    /// message and four short replies.
    private func makeSeededHost() async throws -> Host {
        let sessionId = "timeline-column-\(UUID().uuidString)"
        let (connection, _) = await makeTestConnection(sessionId: sessionId)
        connection.sessionStore.upsert(makeTestSession(id: sessionId, status: .ready))
        let appNavigation = SceneNavigation()
        let appRoot = makeTestAppRoot()
        let chat = ChatViewController(sessionId: sessionId, connection: connection, navigation: appNavigation)
        let navigation = UINavigationController(rootViewController: chat)

        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "timeline column tests need the test host's window scene"
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: Self.window)
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

        let events = [traceEvent(id: "user", type: .user, text: "Review the routes")]
            + (1...4).map { traceEvent(id: "reply-\($0)", type: .assistant, text: "Reply \($0).") }
        let seeded = await waitForMainActorCondition(timeout: .seconds(3)) {
            // The chat's connect, which has no server here, resets its reducer.
            if !chat.reducer.items.contains(where: { $0.id == "user" }) { chat.reducer.loadSession(events) }
            window.layoutIfNeeded()
            return host.timeline.visibleCells.count == 5
        }
        if !seeded { host.hide() }
        try #require(
            seeded,
            "the timeline never showed its five rows: items=\(chat.reducer.items.count) cells=\(host.timeline.visibleCells.count)"
        )
        return host
    }

    private func traceEvent(id: String, type: TraceEventType, text: String) -> TraceEvent {
        TraceEvent(
            id: id,
            type: type,
            timestamp: "2026-10-15T18:00:00.000Z",
            text: text,
            tool: nil,
            args: nil,
            output: nil,
            toolCallId: nil,
            toolName: nil,
            isError: nil,
            thinking: nil
        )
    }
}
