import Testing
import UIKit
@testable import Oppi

/// The pane host drawing a tree of several leaves in a real window: the fit
/// rule's frames and overflow, the grips and their actions, zoom, and the
/// dividers between cells, read as VoiceOver and a UI test read them.
@MainActor
@Suite("Pane tree host", .serialized)
struct PaneTreeHostTests {
    private func grip(_ host: PaneTestHost, _ id: PaneID) throws -> PaneGripView {
        try #require(host.panes.view.subviews.lazy.compactMap { $0 as? PaneGripView }.first { $0.leafID == id })
    }

    private func run(_ action: String, on grip: PaneGripView, in host: PaneTestHost) throws {
        let custom = try #require(grip.accessibilityCustomActions?.first { $0.name == action }, "no \(action) action")
        host.act { _ = custom.actionHandler?(custom) }
    }

    private func leafView(_ host: PaneTestHost, _ id: PaneID) -> UIView? {
        host.panes.view.subviews.first { $0.accessibilityIdentifier == "pane.leaf.\(id.raw)" }
    }

    /// WA2: in mini landscape a split puts the launcher beside the chat, each
    /// with a grip under its bar, and a divider between them.
    @Test func splitRightPutsALauncherBesideTheChatWithGripsAndADivider() throws {
        let host = PaneTestHost(width: 1133, height: 744, inNavigation: true)
        defer { host.hide() }
        let routed = host.scenePanes.routedLeafID
        // ⌘D: the focused pane splits.
        host.act { host.panes.split(axis: .row) }
        let split = try #require(host.scenePanes.splitLeaves.first?.id)
        let leaf = try #require(leafView(host, split))
        #expect(host.screenWidth + 1 + leaf.frame.width == 1133)
        #expect(leaf.frame.minX == host.screenWidth + 1)
        #expect(abs(leaf.frame.width - host.screenWidth) <= 1, "an even split")
        let launcher = try #require((host.panes.children.first { $0.view === leaf } as? UINavigationController)?.topViewController)
        #expect(launcher is PaneLauncherViewController)

        let chatGrip = try grip(host, routed)
        let splitGrip = try grip(host, split)
        #expect(chatGrip.accessibilityLabel?.hasSuffix("1 of 2") == true)
        #expect(splitGrip.accessibilityLabel == "Pane, New Pane, 2 of 2")
        #expect(chatGrip.accessibilityValue == "Focused", "the chat keeps focus")
        #expect(chatGrip.frame.midX == host.screenWidth / 2)
        #expect(splitGrip.frame.midX == leaf.frame.midX)
        // Under the pane's bar, never in it: a drag in the bar moves a floating window.
        let bar = try #require((host.panes.children.first { $0.view === leaf } as? UINavigationController)?.navigationBar)
        #expect(splitGrip.frame.minY >= bar.convert(bar.bounds, to: host.panes.view).maxY)
        #expect(splitGrip.frame.minY > 0)
        // The grip has a strip of its own: the pane's content starts below it.
        let contentTop = launcher.view.convert(launcher.view.safeAreaLayoutGuide.layoutFrame, to: host.panes.view).minY
        #expect(contentTop >= splitGrip.frame.maxY)

        let divider = try #require(host.panes.view.subviews.lazy.compactMap { $0 as? PaneSplitDividerView }.first)
        #expect(divider.accessibilityIdentifier == "pane.divider.1")
        #expect(divider.accessibilityTraits.contains(.adjustable))
        #expect(abs(divider.frame.midX - (host.screenWidth + 0.5)) < 1)
        host.act { divider.accessibilityIncrement() }
        #expect(abs(leaf.frame.minX - (host.screenWidth + 1)) < 0.5)
        #expect(divider.accessibilityValue == "53 percent")
    }

    /// A3 and the zoomed grip: a zoomed pane fills the window, the others
    /// leave it (and VoiceOver), and its grip grows but keeps the whole pane
    /// menu, with Restore first, for touch and VoiceOver alike.
    @Test func zoomFillsTheWindowAndTheGripMenuLeadsWithRestore() throws {
        let host = PaneTestHost(width: 1133, height: 744, inNavigation: true)
        defer { host.hide() }
        host.act { host.panes.split(axis: .row) }
        let split = try #require(host.scenePanes.splitLeaves.first?.id)
        try run("Zoom", on: try grip(host, split), in: host)
        let leaf = try #require(leafView(host, split))
        #expect(leaf.frame == host.panes.view.bounds)
        #expect(host.panes.primary.view.isHidden)
        let capsule = try grip(host, split)
        #expect(capsule.accessibilityValue == "Zoomed")
        #expect(capsule.frame.width > PaneGripView.size.width, "the zoomed grip is the longer pill")
        #expect(try grip(host, host.scenePanes.routedLeafID).isHidden)
        #expect(host.panes.focusedLeaf == .split(split), "zoom focuses the pane")
        let menu = host.panes.menuItems(for: split)
        #expect(menu.first?.identifier == "pane.menu.zoom" && menu.first?.title == "Restore")
        #expect(menu.contains { $0.identifier == "pane.menu.close" && $0.isEnabled }, "Close Pane stays in reach")
        let actions = capsule.accessibilityCustomActions?.map(\.name) ?? []
        #expect(actions.first == "Restore")
        #expect(actions.contains("Close Pane"))
        // A drag does not start on the zoomed grip.
        let pan = try #require(capsule.gestureRecognizers?.first { $0 is UIPanGestureRecognizer })
        #expect(!capsule.gestureRecognizerShouldBegin(pan))

        try run("Restore", on: capsule, in: host)
        #expect(host.scenePanes.zoomedCell == nil)
        #expect(!host.panes.primary.view.isHidden)
        #expect(leaf.frame.width < 1133)
        #expect(capsule.frame.width == PaneGripView.size.width)
        #expect(capsule.gestureRecognizerShouldBegin(pan))
        #expect(host.panes.menuItems(for: split).first { $0.identifier == "pane.menu.zoom" }?.title == "Zoom")
    }

