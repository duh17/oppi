import Foundation
import Testing
@testable import Oppi

/// Where a new pane lands when nothing says, from the pane it was opened
/// from: a pane already showing that kind of thing or an empty launcher
/// before a new pane; a new pane on the kind's New Panes side (a terminal
/// below, the rest to the right in landscape and below in portrait), by the
/// fit rule; the main pane on a compact window or with no pane left to make.
/// The chat, terminals, Rex and games are never replaced.
@Suite("Side pane placement")
struct SidePanePlacementTests: PaneFixtureBuilding {
    private typealias Side = AppPreferenceStore.NewPanes.Side

    private let file = PaneRoute.file(.workspace(id: "w", worktree: nil), path: "a.md", line: nil)
    private let folder = PaneRoute.files(workspace: "w", path: "Sources")
    private let launcher = PaneRoute.local(PaneLocalScreen.launcher(workspaceId: "w").token)
    private let terminal = PaneRoute.local(PaneLocalScreen.terminal(workspaceId: "w").token)
    private let rex = PaneRoute.local(PaneLocalScreen.rex.token)
    private let game = PaneRoute.godot(project: "g")

    private func page() throws -> PaneRoute { .browser(try #require(URL(string: "https://example.com"))) }

    /// The iPad mini's window, by the fit rule the host lays panes out with.
    private func window(_ size: CGSize) -> (PaneLayout) -> PanePresentation {
        { layout in
            PanePresentation.resolve(
                layout, size: size, sidebarWidth: 0, topInset: 0, bottomInset: 0, keyboardHeight: 0, firstResponderLeaf: nil,
                minimumSize: { PaneMinimumSize.standard(for: $0.stack.last?.route ?? .sessions(workspace: nil)) ?? PaneMinimumSize.list },
                liveCap: 8
            )
        }
    }

    private static let landscape = CGSize(width: 1133, height: 744)
    private static let portrait = CGSize(width: 744, height: 1133)

    private func route(of kind: PaneContentKind) -> PaneRoute {
        switch kind {
        case .file: file
        case .folder: folder
        case .webPage: .browser(URL(fileURLWithPath: "/"))
        case .sessions: .sessions(workspace: "w")
        case .terminal: terminal
        case .rex: rex
        case .game: game
        case .git: .git(workspace: "w", worktree: nil)
        }
    }

    /// `side` nil is the kind's default, as nothing saved reads.
    private func place(
        _ kind: PaneContentKind,
        in cells: PaneLayout,
        from source: String = "chat",
        size: CGSize = landscape,
        side: Side? = nil,
        isWide: Bool = true,
        canAddPane: Bool = true
    ) -> SidePanePlacement {
        SidePanePlacement.resolve(
            kind,
            side: side ?? AppPreferenceStore.NewPanes.sideDefault(kind.setting),
            isWide: isWide,
            canAddPane: canAddPane,
            cells: cells,
            source: id(source),
            mainLeaf: id("chat"),
            isPortrait: size.height > size.width,
            shown: { SidePanePlacement.shown($0.stack.last) },
            fits: { target, edge in
                PaneOpenChoices.fits(edge, of: target, in: cells, showing: route(of: kind), presentation: window(size))
            }
        )
    }

    private var chatAlone: PaneLayout { PaneLayout(single: leaf("chat")) }

    /// The defaults with nothing saved: a terminal or Rex opens below the
    /// chat whichever way the window turns; a file, folder, page, session
    /// list or game opens to its right in landscape and below in portrait.
    @Test func eachKindOpensOnItsDefaultSideInBothOrientations() {
        for kind in PaneContentKind.allCases {
            let landscape: PaneEdge = kind.setting == .terminal ? .bottom : .right
            #expect(place(kind, in: chatAlone) == .split(id("chat"), landscape), "\(kind) in landscape")
            #expect(place(kind, in: chatAlone, size: Self.portrait) == .split(id("chat"), .bottom), "\(kind) in portrait")
        }
    }

    /// A New Panes side the person set wins over the window's shape, for
    /// that kind alone.
    @Test func aSavedSideIsFollowedForItsKind() {
        #expect(place(.terminal, in: chatAlone, side: .right) == .split(id("chat"), .right))
        #expect(place(.terminal, in: chatAlone, size: Self.portrait, side: .right) == .split(id("chat"), .right))
        #expect(place(.file, in: chatAlone, side: .below) == .split(id("chat"), .bottom))
        #expect(place(.webPage, in: chatAlone, size: Self.portrait, side: .right) == .split(id("chat"), .right))
        #expect(place(.terminal, in: chatAlone, side: .automatic) == .split(id("chat"), .right), "Automatic follows the window")
        #expect(place(.terminal, in: chatAlone, size: Self.portrait, side: .automatic) == .split(id("chat"), .bottom))
    }

    @Test func theSettingsKindsGroupTheContentKinds() {
        #expect(PaneContentKind.allCases.map(\.setting) == [.files, .files, .web, .sessions, .terminal, .terminal, .games, .files])
        #expect(AppPreferenceStore.NewPanes.Kind.allCases.map(AppPreferenceStore.NewPanes.sideDefault)
            == [.below, .automatic, .automatic, .automatic, .automatic])
    }

    /// With a terminal beside the chat, a new file pane splits the terminal's
    /// cell, not the chat's. Landscape leaves too little width for it to the
    /// terminal's right, so it opens below; with no room either way it still
    /// opens on its side, where the fit rule hides the least recently used
    /// pane. A side the person set falls back the same way.
    @Test func withNoRoomOnTheChosenSideTheOtherSideTakesIt() {
        let cells = row([(leaf("chat"), 0.5), (leaf("t", terminal), 0.5)])
        #expect(place(.file, in: cells, size: CGSize(width: 813, height: 744)) == .split(id("t"), .bottom))
        #expect(place(.file, in: cells, size: CGSize(width: 813, height: 500)) == .split(id("t"), .right))
        #expect(place(.webPage, in: cells, size: CGSize(width: 813, height: 744), side: .right) == .split(id("t"), .bottom))
        let short = CGSize(width: 1400, height: 500)
        #expect(place(.terminal, in: chatAlone, size: short) == .split(id("chat"), .right), "too short for a terminal below")
        #expect(place(.terminal, in: chatAlone, size: CGSize(width: 500, height: 400)) == .split(id("chat"), .bottom),
                "no room either way: its own side")
    }

