import Foundation
import Testing
import UIKit
@testable import Oppi

/// N7c: the sidebar targets the main pane. A row's tap opens its place there
/// whatever pane has focus and never moves focus or rewrites a side pane (the
/// owner's answer over §2.5's focus targeting), and a row's long press offers
/// the place in a new pane beside the main pane, which Undo takes back.
@Suite("The sidebar's rows")
@MainActor
struct SidebarRowTests {
    static let server = "server-1"
    static let workspace = WorkspaceNavTarget(serverId: server, workspace: makeTestWorkspace(id: "workspace-1"))

    /// A pane that can have focus when a sidebar row is tapped: the main leaf,
    /// then each kind of side pane the window holds.
    enum FocusedPane: String, CaseIterable {
        case mainPane
        case sessionList
        case chat
        case file
        case folder
        case terminal
        case game
        case webPage
        case launcher

        /// What a side pane of this kind shows; nil for the main leaf.
        @MainActor
        var route: WorkspaceStackRouteElement? {
            let server = SidebarRowTests.server
            return switch self {
            case .mainPane: nil
            case .sessionList: .entry(PaneStackEntry(serverId: server, route: .sessions(workspace: "workspace-1")))
            case .chat: .entry(PaneStackEntry(serverId: server, route: .session("session-side")))
            case .file: .entry(PaneStackEntry(serverId: server, route: .file(.host, path: "notes/a.md", line: nil)))
            case .folder: .fileBrowser(FileBrowserNavTarget(serverId: server, workspaceId: "workspace-1", path: "notes/"))
            case .terminal: .terminal(TerminalNavTarget { UIViewController() })
            case .game: .entry(PaneStackEntry(serverId: server, route: .godot(project: "tide-runner")))
            case .webPage: .entry(PaneStackEntry(serverId: server, route: .browser(URL(string: "https://example.test/page")!)))
            case .launcher:
                .entry(PaneStackEntry(serverId: server, route: .local(PaneLocalScreen.launcher(workspaceId: "workspace-1").token)))
            }
        }
    }