    /// The other ways out of a zoom: Split Panes off shows the chat alone,
    /// unzoomed, and on again the capsule is there to leave by; closing the
    /// zoomed pane gives the chat the window back.
    @Test func splitPanesOffAndCloseNeverLeaveAZoomWithoutAWayOut() throws {
        let host = PaneTestHost(width: 1133, height: 744, inNavigation: true)
        defer { host.hide() }
        let routed = host.scenePanes.routedLeafID
        host.act { host.panes.split(axis: .row) }
        let split = try #require(host.scenePanes.splitLeaves.first?.id)
        host.act { host.panes.zoom(split) }

        host.act {
            host.scenePanes.splitsEnabled = false
            host.panes.updatePropertiesIfNeeded()
        }
        #expect(!host.panes.primary.view.isHidden)
        #expect(host.panes.primary.view.frame == host.panes.view.bounds, "the chat has the window")
        #expect(host.scenePanes.zoomedCell == nil)
        host.act {
            host.scenePanes.splitsEnabled = true
            host.panes.updatePropertiesIfNeeded()
        }
        let capsule = try grip(host, split)
        #expect(!capsule.isHidden && capsule.accessibilityValue == "Zoomed", "back on, the capsule shows")

        host.act { host.panes.closePane(split) }
        #expect(host.scenePanes.zoomedCell == nil)
        #expect(host.panes.primary.view.frame == host.panes.view.bounds)
        #expect(try grip(host, routed).isHidden, "one pane, no grip")
    }

    /// Overflow: a third pane in mini portrait does not fit beside two, so the
    /// least recent goes to overflow, the new one takes focus to be seen, and
    /// the pane menu offers the hidden one back.
    @Test func aPaneThatDoesNotFitGoesToOverflowAndTheMenuBringsItBack() throws {
        let host = PaneTestHost(width: 744, height: 1133, inNavigation: true)
        defer { host.hide() }
        let routed = host.scenePanes.routedLeafID
        host.act { host.panes.split(axis: .row) }
        let first = try #require(host.scenePanes.splitLeaves.first?.id)
        try run("Split Right", on: try grip(host, routed), in: host)
        let second = try #require(host.scenePanes.splitLeaves.map(\.id).first { $0 != first })
        #expect(leafView(host, second)?.isHidden == false, "the new pane shows")
        #expect(leafView(host, first)?.isHidden == true, "the least recent pane went to overflow")
        #expect(!host.panes.primary.view.isHidden)
        #expect(host.panes.focusedLeaf == .split(second))

        let menu = host.panes.menuItems(for: second)
        let hidden = try #require(menu.first { $0.identifier == "pane.menu.hidden" })
        host.act { hidden.children.first?.run() }
        #expect(leafView(host, first)?.isHidden == false)
        #expect(host.panes.focusedLeaf == .split(first))
    }

    /// A file dropped on a pane's edge where no third pane fits: the new
    /// pane takes focus and shows, as Split's does, rather than going
    /// straight to Hidden Panes.
    @Test func aDropThatMakesAPaneThatDoesNotFitFocusesIt() throws {
        let host = PaneTestHost(width: 744, height: 1133, inNavigation: true)
        defer { host.hide() }
        let routed = host.scenePanes.routedLeafID
        host.act { host.panes.split(axis: .row) }
        let file = PaneStackEntry(serverId: "s", route: .file(.host, path: "/tmp/a.md", line: nil))
        host.act { host.panes.split(routed, edge: .left, showing: file) }
        let dropped = try #require(host.scenePanes.splitLeaves.first { host.scenePanes.topEntry(of: $0.id) == file }?.id)
        #expect(leafView(host, dropped)?.isHidden == false, "the dropped pane shows")
        #expect(host.panes.focusedLeaf == .split(dropped))
    }

    /// A divider never takes a cell below its minimum: the chat keeps 375 pt.
    @Test func aDividerStopsAtTheChatsMinimum() throws {
        let host = PaneTestHost(width: 1133, height: 744, inNavigation: true)
        defer { host.hide() }
        host.act { host.panes.split(axis: .row) }
        let divider = try #require(host.panes.view.subviews.lazy.compactMap { $0 as? PaneSplitDividerView }.first)
        for _ in 0..<20 { host.act { divider.accessibilityDecrement() } }
        #expect(host.screenWidth == PaneMinimumSize.chat.width)
    }

    /// The chat's companion stays beside it inside the chat's cell when the
    /// window is split.
    @Test func theChatsPanelStaysInsideTheChatsCell() throws {
        let host = PaneTestHost(width: 1133, height: 744, inNavigation: true)
        defer { host.hide() }
        host.showPanel(minWidth: 320, idealWidth: 360, maxWidth: 640)
        host.act { host.panes.split(axis: .column) }
        let split = try #require(host.scenePanes.splitLeaves.first?.id)
        let leaf = try #require(leafView(host, split))
        let companion = try #require(host.companion?.view)
        #expect(leaf.frame.minY > 0 && leaf.frame.width == 1133, "Split Down puts the pane below")
        #expect(companion.frame.maxY <= leaf.frame.minY)
        #expect(companion.frame.maxX == 1133)
        #expect(host.screenWidth + 1 + companion.frame.width >= 1133 - 1)
    }