    /// Portrait with a file below the chat: a folder link splits the file's
    /// pane, so the chat keeps its half of the window.
    @Test func theNextPaneFromTheChatSplitsTheOtherPaneSoTheChatKeepsItsShare() {
        let cells = PaneLayout(
            root: .split(axis: .column, children: [.leaf(leaf("chat")), .leaf(leaf("doc", file))], weights: [0.5, 0.5]),
            focus: id("chat"),
            recency: ids("chat", "doc")
        )
        #expect(place(.folder, in: cells, size: Self.portrait) == .split(id("doc"), .bottom))
    }

    @Test func anEmptyLauncherIsReusedBeforeANewPaneByEveryKind() {
        let cells = row([(leaf("chat"), 0.5), (leaf("new", launcher), 0.5)])
        for kind in PaneContentKind.allCases {
            #expect(place(kind, in: cells) == .reuse(id("new")), "\(kind)")
        }
        #expect(place(.webPage, in: cells, size: Self.portrait) == .reuse(id("new")))
    }

    /// A pane showing the same kind of thing takes the link before a
    /// launcher does, the most recently used first; each kind finds its own.
    @Test func aPaneShowingTheSameKindIsReusedFirst() throws {
        let cells = row(
            [(leaf("chat"), 0.15), (leaf("new", launcher), 0.15), (leaf("doc1", file), 0.15),
             (leaf("doc2", file), 0.15), (leaf("web", try page()), 0.2), (leaf("list", .sessions(workspace: "w")), 0.2)],
            recency: ["chat", "doc2", "new", "web", "doc1", "list"]
        )
        #expect(place(.file, in: cells) == .reuse(id("doc2")))
        #expect(place(.webPage, in: cells) == .reuse(id("web")))
        #expect(place(.sessions, in: cells) == .reuse(id("list")))
        #expect(place(.folder, in: cells) == .reuse(id("new")), "no Files pane, so the launcher")
    }

    /// The chat, the source pane, a terminal, Rex, a game and a collapsed
    /// pane keep what they show: new content gets a pane of its own, even
    /// content of the same kind.
    @Test func theChatTheSourceTerminalsRexAndGamesAreNeverReplaced() {
        let wide = CGSize(width: 2400, height: 744)
        var cells = row([(leaf("chat"), 0.3), (leaf("t", terminal), 0.2), (leaf("rex", rex), 0.2), (leaf("doc", file), 0.3)])
        #expect(place(.file, in: cells, from: "doc", size: wide) == .split(id("doc"), .right))
        #expect(place(.terminal, in: cells, from: "doc", size: wide, side: .right) == .split(id("doc"), .right))
        #expect(place(.rex, in: cells, from: "doc", size: wide, side: .right) == .split(id("doc"), .right))
        cells.collapsed[id("doc")] = 0.3
        #expect(place(.file, in: cells, size: wide) == .split(id("t"), .right))
        let playing = row([(leaf("chat"), 0.5), (leaf("game", game), 0.5)])
        #expect(place(.game, in: playing, size: wide) == .split(id("game"), .right))
    }

