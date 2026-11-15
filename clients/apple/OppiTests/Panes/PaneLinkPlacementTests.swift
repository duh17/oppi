import Foundation
import Testing
@testable import Oppi

/// Where a tapped link's file, folder or web page lands, from the pane it was
/// tapped in: a pane already showing that kind of thing or an empty
/// launcher before a new pane; a new pane to the right in landscape and below
/// in portrait, by the fit rule; the main pane on a compact window or with no
/// pane left to make. The chat, terminals, Rex and games are never replaced.
@Suite("Pane link placement")
struct PaneLinkPlacementTests: PaneFixtureBuilding {
    private let file = PaneRoute.file(.workspace(id: "w", worktree: nil), path: "a.md", line: nil)
    private let folder = PaneRoute.files(workspace: "w", path: "Sources")
    private let launcher = PaneRoute.local(PaneLocalScreen.launcher(workspaceId: "w").token)
    private let terminal = PaneRoute.local(PaneLocalScreen.terminal(workspaceId: "w").token)
    private let rex = PaneRoute.local(PaneLocalScreen.rex.token)

    private func page() throws -> PaneRoute { .browser(try #require(URL(string: "https://example.com"))) }

    /// The iPad mini's window, by the fit rule the host lays panes out with.
    private func window(_ size: CGSize) -> (PaneLayout) -> PanePresentation {
        { layout in
            PanePresentation.resolve(
                layout, size: size, sidebarWidth: 0, bottomInset: 0, keyboardHeight: 0, firstResponderLeaf: nil,
                minimumSize: { PaneMinimumSize.standard(for: $0.stack.last?.route ?? .sessions(workspace: nil)) ?? PaneMinimumSize.list },
                liveCap: 8
            )
        }
    }

    private static let landscape = CGSize(width: 1133, height: 744)
    private static let portrait = CGSize(width: 744, height: 1133)

    private func place(
        _ kind: PaneLinkKind,
        in cells: PaneLayout,
        from source: String = "chat",
        size: CGSize = landscape,
        isWide: Bool = true,
        canAddPane: Bool = true
    ) -> PaneLinkPlacement {
        let route: PaneRoute = switch kind {
        case .file: file
        case .folder: folder
        case .webPage: .browser(URL(fileURLWithPath: "/"))
        }
        return PaneLinkPlacement.resolve(
            kind,
            isWide: isWide,
            canAddPane: canAddPane,
            cells: cells,
            source: id(source),
            routedLeaf: id("chat"),
            isPortrait: size.height > size.width,
            shown: { PaneLinkPlacement.shown($0.stack.last) },
            fits: { target, edge in PaneOpenChoices.fits(edge, of: target, in: cells, showing: route, presentation: window(size)) }
        )
    }

    private var chatAlone: PaneLayout { PaneLayout(single: leaf("chat")) }

    @Test func aLandscapeWindowOpensTheLinkToTheChatsRight() {
        for kind in [PaneLinkKind.file, .folder, .webPage] {
            #expect(place(kind, in: chatAlone) == .split(id("chat"), .right), "\(kind)")
        }
    }

    @Test func aPortraitWindowOpensTheLinkBelowTheChat() {
        for kind in [PaneLinkKind.file, .folder, .webPage] {
            #expect(place(kind, in: chatAlone, size: Self.portrait) == .split(id("chat"), .bottom), "\(kind)")
        }
    }

    /// With a terminal beside the chat, a new file pane splits the terminal's
    /// cell, not the chat's. Landscape leaves too little width for it to the
    /// terminal's right, so it opens below; with no room either way it still
    /// opens on the window's side, where the fit rule hides the least
    /// recently used pane.
    @Test func withNoRoomOnThePreferredSideTheOtherSideTakesIt() {
        let cells = row([(leaf("chat"), 0.5), (leaf("t", terminal), 0.5)])
        #expect(place(.file, in: cells, size: CGSize(width: 813, height: 744)) == .split(id("t"), .bottom))
        #expect(place(.file, in: cells, size: CGSize(width: 813, height: 500)) == .split(id("t"), .right))
    }

    /// Portrait with a file below the chat: a folder link splits the file's
    /// pane, so the chat keeps its half of the window.
    @Test func aChatLinksNextPaneSplitsTheOtherPaneSoTheChatKeepsItsShare() {
        let cells = PaneLayout(
            root: .split(axis: .column, children: [.leaf(leaf("chat")), .leaf(leaf("doc", file))], weights: [0.5, 0.5]),
            focus: id("chat"),
            recency: ids("chat", "doc")
        )
        #expect(place(.folder, in: cells, size: Self.portrait) == .split(id("doc"), .bottom))
    }

    @Test func anEmptyLauncherIsReusedBeforeANewPane() {
        let cells = row([(leaf("chat"), 0.5), (leaf("new", launcher), 0.5)])
        #expect(place(.file, in: cells) == .reuse(id("new")))
        #expect(place(.webPage, in: cells, size: Self.portrait) == .reuse(id("new")))
    }

    /// A pane showing the same kind of thing takes the link before a
    /// launcher does, the most recently used first; each kind finds its own.
    @Test func aPaneShowingTheSameKindIsReusedFirst() throws {
        let cells = row(
            [(leaf("chat"), 0.2), (leaf("new", launcher), 0.2), (leaf("doc1", file), 0.2),
             (leaf("doc2", file), 0.2), (leaf("web", try page()), 0.2)],
            recency: ["chat", "doc2", "new", "web", "doc1"]
        )
        #expect(place(.file, in: cells) == .reuse(id("doc2")))
        #expect(place(.webPage, in: cells) == .reuse(id("web")))
        #expect(place(.folder, in: cells) == .reuse(id("new")), "no Files pane, so the launcher")
    }

    /// The chat, the pane the link was tapped in, a terminal, Rex and a
    /// collapsed pane keep what they show: the link gets a pane of its own.
    @Test func theChatTheSourceTerminalsAndRexAreNeverReplaced() {
        var cells = row([(leaf("chat"), 0.3), (leaf("t", terminal), 0.2), (leaf("rex", rex), 0.2), (leaf("doc", file), 0.3)])
        #expect(place(.file, in: cells, from: "doc", size: CGSize(width: 2400, height: 744)) == .split(id("doc"), .right))
        cells.collapsed[id("doc")] = 0.3
        #expect(place(.file, in: cells, size: CGSize(width: 2400, height: 744)) == .split(id("t"), .right))
    }

    @Test func aCompactWindowOpensInTheMainPaneAsBefore() {
        let cells = row([(leaf("chat"), 0.5), (leaf("new", launcher), 0.5)])
        #expect(place(.file, in: cells, isWide: false) == .mainPane)
        #expect(place(.webPage, in: chatAlone, isWide: false) == .mainPane)
    }

    @Test func aWindowAtItsMostPanesStillReusesOne() {
        let full = row([(leaf("chat"), 0.5), (leaf("t", terminal), 0.5)])
        #expect(place(.file, in: full, canAddPane: false) == .mainPane)
        let withLauncher = row([(leaf("chat"), 0.5), (leaf("new", launcher), 0.5)])
        #expect(place(.file, in: withLauncher, canAddPane: false) == .reuse(id("new")))
    }

    /// What each pane shows, as the placement weighs it.
    @Test func panesAreClassifiedByWhatTheyShow() throws {
        let entry = { (route: PaneRoute) in PaneStackEntry(serverId: "s", route: route) }
        #expect(PaneLinkPlacement.shown(entry(file)) == .kind(.file))
        #expect(PaneLinkPlacement.shown(entry(folder)) == .kind(.folder))
        #expect(PaneLinkPlacement.shown(entry(.hostFiles(path: "~/notes"))) == .kind(.folder))
        #expect(PaneLinkPlacement.shown(entry(try page())) == .kind(.webPage))
        #expect(PaneLinkPlacement.shown(entry(.local(PaneLocalScreen.browser.token))) == .kind(.webPage))
        #expect(PaneLinkPlacement.shown(entry(launcher)) == .launcher)
        for other in [terminal, rex, .session("s"), .godot(project: "g"), .git(workspace: "w", worktree: nil)] {
            #expect(PaneLinkPlacement.shown(entry(other)) == .other, "\(other)")
        }
    }
}
