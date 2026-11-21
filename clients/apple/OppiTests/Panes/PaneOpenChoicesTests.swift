import Foundation
import Testing
@testable import Oppi

/// What a file link's or row's menu offers from its pane (build plan §1.6
/// rule 4): nothing on a compact window, Open in New Pane by the fit rule
/// (§1.3: beside its pane when every pane still fits, full when not), and
/// Open in Pane ▸ listing the window's other panes.
@Suite("Pane open choices")
struct PaneOpenChoicesTests: PaneFixtureBuilding {
    private let files = PaneRoute.files(workspace: "w", path: nil)

    /// The fit rule for a window `width` wide, as the host resolves it.
    private func window(width: CGFloat, liveCap: Int = 4) -> (PaneLayout) -> PanePresentation {
        { layout in
            PanePresentation.resolve(
                layout,
                size: CGSize(width: width, height: 700),
                sidebarWidth: 0,
                topInset: 0,
                bottomInset: 0,
                keyboardHeight: 0,
                firstResponderLeaf: nil,
                minimumSize: { PaneMinimumSize.standard(for: $0.stack.last?.route ?? .sessions(workspace: nil)) ?? PaneMinimumSize.list },
                liveCap: liveCap
            )
        }
    }

    private func choices(
        _ cells: PaneLayout,
        from source: String,
        width: CGFloat,
        isWide: Bool = true,
        canAddPane: Bool = true,
        liveCap: Int = 4
    ) -> PaneOpenChoices? {
        PaneOpenChoices.resolve(
            isWide: isWide,
            canAddPane: canAddPane,
            cells: cells,
            source: id(source),
            title: { "Title \($0.raw)" },
            takesFile: { id in
                guard let entry = cells.leaf(id)?.stack.last else { return true }
                return PaneOpenChoices.takesFile(.entry(entry))
            },
            presentation: window(width: width, liveCap: liveCap)
        )
    }

    @Test func aCompactWindowOffersNoPaneItems() {
        let cells = row(("chat", 0.5), ("b", 0.5))
        #expect(choices(cells, from: "chat", width: 390, isWide: false) == nil)
    }

    @Test func aChatAloneOnTheMiniInPortraitOpensTheFileBesideIt() {
        // 375 + 1 + 360 = 736 of the mini's 744 pt.
        let cells = PaneLayout(single: leaf("chat"))
        let offered = choices(cells, from: "chat", width: 744)
        #expect(offered == PaneOpenChoices(right: .beside, below: .beside, targets: []))
    }

    /// Each edge has its own fit: too narrow for a file to the right, the
    /// window is tall enough for one below.
    @Test func aPaneTooNarrowForBothOpensTheNewOneFull() {
        let cells = PaneLayout(single: leaf("chat"))
        #expect(choices(cells, from: "chat", width: 700)?.right == .full)
        #expect(choices(cells, from: "chat", width: 700)?.below == .beside)
    }

    /// The fit rule weighs the whole window, not the pane's share now: the
    /// chat gives up its slack, so a Files pane at half of a landscape mini
    /// still takes a file beside it; with the sidebar's 320 pt gone it does not.
    @Test func theFitRuleCountsWhatOtherPanesCanGiveUp() {
        let cells = row([(leaf("chat"), 0.5), (leaf("b", files), 0.5)])
        #expect(choices(cells, from: "b", width: 1133)?.right == .beside)
        #expect(choices(cells, from: "b", width: 813)?.right == .full)
    }

    @Test func overTheLivePaneCapTheNewPaneOpensFull() {
        let cells = row([(leaf("chat"), 0.25), (leaf("b", files), 0.25), (leaf("c", files), 0.25), (leaf("d", files), 0.25)])
        #expect(choices(cells, from: "chat", width: 2400, liveCap: 4)?.right == .full)
        #expect(choices(cells, from: "chat", width: 2400, liveCap: 5)?.right == .beside)
    }

    @Test func openInPaneListsEveryOtherPaneInTreeOrder() {
        let cells = PaneLayout(
            root: .split(axis: .row, children: [
                .leaf(leaf("chat")),
                .split(axis: .column, children: [.leaf(leaf("b", files)), .leaf(leaf("c", files))], weights: [0.5, 0.5]),
            ], weights: [0.5, 0.5]),
            focus: id("chat"),
            recency: ids("chat", "b", "c")
        )
        let fromB = choices(cells, from: "b", width: 1133)
        #expect(fromB?.targets == [
            PaneOpenChoices.Target(id: id("chat"), title: "Title chat"),
            PaneOpenChoices.Target(id: id("c"), title: "Title c"),
        ])
        #expect(choices(cells, from: "chat", width: 1133)?.targets.map(\.id) == ids("b", "c"))
    }

    /// A web page, a terminal or Rex is not somewhere a file goes; Files, a
    /// file and the launcher are.
    @Test func openInPaneLeavesOutBrowserAndTerminalPanes() throws {
        let page = PaneRoute.browser(try #require(URL(string: "https://example.com")))
        let terminal = PaneRoute.local(PaneLocalScreen.terminal(workspaceId: "w").token)
        let rex = PaneRoute.local(PaneLocalScreen.rex.token)
        let launcher = PaneRoute.local(PaneLocalScreen.launcher(workspaceId: "w").token)
        let file = PaneRoute.file(.workspace(id: "w", worktree: nil), path: "a.md", line: nil)
        let cells = row([
            (leaf("chat"), 0.2), (leaf("web", page), 0.2), (leaf("term", terminal), 0.15),
            (leaf("rex", rex), 0.15), (leaf("new", launcher), 0.15), (leaf("doc", file), 0.15),
        ])
        #expect(choices(cells, from: "doc", width: 2400)?.targets.map(\.id) == ids("chat", "new"))
        #expect(choices(cells, from: "web", width: 2400)?.targets.map(\.id) == ids("chat", "new", "doc"))
    }

    @Test func aWindowAtItsMostPanesStillOpensInTheOthers() {
        let cells = row(("chat", 0.5), ("b", 0.5))
        let offered = choices(cells, from: "chat", width: 1133, canAddPane: false)
        #expect(offered?.right == nil && offered?.below == nil)
        #expect(offered?.targets.map(\.id) == [id("b")])
    }
}