    /// The touch path with one pane: the screen's own menu offers Split Right
    /// and Split Down, since no grip shows yet.
    @Test func withOnePaneTheScreensMenuOffersTheSplits() throws {
        let host = PaneTestHost(width: 1133, height: 744, inNavigation: true)
        defer { host.hide() }
        let items = host.panes.screenMenuItems(for: host.screen)
        #expect(items.map(\.identifier) == ["pane.menu.splitRight", "pane.menu.splitDown"])
        host.act { items[1].run() }
        let split = try #require(host.scenePanes.splitLeaves.first?.id)
        #expect(leafView(host, split)?.frame.minY ?? 0 > 0, "Split Down put the new pane below")
    }

    /// The Split Panes experiment turned off with a pane open: the window is
    /// the chat and its panel again, at the panel's width, with no grip, and
    /// offers no split, item menu, web page beside, drop zone or Undo. Turned
    /// back on, the pane returns with its grip and its Undo.
    @Test func splitPanesOffLeavesTheChatAndItsPanelAndOnBringsThePaneBack() throws {
        let host = PaneTestHost(width: 1133, height: 744, inNavigation: true)
        defer { host.hide() }
        let routed = host.scenePanes.routedLeafID
        host.showPanel(minWidth: 320, idealWidth: 360, maxWidth: 640)
        host.act { host.panes.split(axis: .column) }
        let kept = try #require(host.scenePanes.splitLeaves.first?.id)
        // Open in Pane, for an Undo.
        let files = PaneStackEntry(serverId: "s", route: .files(workspace: "ws", path: nil))
        host.act {
            host.scenePanes.open(files, inCell: kept)
            host.panes.updatePropertiesIfNeeded()
        }
        #expect(host.scenePanes.undoAction == ScenePanes.openInPaneAction)
        let companion = try #require(host.companion?.view)
        let splitHeight = companion.frame.height

        host.act {
            host.scenePanes.splitsEnabled = false
            host.panes.updatePropertiesIfNeeded()
        }
        #expect(leafView(host, kept) == nil, "the split pane leaves the window")
        #expect(try grip(host, routed).isHidden)
        #expect(host.screen.additionalSafeAreaInsets.top == 0, "no grip strip")
        #expect(companion.frame.maxX == 1133, "the panel stays beside the chat")
        #expect(abs(host.screenWidth + 1 + companion.frame.width - 1133) <= 1, "the two share the window")
        #expect(companion.frame.height > splitHeight, "the chat's cell is the whole window again")
        #expect(host.panes.screenMenuItems(for: host.screen).isEmpty, "no Split Right or Down")
        #expect(host.panes.openChoices(from: routed) == nil, "no Open in New Pane or Open in Pane")
        #expect(!host.panes.openBrowser(try #require(URL(string: "https://example.com"))), "web links keep Safari's sheet")
        let chat = try #require(host.panes.cellFrame(routed))
        let file = PaneDragPayload.Content.entry(PaneStackEntry(serverId: "s", route: .file(.host, path: "/tmp/a", line: nil)))
        #expect(host.panes.dropTarget(at: CGPoint(x: chat.minX + 10, y: chat.midY), payload: file) == nil, "no drop zone splits")
        #expect(host.scenePanes.undoAction == nil)
        host.act { host.panes.split(axis: .column) }
        #expect(host.scenePanes.tree.leaves.count == 3, "⌘D does nothing")
        #expect(host.scenePanes.topEntry(of: kept) == files, "the tree keeps the pane")

        host.act {
            host.scenePanes.splitsEnabled = true
            host.panes.updatePropertiesIfNeeded()
        }
        let leaf = try #require(leafView(host, kept), "the pane is back")
        #expect(leaf.frame.maxY == 744, "below the chat, where it was")
        #expect(!(try grip(host, kept)).isHidden)
        #expect(host.scenePanes.undoAction == ScenePanes.openInPaneAction)
    }

    /// A screen that brings its own controls, as the terminal and a file
    /// reader do: its stack hides the bar.
    private final class BarlessScreen: UIViewController, NavigationBarHiding {
        var hidesNavigationBar: Bool { true }
    }

    /// A pane below another has its grip right under the divider, clear of
    /// the divider's grabber, with its strip above the content: only a pane
    /// at the window's top keeps clear of the status bar.
    @Test func aLowerPanesGripSitsRightUnderTheDivider() throws {
        let host = PaneTestHost(width: 744, height: 1133, inNavigation: true)
        defer { host.hide() }
        try #require(host.panes.view.safeAreaInsets.top > 0, "the window has a status bar")
        host.act { host.panes.split(axis: .column) }
        let split = try #require(host.scenePanes.splitLeaves.first?.id)
        let leaf = try #require(leafView(host, split))
        #expect(leaf.frame.minY > host.panes.view.safeAreaInsets.top, "the new pane sits below the chat")
        let navigation = try #require(host.panes.children.first { $0.view === leaf } as? UINavigationController)
        let screen = BarlessScreen()
        host.act { navigation.pushViewController(screen, animated: false) }
        #expect(navigation.isNavigationBarHidden)

        let grip = try grip(host, split)
        let divider = try #require(host.panes.view.subviews.lazy.compactMap { $0 as? PaneSplitDividerView }.first)
        let grabberBottom = divider.frame.midY + PaneSplitDividerView.grabberThickness / 2
        #expect(grip.frame.minY > grabberBottom, "apart from the divider's grabber: \(grip.frame), divider \(divider.frame)")
        #expect(grip.frame.minY - leaf.frame.minY <= 8, "right under the divider: \(grip.frame), pane \(leaf.frame)")
        let contentTop = screen.view.convert(screen.view.safeAreaLayoutGuide.layoutFrame, to: host.panes.view).minY
        #expect(contentTop == leaf.frame.minY + PaneStripSlot.height, "no status-bar inset in a lower pane")
    }

