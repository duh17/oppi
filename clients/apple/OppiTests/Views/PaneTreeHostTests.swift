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

    /// A3 and the zoom capsule: a zoomed pane fills the window, the others
    /// leave it (and VoiceOver), and its grip offers Restore.
    @Test func zoomFillsTheWindowAndTheCapsuleRestores() throws {
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
        #expect(try grip(host, host.scenePanes.routedLeafID).isHidden)
        #expect(host.panes.focusedLeaf == .split(split), "zoom focuses the pane")

        host.act { _ = capsule.accessibilityActivate() }
        #expect(!host.panes.primary.view.isHidden)
        #expect(leaf.frame.width < 1133)
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
        let items = host.panes.splitItems(for: host.screen)
        #expect(items.map(\.identifier) == ["pane.menu.splitRight", "pane.menu.splitDown"])
        host.act { items[1].run() }
        let split = try #require(host.scenePanes.splitLeaves.first?.id)
        #expect(leafView(host, split)?.frame.minY ?? 0 > 0, "Split Down put the new pane below")
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
}
