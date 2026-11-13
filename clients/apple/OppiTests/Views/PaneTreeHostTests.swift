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
}