    /// A held grip over another pane: its edge moves the pane there, its
    /// middle swaps them, and the pane's own cell takes nothing.
    @Test func aLiftedGripMovesToAnEdgeOrSwapsInTheMiddle() throws {
        let host = PaneTestHost(width: 1133, height: 744, inNavigation: true)
        defer { host.hide() }
        host.act { host.panes.split(axis: .row) }
        let routed = host.scenePanes.routedLeafID
        let split = try #require(host.scenePanes.splitLeaves.first?.id)
        let chat = try #require(host.panes.cellFrame(routed))
        let lifted = PaneDragPayload.Content.pane(split)
        #expect(host.panes.dropTarget(at: CGPoint(x: chat.minX + 10, y: chat.midY), payload: lifted)?.target == .move(routed, .left))
        #expect(host.panes.dropTarget(at: CGPoint(x: chat.midX, y: chat.midY), payload: lifted)?.target == .swap(routed))
        let own = try #require(host.panes.cellFrame(split))
        #expect(host.panes.dropTarget(at: CGPoint(x: own.midX, y: own.midY), payload: lifted) == nil)

        host.act { host.panes.swap(split, with: routed) }
        #expect(try #require(leafView(host, split)).frame.minX == 0, "the panes traded places")
    }

    /// A point in `cell`'s zone at `edge`, or its middle.
    private static func point(in cell: CGRect, at edge: PaneEdge?) -> CGPoint {
        switch edge {
        case .left: CGPoint(x: cell.minX + 10, y: cell.midY)
        case .right: CGPoint(x: cell.maxX - 10, y: cell.midY)
        case .top: CGPoint(x: cell.midX, y: cell.minY + 10)
        case .bottom: CGPoint(x: cell.midX, y: cell.maxY - 10)
        case nil: CGPoint(x: cell.midX, y: cell.midY)
        }
    }

    private static func twoPanes(landscape: Bool) -> PaneTestHost {
        let host = landscape
            ? PaneTestHost(width: 1133, height: 744, inNavigation: true)
            : PaneTestHost(width: 744, height: 1133, inNavigation: true)
        host.act { host.panes.split(axis: landscape ? .row : .column) }
        return host
    }

    /// A lifted grip's lit zone is the frame its pane lands in, for every
    /// zone of its neighbour, in both iPad mini orientations. A pane moved to
    /// its neighbour's edge leaves its own place first, so beside a pane it
    /// takes half the window there, not half the neighbour.
    @Test(arguments: [true, false], [PaneEdge.left, .right, .top, .bottom, nil])
    func aLiftedPanesPreviewIsTheFrameItLandsIn(landscape: Bool, edge: PaneEdge?) throws {
        let host = Self.twoPanes(landscape: landscape)
        defer { host.hide() }
        let routed = host.scenePanes.routedLeafID
        let lifted = try #require(host.scenePanes.splitLeaves.first?.id)
        let cell = try #require(host.panes.cellFrame(routed))
        let drop = try #require(host.panes.dropTarget(at: Self.point(in: cell, at: edge), payload: .pane(lifted)))
        host.act {
            switch drop.target {
            case .move(let id, let edge): host.panes.move(lifted, to: id, edge: edge)
            case .swap(let id): host.panes.swap(lifted, with: id)
            default: Issue.record("a lifted pane only moves or swaps: \(drop.target)")
            }
        }
        let landed = try #require(host.panes.cellFrame(lifted), "the moved pane is in sight")
        #expect(drop.zone == landed, "preview \(String(describing: drop.zone)), landed \(landed)")
        #expect(leafView(host, lifted)?.frame == landed)
    }

    /// A dragged entry's lit zone is the frame its pane gets: a new pane at
    /// the edge it was dropped on, or the pane it replaces in the middle.
    @Test(arguments: [true, false], [PaneEdge.left, .right, .top, .bottom, nil])
    func aDroppedEntrysPreviewIsTheFrameItsPaneGets(landscape: Bool, edge: PaneEdge?) throws {
        let host = Self.twoPanes(landscape: landscape)
        defer { host.hide() }
        let pane = try #require(host.scenePanes.splitLeaves.first?.id)
        let cell = try #require(host.panes.cellFrame(pane))
        let file = PaneStackEntry(serverId: "s", route: .file(.host, path: "/tmp/a", line: nil))
        let drop = try #require(host.panes.dropTarget(at: Self.point(in: cell, at: edge), payload: .entry(file)))
        var filled: PaneID?
        host.act {
            switch drop.target {
            case .split(let id, let edge):
                host.panes.split(id, edge: edge, showing: file)
                filled = host.scenePanes.splitLeaves.first { $0.id != pane }?.id
            case .open(let id):
                host.scenePanes.show(file, in: id)
                host.panes.focus(cell: id)
                filled = id
            default: Issue.record("an entry over a pane splits or opens: \(drop.target)")
            }
        }
        let landed = try #require(filled.flatMap(host.panes.cellFrame), "the filled pane is in sight")
        #expect(drop.zone == landed, "preview \(String(describing: drop.zone)), landed \(landed)")
    }