    @Test func aCompactWindowOpensInTheMainPaneAsBefore() {
        let cells = row([(leaf("chat"), 0.5), (leaf("new", launcher), 0.5)])
        for kind in PaneContentKind.allCases {
            #expect(place(kind, in: cells, isWide: false) == .mainPane, "\(kind)")
            #expect(place(kind, in: chatAlone, isWide: false) == .mainPane, "\(kind)")
        }
    }

    @Test func aWindowAtItsMostPanesStillReusesOne() {
        let full = row([(leaf("chat"), 0.5), (leaf("t", terminal), 0.5)])
        #expect(place(.file, in: full, canAddPane: false) == .mainPane)
        #expect(place(.terminal, in: full, canAddPane: false) == .mainPane)
        let withLauncher = row([(leaf("chat"), 0.5), (leaf("new", launcher), 0.5)])
        #expect(place(.file, in: withLauncher, canAddPane: false) == .reuse(id("new")))
    }

    /// What each pane shows, as the placement weighs it.
    @Test func panesAreClassifiedByWhatTheyShow() throws {
        let entry = { (route: PaneRoute) in PaneStackEntry(serverId: "s", route: route) }
        #expect(SidePanePlacement.shown(entry(file)) == .kind(.file))
        #expect(SidePanePlacement.shown(entry(folder)) == .kind(.folder))
        #expect(SidePanePlacement.shown(entry(.hostFiles(path: "~/notes"))) == .kind(.folder))
        #expect(SidePanePlacement.shown(entry(try page())) == .kind(.webPage))
        #expect(SidePanePlacement.shown(entry(.local(PaneLocalScreen.browser.token))) == .kind(.webPage))
        #expect(SidePanePlacement.shown(entry(.sessions(workspace: "w"))) == .kind(.sessions))
        #expect(SidePanePlacement.shown(entry(terminal)) == .kind(.terminal))
        #expect(SidePanePlacement.shown(entry(rex)) == .kind(.rex))
        #expect(SidePanePlacement.shown(entry(game)) == .kind(.game))
        #expect(SidePanePlacement.shown(entry(.local(PaneLocalScreen.godot.token))) == .kind(.game))
        #expect(SidePanePlacement.shown(entry(launcher)) == .launcher)
        #expect(SidePanePlacement.shown(entry(.git(workspace: "w", worktree: nil))) == .kind(.git))
        #expect(SidePanePlacement.shown(entry(.commit(workspace: "w", sha: "9f86d08"))) == .kind(.git))
        for other in [PaneRoute.session("s")] {
            #expect(SidePanePlacement.shown(entry(other)) == .other, "\(other)")
        }
    }

    /// Where `kind` from `origin` lands with focus on pane `focused`, as
    /// `PaneHostController.openBeside` places it; nil when it opens in the main pane without trying beside.
    private func place(
        _ kind: PaneContentKind, in cells: PaneLayout, origin: SidePaneOrigin, focused: String, size: CGSize = landscape
    ) -> SidePanePlacement? {
        SidePanePlacement.source(of: origin, focused: id(focused), mainLeaf: id("chat")).map { place(kind, in: cells, from: $0.raw, size: size) }
    }

    /// A link from outside the app (`oppi://file`, a share) has no pane of its
    /// own: with a file beside the chat and the last touch in that file's
    /// pane, the next outside file still opens beside the main pane, so it
    /// takes the file's pane rather than opening a third. A link tapped in
    /// the file's pane opens beside that pane, which keeps its file. Open
    /// Here never opens beside.
    @Test func anOutsideLinkOpensBesideTheMainPaneWhicheverPaneHasFocus() {
        let cells = row([(leaf("chat"), 0.5), (leaf("doc", file), 0.5)])
        let wide = CGSize(width: 2400, height: 744)
        #expect(place(.file, in: cells, origin: .external, focused: "doc", size: wide) == .reuse(id("doc")))
        #expect(place(.file, in: cells, origin: .external, focused: "chat", size: wide) == .reuse(id("doc")), "the same from either pane")
        #expect(place(.folder, in: cells, origin: .external, focused: "doc", size: wide) == .split(id("doc"), .right))
        #expect(place(.file, in: cells, origin: .focusedPane, focused: "doc", size: wide) == .split(id("doc"), .right))
        #expect(place(.file, in: cells, origin: .focusedPane, focused: "chat", size: wide) == .reuse(id("doc")))
        #expect(place(.file, in: cells, origin: .pane(id("doc")), focused: "chat", size: wide) == .split(id("doc"), .right))
        #expect(place(.file, in: cells, origin: .mainPane, focused: "doc", size: wide) == nil)
    }
}