    /// A row tapped with `focus` having the window's focus: the place becomes
    /// the main pane's route, the sidebar highlights it, and the focused pane
    /// keeps its screen and its focus.
    @Test func aRowOpensInTheMainPaneWhateverPaneHasFocus() throws {
        for focus in FocusedPane.allCases {
            let navigation = SceneNavigation()
            navigation.app.launchPhase = .ready
            navigation.app.showOnboarding = false
            navigation.setWorkspaceNavigationPresentation(.split)
            let panes = navigation.panes
            navigation.open(.place(.utility(.agents)))
            var side: PaneID?
            var route: WorkspaceStackRouteElement?
            if let shown = focus.route {
                route = shown
                side = try #require(panes.split(panes.mainLeafID, edge: .right, showing: shown), "\(focus): no pane beside")
                panes.focus(try #require(side))
            }
            let routesBefore = panes.splitLeaves.compactMap { leaf in panes.stack(of: leaf.id).map { (leaf.id, $0) } }
            let focusBefore = panes.cellLayout.focus

            navigation.open(.place(.sessions(Self.workspace)))

            #expect(navigation.mainPaneRoute == PaneStack(place: .sessions(Self.workspace)), "\(focus): the main pane")
            #expect(navigation.currentPlace == .sessions(Self.workspace), "\(focus): the sidebar highlights the main pane's place")
            #expect(panes.cellLayout.focus == focusBefore, "\(focus): the open moved focus")
            for (id, route) in routesBefore {
                #expect(panes.stack(of: id) == route, "\(focus): the open rewrote the pane \(id)")
            }
            if let side { #expect(panes.stack(of: side)?.top == route, "\(focus): the focused pane kept its screen") }
        }
    }

    /// A place holds its own lock, and opens as a screen a saved tree keeps —
    /// except a utility, which has no link (`PaneEntries.entry(for:)`).
    @Test func aPlaceOpensWithItsLockAndTheScreenASavedTreeKeeps() {
        let allSessions = PaneOpenContent(place: .allSessions, serverId: Self.server)
        #expect(allSessions.lockTarget == .server(Self.server))

        let workspace = PaneOpenContent(place: .sessions(Self.workspace), serverId: "server-unused")
        #expect(workspace.lockTarget == .workspace(serverId: Self.server, workspaceId: "workspace-1"))

        let agents = PaneOpenContent(place: .utility(.agents), serverId: Self.server)
        #expect(agents.lockTarget == .server(Self.server))

        // A relaunch's restore keeps a pane whose screen has a link, as it
        // keeps the launcher's choice; a utility's pane goes with it.
        #expect(PaneEntries.entry(for: allSessions.route) != nil)
        #expect(PaneEntries.entry(for: workspace.route) != nil)
        #expect(PaneEntries.entry(for: agents.route) == nil)
    }

    /// A row's menu is the two new panes and nothing else: a chosen pane shows
    /// the place beside the main pane, focused, and Undo closes it.
    @Test func aRowsMenuOpensThePlaceBesideWithUndo() throws {
        let host = PaneTestHost(width: 1133, height: 744)
        defer { host.hide() }
        host.panes.traitOverrides.appRootEnvironment = host.root
        host.panes.updateTraitsIfNeeded()
        try #require(AppRootEnvironment.near(host.panes) != nil, "the host sees the app root")
        let panes = host.scenePanes
        let main = panes.mainLeafID

        let items = PaneOpenMenu.items(in: host.panes, from: main, includesOpenHere: false, offersOtherPanes: false) { _ in }
        #expect(items.map(\.identifier) == ["pane.open.newPane.right", "pane.open.newPane.below"])

        let content = PaneOpenContent(place: .sessions(Self.workspace), serverId: Self.server)
        host.act { host.panes.place(content, at: .newPane(.right), from: main) }
        let opened = try #require(panes.splitLeaves.first?.id, "no pane beside")
        #expect(panes.stack(of: opened)?.top == content.route, "the new pane shows the place the menu opened")
        #expect(host.panes.focusedCell == opened, "the new pane has focus")
        #expect(panes.undoAction == "Open in New Pane")

        host.act { host.panes.undoPanes() }
        #expect(panes.splitLeaves.isEmpty, "Undo closed the new pane")
    }

    /// Opening and closing the portrait drawer takes no focus: the drawer
    /// shows and hides over the panes and never writes the tree.
    @Test func theDrawerOpensOverThePanesWithoutTakingTheirFocus() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let root = makeTestAppRoot()
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 744, height: 1133)
        window.traitOverrides.horizontalSizeClass = .regular
        window.traitOverrides.verticalSizeClass = .regular
        window.traitOverrides.appRootEnvironment = root
        let stack = ShellNavigationController(root: root)
        let panes = root.navigation.panes
        let host = PaneHostController(primary: stack, panes: panes)
        root.navigation.paneArea = host
        let drawer = WorkspaceDrawerController(root: root)
        window.rootViewController = drawer
        drawer.adopt(WorkspacePaneArea(stack: stack, host: host))
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        let side = try #require(panes.split(
            panes.mainLeafID, edge: .bottom,
            showing: .entry(PaneStackEntry(serverId: Self.server, route: .file(.host, path: "notes/a.md", line: nil)))
        ))
        panes.focus(side)
        let before = panes.cellLayout

        drawer.toggleSidebar()
        #expect(drawer.isSidebarOpen, "the drawer opened")
        #expect(panes.cellLayout == before, "opening the drawer changed the panes")
        drawer.toggleSidebar()
        #expect(!drawer.isSidebarOpen, "the drawer closed")
        #expect(panes.cellLayout == before, "closing the drawer changed the panes")
    }
}