    /// Close Pane removes the split leaf and its grip; one pane left has none.
    @Test func closePaneLeavesOnePaneWithNoGrip() throws {
        let host = PaneTestHost(width: 1133, height: 744, inNavigation: true)
        defer { host.hide() }
        host.act { host.panes.split(axis: .row) }
        let split = try #require(host.scenePanes.splitLeaves.first?.id)
        try run("Close Pane", on: try grip(host, split), in: host)
        #expect(host.scenePanes.splitLeaves.isEmpty)
        #expect(leafView(host, split) == nil)
        #expect(host.screenWidth == 1133)
        #expect(try grip(host, host.scenePanes.routedLeafID).isHidden)
        #expect(host.screen.additionalSafeAreaInsets.top == 0, "one pane gives its strip back")
    }

    private func strip(_ host: PaneTestHost, _ id: PaneID) -> PaneStripView? {
        host.panes.view.subviews.lazy.compactMap { $0 as? PaneStripView }
            .first { $0.accessibilityIdentifier == "pane.strip.\(id.raw)" }
    }

    /// R2: a divider dragged past half the pane's minimum collapses it to a
    /// 20 pt strip on release, the chat takes the room, and no divider is left
    /// to drag; activating the strip brings the pane back focused at its share.
    @Test func aDividerDraggedPastAPaneCollapsesItAndItsStripExpandsIt() throws {
        let host = PaneTestHost(width: 1133, height: 744, inNavigation: true)
        defer { host.hide() }
        host.act { host.panes.split(axis: .row) }
        let split = try #require(host.scenePanes.splitLeaves.first?.id)
        let divider = try #require(host.panes.view.subviews.lazy.compactMap { $0 as? PaneSplitDividerView }.first)
        let shareBefore = host.screenWidth
        // Short of half the launcher's minimum: held at its minimum, no collapse.
        divider.onBegan?()
        divider.onChanged?(400)
        host.act { divider.onEnded?() }
        #expect(strip(host, split) == nil)
        #expect(leafView(host, split)?.frame.width == PaneMinimumSize.list.width)

        divider.onBegan?()
        divider.onChanged?(300)
        host.act { divider.onEnded?() }
        let collapsed = try #require(strip(host, split), "past half its minimum the release collapsed it")
        #expect(collapsed.frame == CGRect(x: 1133 - 20, y: 0, width: 20, height: 744))
        #expect(abs(host.screenWidth - (1133 - 21)) < 0.5, "the chat takes the room")
        #expect(leafView(host, split)?.isHidden == true)
        #expect(try grip(host, split).isHidden, "a strip has no grip")
        #expect(!host.panes.view.subviews.contains { $0 is PaneSplitDividerView && !$0.isHidden },
                "no divider to drag beside a strip")
        #expect(collapsed.accessibilityLabel == "Collapsed pane, New Pane")
        // Drawn 20 pt thin, it takes touches 44 pt across.
        #expect(host.panes.view.hitTest(CGPoint(x: 1133 - 20 - 11, y: 372), with: nil) === collapsed)
        #expect(host.panes.view.hitTest(CGPoint(x: 1133 - 20 - 13, y: 372), with: nil) !== collapsed)

        host.act { _ = collapsed.accessibilityActivate() }
        #expect(strip(host, split) == nil)
        #expect(leafView(host, split)?.isHidden == false)
        #expect(host.panes.focusedLeaf == .split(split), "the expanded pane takes focus")
        #expect(abs(host.screenWidth - (1133 - 1 - PaneMinimumSize.list.width)) <= 1,
                "at the share it had when it collapsed (\(shareBefore) before the drags)")
    }

    /// The pane menu's Collapse does the same, and is off for the window's
    /// only open pane.
    @Test func thePaneMenuCollapsesAPane() throws {
        let host = PaneTestHost(width: 1133, height: 744, inNavigation: true)
        defer { host.hide() }
        let routed = host.scenePanes.routedLeafID
        host.act { host.panes.split(axis: .row) }
        let split = try #require(host.scenePanes.splitLeaves.first?.id)
        try run("Collapse", on: try grip(host, routed), in: host)
        #expect(strip(host, routed)?.frame.width == 20, "the chat's cell collapsed to its strip")
        #expect(host.panes.primary.view.isHidden)
        #expect(host.panes.focusedLeaf == .split(split), "focus moved to the open pane")
        #expect(host.panes.menuItems(for: split).first { $0.identifier == "pane.menu.collapse" }?.isEnabled == false,
                "the last open pane cannot collapse")
    }

    /// §1.5: a compact window shows one pane, the focused one, and the chip
    /// in place of the grips names it and its place; stepping shows the next
    /// pane in tree order, and the list shows any of them.
    @Test func aCompactWindowShowsOnePaneAndTheChip() throws {
        let host = PaneTestHost(width: 1133, height: 744, inNavigation: true)
        defer { host.hide() }
        let routed = host.scenePanes.routedLeafID
        host.act { host.panes.split(axis: .row) }
        let split = try #require(host.scenePanes.splitLeaves.first?.id)
        host.window.traitOverrides.horizontalSizeClass = .compact
        host.resize(width: 390)
        host.act {}
        let chip = try #require(host.panes.view.subviews.lazy.compactMap { $0 as? PaneChipView }.first)
        #expect(!chip.isHidden)
        #expect(chip.accessibilityLabel?.hasSuffix("1 of 2") == true)
        #expect(host.screenWidth == 390, "the focused pane fills the window")
        #expect(leafView(host, split)?.isHidden == true)
        #expect(try grip(host, routed).isHidden && grip(host, split).isHidden, "no grips on a compact window")
        #expect(host.scenePanes.tree.leaves.count == 2, "the tree is unchanged")

        host.act { chip.onStep(1) }
        #expect(leafView(host, split)?.frame.width == 390)
        #expect(host.panes.primary.view.isHidden)
        #expect(chip.accessibilityLabel == "Panes, New Pane, 2 of 2")
        host.act { chip.onStep(1) }
        #expect(host.panes.focusedLeaf == .primary, "stepping wraps around")

        let list = host.panes.paneListItems()
        #expect(list.map(\.identifier) == ["pane.list.\(routed.raw)", "pane.list.\(split.raw)"])
        #expect(list.map(\.isChecked) == [true, false])
        host.act { list[1].run() }
        #expect(host.panes.focusedLeaf == .split(split))

        host.window.traitOverrides.horizontalSizeClass = .regular
        host.resize(width: 1133)
        host.act {}
        #expect(chip.isHidden)
        #expect(leafView(host, split)?.isHidden == false && !host.panes.primary.view.isHidden,
                "widened, both panes show again")
    }

    /// The companion fills the window and gives its leaf its room back on
    /// request (⇧⌘L for the File Browser's list); a companion with no room
    /// beside its leaf has nothing to toggle.
    @Test func theCompanionFillsTheWindowAndGivesTheRoomBack() throws {
        let host = PaneTestHost(width: 1133, height: 744)
        defer { host.hide() }
        host.showPanel(minWidth: 390, idealWidth: 520, maxWidth: 820)
        #expect(host.screen.leaf.fillsWindow == false)
        let beside = try #require(host.companionWidth)
        host.act { host.screen.leaf.setFillsWindow(true) }
        #expect(host.companionWidth == 1133 - PaneWidthPolicy.fullWindowGrabEdge)
        #expect(host.screen.leaf.fillsWindow == true)
        #expect(host.divider.accessibilityCustomActions?.map(\.name) == ["Show Both Panes"])
        host.act { host.screen.leaf.setFillsWindow(false) }
        #expect(host.companionWidth == beside)

        host.resize(width: 744)
        host.act {}
        #expect(host.screen.leaf.fillsWindow == nil, "no room beside: full by the fit rule, only Close ends it")
    }

    /// The pane chords' operations: focus moves by direction and by number,
    /// a pane moves beside its neighbour, and the divider on the focused
    /// pane's edge steps 32 pt toward the arrow; none of them has a target on
    /// a compact window.
    @Test func paneChordsFocusMoveAndStepTheDivider() throws {
        let host = PaneTestHost(width: 1133, height: 744, inNavigation: true)
        defer { host.hide() }
        let routed = host.scenePanes.routedLeafID
        host.act { host.panes.split(axis: .row) }
        let split = try #require(host.scenePanes.splitLeaves.first?.id)

        host.act { host.panes.focusPane(toward: .right) }
        #expect(host.panes.focusedLeaf == .split(split))
        #expect(!host.panes.canMoveDivider(toward: .up), "no column split to move")
        host.act { host.panes.focusPane(number: 1) }
        #expect(host.panes.focusedLeaf == .primary)

        let before = host.screenWidth
        host.act { host.panes.moveDivider(toward: .right) }
        #expect(host.screenWidth == before + PaneDividerView.accessibilityStep, "the chat's trailing divider moved right")
        host.act { host.panes.focusPane(toward: .right) }
        host.act { host.panes.moveDivider(toward: .left) }
        #expect(host.screenWidth == before, "the launcher's leading divider moved back left")

        #expect(host.panes.canMove(split, toward: .left))
        host.act { host.panes.move(split, toward: .left) }
        #expect(try #require(leafView(host, split)).frame.minX == 0, "the pane moved to the chat's left")
        #expect(host.panes.cellFrame(routed)?.minX ?? 0 > 0)

        host.window.traitOverrides.horizontalSizeClass = .compact
        host.resize(width: 390)
        host.act {}
        #expect(!host.panes.canMove(split, toward: .right))
        #expect(!host.panes.canMoveDivider(toward: .left))
    }

    /// With the chat's companion beside it and no split, ⌃⌘ left and right
    /// step the companion's divider.
    @Test func dividerChordsStepTheCompanion() throws {
        let host = PaneTestHost(width: 1133, height: 744)
        defer { host.hide() }
        host.showPanel(minWidth: 390, idealWidth: 520, maxWidth: 820)
        let width = try #require(host.companionWidth)
        #expect(host.panes.canMoveDivider(toward: .left))
        #expect(!host.panes.canMoveDivider(toward: .down))
        host.act { host.panes.moveDivider(toward: .left) }
        #expect(host.companionWidth == width + PaneDividerView.accessibilityStep, "the divider moved toward the chat")
    }

    /// A4: the "Panes" rotor steps through the panes' grips in tree order,
    /// a collapsed pane by its strip, and each pane is its own focus group
    /// for Tab and Full Keyboard Access.
    @Test func thePanesRotorStepsThroughThePanesInTreeOrder() throws {
        let host = PaneTestHost(width: 1133, height: 744, inNavigation: true)
        defer { host.hide() }
        let rotor = try #require(host.panes.view.accessibilityCustomRotors?.first { $0.name == "Panes" })
        func step(from current: UIView?, _ direction: UIAccessibilityCustomRotor.Direction) -> UIView? {
            let predicate = UIAccessibilityCustomRotorSearchPredicate()
            predicate.currentItem = UIAccessibilityCustomRotorItemResult(targetElement: current ?? NSObject(), targetRange: nil)
            predicate.searchDirection = direction
            return rotor.itemSearchBlock(predicate)?.targetElement as? UIView
        }
        #expect(step(from: nil, .next) == nil, "one pane: nothing to step to")

        let routed = host.scenePanes.routedLeafID
        host.act { host.panes.split(axis: .row) }
        let split = try #require(host.scenePanes.splitLeaves.first?.id)
        let first = try #require(step(from: nil, .next))
        #expect(first === (try grip(host, routed)))
        let second = try #require(step(from: first, .next))
        #expect(second === (try grip(host, split)))
        #expect(step(from: second, .next) == nil)
        #expect(step(from: second, .previous) === first)

        host.act { host.panes.collapse(split) }
        #expect(step(from: first, .next)?.accessibilityIdentifier == "pane.strip.\(split.raw)")

        #expect(host.panes.primary.view.focusGroupIdentifier == "pane.\(routed.raw)")
        #expect(leafView(host, split)?.focusGroupIdentifier == "pane.\(split.raw)")
    }

    /// §1.7: Close Pane, Move Pane and Reset Panes can be undone. The toast
    /// offers it at once and the grip menu after; Undo brings the panes
    /// back with the same ids and content, newest step first, five deep.
    @Test func undoTakesBackCloseMoveAndReset() throws {
        let host = PaneTestHost(width: 1133, height: 744, inNavigation: true)
        defer { host.hide() }
        let routed = host.scenePanes.routedLeafID
        #expect(!host.scenePanes.undo(), "nothing to undo yet")
        host.act { host.panes.split(axis: .row) }
        let first = try #require(host.scenePanes.splitLeaves.first?.id)
        host.act { host.panes.split(first, axis: .column) }
        let second = try #require(host.scenePanes.splitLeaves.map(\.id).first { $0 != first })
        let split = host.scenePanes.tree

        host.act { host.panes.closePane(second) }
        #expect(host.scenePanes.undoAction == "Close Pane")
        let toast = try #require(host.panes.view.subviews.lazy.compactMap { $0 as? PaneUndoToast }.first)
        #expect(!toast.isHidden && toast.configuration?.title == "Undo Close Pane")
        #expect(host.panes.menuItems(for: routed).first?.identifier == "pane.menu.undo")
        host.act { toast.sendActions(for: .primaryActionTriggered) }
        #expect(host.scenePanes.tree == split, "Undo brought the closed pane back where it was")
        #expect(leafView(host, second)?.isHidden == false)
        #expect(toast.isHidden)
        #expect(host.scenePanes.undoAction == nil)

        host.act { host.panes.move(first, toward: .left) }
        #expect(host.scenePanes.undoAction == "Move Pane")
        host.act { host.panes.resetPanes() }
        #expect(host.scenePanes.splitLeaves.isEmpty)
        #expect(host.panes.screenMenuItems(for: host.screen).first?.identifier == "pane.menu.undo",
                "one pane: the screen's own menu offers Undo")
        host.act { host.panes.undoPanes() }
        #expect(Set(host.scenePanes.splitLeaves.map(\.id)) == [first, second], "Reset taken back")
        host.act { host.panes.undoPanes() }
        #expect(host.scenePanes.tree == split, "then the move")

        for _ in 0..<(ScenePanes.undoDepth + 2) { host.act { host.panes.swap(first, with: second) } }
        #expect(host.scenePanes.undoSteps.count == ScenePanes.undoDepth)
    }

    /// A tapped file link opens beside the chat, to its right in landscape
    /// and below it in portrait, focused; a second file link replaces what
    /// that pane shows. A terminal in that pane is never replaced: the next
    /// link gets a pane of its own. With Split Panes off, the link is the
    /// main pane's again.
    @Test(arguments: [(CGSize(width: 1133, height: 744), PaneAxis.row), (CGSize(width: 744, height: 1133), .column)])
    func aTappedFileLinkOpensBesideTheChatAndTheNextReusesItsPane(size: CGSize, axis: PaneAxis) async throws {
        let host = PaneTestHost(width: size.width, height: size.height, inNavigation: true)
        defer { host.hide() }
        try await newPanes(host)
        let routed = host.scenePanes.routedLeafID
        let file = { (path: String) in
            PaneOpenContent(entry: PaneStackEntry(serverId: "s", route: .file(.host, path: path, line: nil)))
        }

        var opened = false
        host.act { opened = host.panes.openBeside(file("/tmp/a.md"), kind: .file) }
        #expect(opened)
        let pane = try #require(host.scenePanes.splitLeaves.first?.id)
        guard case .split(let splitAxis, let children, _) = host.scenePanes.cellLayout.root else {
            Issue.record("no split: \(host.scenePanes.cellLayout.root)")
            return
        }
        #expect(splitAxis == axis)
        #expect(children.map(\.leaves.first?.id) == [routed, pane], "after the chat")
        #expect(host.scenePanes.cellLayout.focus == pane, "the file's pane has focus")
        let frame = try #require(leafView(host, pane)).frame
        #expect(axis == .row ? frame.minX > 0 : frame.minY > 0)

        host.act {
            host.panes.focus(cell: routed)
            _ = host.panes.openBeside(file("/tmp/b.md"), kind: .file)
        }
        #expect(host.scenePanes.splitLeaves.map(\.id) == [pane], "no second pane")
        #expect(host.scenePanes.topEntry(of: pane).route == .file(.host, path: "/tmp/b.md", line: nil))

        let terminal = PaneStackEntry(serverId: "s", route: .local(PaneLocalScreen.terminal(workspaceId: "w").token))
        host.act {
            host.scenePanes.show(terminal, in: pane)
            host.panes.focus(cell: routed)
            _ = host.panes.openBeside(file("/tmp/c.md"), kind: .file)
        }
        #expect(host.scenePanes.topEntry(of: pane) == terminal, "the terminal keeps its pane")
        #expect(host.scenePanes.splitLeaves.count == 2, "the file got a pane of its own")

        host.act {
            host.scenePanes.splitsEnabled = false
            host.panes.updatePropertiesIfNeeded()
        }
        #expect(!host.panes.openBeside(file("/tmp/d.md"), kind: .file), "Split Panes off: the main pane opens it")
    }

    /// New Panes settings of the test's own, so a saved side on the
    /// simulator never reaches it; `sides` are saved through the settings
    /// store, as the settings rows save them.
    private func newPanes(
        _ host: PaneTestHost,
        _ sides: [AppPreferenceStore.NewPanes.Kind: AppPreferenceStore.NewPanes.Side] = [:]
    ) async throws {
        let defaults = try #require(UserDefaults(suiteName: "PaneTreeHostTests-\(UUID().uuidString)"))
        host.scenePanes.preferences = defaults
        let store = SettingsStore(serverId: nil, device: DeviceAdapter(defaults: defaults), server: ServerAdapter { _ in nil })
        for (kind, side) in sides {
            #expect(await store.set(SettingsCatalog.newPaneSide(kind), side).value.current == side)
        }
    }

    /// The split the routed leaf and one new pane make: its axis and the new pane.
    private func splitBesideChat(_ host: PaneTestHost) throws -> (axis: PaneAxis, pane: PaneID) {
        let pane = try #require(host.scenePanes.splitLeaves.first?.id)
        guard case .split(let axis, let children, _) = host.scenePanes.cellLayout.root else {
            Issue.record("no split: \(host.scenePanes.cellLayout.root)")
            return (.row, pane)
        }
        #expect(children.map(\.leaves.first?.id) == [host.scenePanes.routedLeafID, pane], "after the chat")
        return (axis, pane)
    }

    /// The chat bar's Terminal: the folder terminal opens in a pane below the
    /// chat in landscape and in portrait, focused and showing the terminal's
    /// screen, so the shell gets the window's width. Set to Right in New
    /// Panes, it opens to the chat's right instead.
    @Test(arguments: [CGSize(width: 1133, height: 744), CGSize(width: 744, height: 1133)])
    func theChatBarsTerminalOpensBelowTheChatAndFollowsNewPanes(size: CGSize) async throws {
        let entry = PaneStackEntry(serverId: "s", route: .local(PaneLocalScreen.terminal(workspaceId: "w").token))
        func openTerminal(right: Bool) async throws -> (axis: PaneAxis, frame: CGRect) {
            let host = PaneTestHost(width: size.width, height: size.height, inNavigation: true)
            defer { host.hide() }
            try await newPanes(host, right ? [.terminal: .right] : [:])
            let screen = UIViewController()
            var opened = false
            host.act {
                opened = host.panes.openBeside(
                    PaneOpenContent(entry: entry), kind: .terminal, from: host.scenePanes.routedLeafID, screen: screen
                )
            }
            #expect(opened)
            let (axis, pane) = try splitBesideChat(host)
            #expect(host.scenePanes.cellLayout.focus == pane, "the terminal's pane has focus")
            #expect(host.scenePanes.topEntry(of: pane) == entry)
            #expect(screen.view.window != nil && host.panes.cell(holding: screen) == pane, "the pane shows the terminal's screen")
            return (axis, try #require(leafView(host, pane)).frame)
        }

        let below = try await openTerminal(right: false)
        #expect(below.axis == .column)
        #expect(below.frame.minY > 0 && below.frame.minX == 0 && below.frame.width == size.width, "below, the window's width")
        let right = try await openTerminal(right: true)
        #expect(right.axis == .row)
        #expect(right.frame.minX > 0 && right.frame.minY == 0, "to the chat's right")
    }

    /// Open in New Pane to the Right is the person's choice: it opens there
    /// even with New Panes set to put files below, where a tap puts them.
    @Test func openInNewPaneToTheRightWinsOverNewPanes() async throws {
        let host = PaneTestHost(width: 1133, height: 744, inNavigation: true)
        defer { host.hide() }
        // The menu's open needs the app root. A window's trait override reaches
        // the host only on a later trait pass, which the await below may or may
        // not give it in a busy test process: give it to the host directly.
        host.panes.traitOverrides.appRootEnvironment = host.root
        host.panes.updateTraitsIfNeeded()
        try #require(AppRootEnvironment.near(host.panes) != nil, "the host sees the app root")
        try await newPanes(host, [.files: .below])
        let file = PaneOpenContent(entry: PaneStackEntry(serverId: "s", route: .file(.host, path: "/tmp/a.md", line: nil)))
        host.act { host.panes.open(file, .newPane(.right), from: host.scenePanes.routedLeafID) }
        #expect(try splitBesideChat(host).axis == .row)
        host.act { host.panes.undoPanes() }
        #expect(host.scenePanes.splitLeaves.isEmpty)
        host.act { _ = host.panes.openBeside(file, kind: .file) }
        #expect(try splitBesideChat(host).axis == .column, "a tap follows the setting")
    }
}
