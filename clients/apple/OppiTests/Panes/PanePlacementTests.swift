import Foundation
import Testing
import UIKit
@testable import Oppi

/// The one placement table (`PanePlacement`), as a table: every kind of open,
/// in each window layout, says where it goes, what then shows on top of the
/// main pane, where Back goes, and which place the sidebar (or the drawer)
/// highlights. Side content and the panes it fills are the other suite
/// (`PaneSideContentTests`).
@Suite("Where an open lands")
@MainActor
struct PanePlacementTests {
    /// The main leaf a fresh window starts with.
    static let main: PaneID = {
        guard let id = PaneID("leaf-1") else { preconditionFailure("leaf-1 is not a pane id") }
        return id
    }()

    /// The rule reads only the main pane's route and the window's shell, so
    /// the iPhone and the iPad in portrait are one layout here: both show the stack shell. A side pane is
    /// a layout of its own because a main-pane open must leave it alone.
    enum Layout: CaseIterable {
        /// The iPhone, and the iPad in portrait.
        case stackShell
        /// The iPad in landscape.
        case splitShell
        /// The iPad in landscape with a file in a side pane.
        case splitShellBesideASidePane

        var presentation: WorkspaceNavigationPresentation {
            self == .stackShell ? .stack : .split
        }
    }

    /// What one shell does with an open.
    struct Outcome {
        let placement: PanePlacement
        /// The main pane's top screen after the open.
        let shows: WorkspaceStackRouteElement
        /// The top screen after Back; nil when the open left nothing to go back from.
        let back: WorkspaceStackRouteElement?
        /// The place the sidebar or the drawer highlights after the open (`currentPlace`).
        let place: NavigationPlace
    }

    struct Row {
        let journey: String
        var start: [(NavigationDestination, OpenOrigin?)] = []
        let open: NavigationDestination
        /// The open's origin; nil is a screen of the main pane's own.
        var from: OpenOrigin? = nil
        /// What kind of side content it is, when a pane beside may take it.
        var beside: PaneContentKind? = nil
        let stack: Outcome
        let split: Outcome
    }

    static let server = "server-1"
    static let workspace = WorkspaceNavTarget(serverId: server, workspace: makeTestWorkspace(id: "workspace-1"))
    static let otherWorkspace = WorkspaceNavTarget(serverId: server, workspace: makeTestWorkspace(id: "workspace-2"))
    static let chat = WorkspaceSessionNavTarget(serverId: server, sessionId: "chat", workspaceId: "workspace-1")
    static let other = WorkspaceSessionNavTarget(serverId: server, sessionId: "other", workspaceId: "workspace-1")
    static let folder = FileBrowserNavTarget(serverId: server, workspaceId: "workspace-1", path: "notes/")
    static let file = WorkspaceLinkedFileNavTarget.workspaceFile(serverId: server, workspaceId: "workspace-1", path: "notes/a.md")
    static let reader = ChatReaderNavTarget(id: UUID())
    static let entry = PaneStackEntry(serverId: "server-unpaired", route: .session("linked"))
    static let serverDetails = ServerDetailsNavTarget(serverId: server)
    static let inWorkspace = NavigationPlace.sessions(workspace)
    static let terminal = TerminalNavTarget { UIViewController() }
    static let rex = NavigationPlace.utility(.rex)
    static let terminals = NavigationPlace.utility(.sshTerminal)

    static func outcome(
        _ placement: PanePlacement,
        shows: WorkspaceStackRouteElement,
        back: WorkspaceStackRouteElement?,
        place: NavigationPlace = .allSessions
    ) -> Outcome {
        Outcome(placement: placement, shows: shows, back: back, place: place)
    }

    static let rows: [Row] = [
        // Places.
        Row(journey: "a workspace's list → All Sessions", start: [(.place(.sessions(workspace)), nil)],
            open: .place(.allSessions),
            stack: outcome(.root(Self.main, .allSessions), shows: .allSessions, back: nil),
            split: outcome(.root(Self.main, .allSessions), shows: .allSessions, back: nil)),
        Row(journey: "Agents → a workspace's list", start: [(.place(.utility(.agents)), nil)],
            open: .place(.sessions(workspace)),
            stack: outcome(.root(Self.main, inWorkspace), shows: .workspace(workspace), back: .allSessions, place: inWorkspace),
            split: outcome(.root(Self.main, inWorkspace), shows: .workspace(workspace), back: nil, place: inWorkspace)),
        // A place replaces the main pane's stack in both shells, opened from the sidebar, the drawer, a
        // link or a key; the stack shell keeps All Sessions under it.
        Row(journey: "a chat → Pinned", start: [(.chat(chat), nil)],
            open: .place(.utility(.pinned)),
            stack: outcome(.root(Self.main, .utility(.pinned)), shows: .utility(.pinned), back: .allSessions, place: .utility(.pinned)),
            split: outcome(.root(Self.main, .utility(.pinned)), shows: .utility(.pinned), back: nil, place: .utility(.pinned))),
        Row(journey: "a workspace's chat → oppi://pins",
            start: [(.place(.sessions(workspace)), nil), (.chat(chat), .row(Self.main, workspace: workspace))],
            open: .place(.utility(.pinned)), from: .external,
            stack: outcome(.root(Self.main, .utility(.pinned)), shows: .utility(.pinned), back: .allSessions, place: .utility(.pinned)),
            split: outcome(.root(Self.main, .utility(.pinned)), shows: .utility(.pinned), back: nil, place: .utility(.pinned))),
        Row(journey: "a chat → Pinned → a pinned chat",
            start: [(.chat(chat), nil), (.place(.utility(.pinned)), nil)],
            open: .chat(other),
            stack: outcome(.push(Self.main), shows: .session(other), back: .utility(.pinned), place: .utility(.pinned)),
            split: outcome(.push(Self.main), shows: .session(other), back: .utility(.pinned), place: .utility(.pinned))),

        // Chats from a list or a button.
        Row(journey: "All Sessions → chat",
            open: .chat(chat),
            stack: outcome(.push(Self.main), shows: .session(chat), back: .allSessions),
            split: outcome(.onPlace(Self.main, .allSessions), shows: .session(chat), back: .allSessions)),
        Row(journey: "a workspace's list → chat", start: [(.place(.sessions(workspace)), nil)],
            open: .chat(chat), from: .row(Self.main, workspace: workspace),
            stack: outcome(.onPlace(Self.main, inWorkspace), shows: .session(chat), back: .workspace(workspace), place: inWorkspace),
            split: outcome(.onPlace(Self.main, inWorkspace), shows: .session(chat), back: .workspace(workspace), place: inWorkspace)),
        Row(journey: "Agents → chat", start: [(.place(.utility(.agents)), nil)],
            open: .chat(chat),
            stack: outcome(.push(Self.main), shows: .session(chat), back: .utility(.agents), place: .utility(.agents)),
            split: outcome(.push(Self.main), shows: .session(chat), back: .utility(.agents), place: .utility(.agents))),
        Row(journey: "a chat's button → another chat", start: [(.chat(chat), nil)],
            open: .chat(other),
            stack: outcome(.push(Self.main), shows: .session(other), back: .session(chat)),
            split: outcome(.onPlace(Self.main, .allSessions), shows: .session(other), back: .allSessions)),
        Row(journey: "Quick Session at All Sessions → a chat in a workspace",
            open: .chat(chat), from: .row(Self.main, workspace: workspace),
            stack: outcome(.push(Self.main), shows: .session(chat), back: .allSessions),
            split: outcome(.onPlace(Self.main, .allSessions), shows: .session(chat), back: .allSessions)),
        Row(journey: "Quick Session at one workspace's list → a chat in another",
            start: [(.place(.sessions(otherWorkspace)), nil)],
            open: .chat(chat), from: .row(Self.main, workspace: workspace),
            stack: outcome(.onPlace(Self.main, inWorkspace), shows: .session(chat), back: .workspace(workspace), place: inWorkspace),
            split: outcome(.onPlace(Self.main, inWorkspace), shows: .session(chat), back: .workspace(workspace), place: inWorkspace)),
        // Over All Sessions or a utility the stack shell pushes Quick Session's chat; the split
        // shell puts it on All Sessions, its column's place, or over the utility.
        Row(journey: "Quick Session over a chat at All Sessions → a chat in a workspace",
            start: [(.chat(other), nil)],
            open: .chat(chat), from: .row(Self.main, workspace: workspace),
            stack: outcome(.push(Self.main), shows: .session(chat), back: .session(other)),
            split: outcome(.onPlace(Self.main, .allSessions), shows: .session(chat), back: .allSessions)),
        Row(journey: "Quick Session from Agents → a chat in a workspace", start: [(.place(.utility(.agents)), nil)],
            open: .chat(chat), from: .row(Self.main, workspace: workspace),
            stack: outcome(.push(Self.main), shows: .session(chat), back: .utility(.agents), place: .utility(.agents)),
            split: outcome(.push(Self.main), shows: .session(chat), back: .utility(.agents), place: .utility(.agents))),
        Row(journey: "Quick Session over a file → a chat in the file's workspace",
            start: [(.page(.linkedFile(file)), nil)],
            open: .chat(chat), from: .row(Self.main, workspace: workspace),
            stack: outcome(.push(Self.main), shows: .session(chat), back: .linkedFile(file)),
            split: outcome(.onPlace(Self.main, .allSessions), shows: .session(chat), back: .allSessions)),

        // Chats from a link.
        Row(journey: "a chat → a session link", start: [(.chat(chat), nil)],
            open: .chat(other), from: .link,
            stack: outcome(.push(Self.main), shows: .session(other), back: .session(chat)),
            split: outcome(.push(Self.main), shows: .session(other), back: .session(chat))),
        Row(journey: "a chat → a link to itself", start: [(.chat(chat), nil)],
            open: .chat(chat), from: .link,
            stack: outcome(.stay, shows: .session(chat), back: .allSessions),
            split: outcome(.stay, shows: .session(chat), back: .allSessions)),

        // Chats from outside the app.
        Row(journey: "Pinned → a notification's chat", start: [(.place(.utility(.pinned)), nil)],
            open: .chat(chat), from: .external,
            stack: outcome(.onPlace(Self.main, .allSessions), shows: .session(chat), back: .allSessions),
            split: outcome(.onPlace(Self.main, .allSessions), shows: .session(chat), back: .allSessions)),
        Row(journey: "a workspace's chat → a notification's chat",
            start: [(.place(.sessions(workspace)), nil), (.chat(other), .row(Self.main, workspace: workspace))],
            open: .chat(chat), from: .external,
            stack: outcome(.onPlace(Self.main, .allSessions), shows: .session(chat), back: .allSessions),
            split: outcome(.onPlace(Self.main, inWorkspace), shows: .session(chat), back: .workspace(workspace), place: inWorkspace)),

        // Pages.
        Row(journey: "a chat → a reader", start: [(.chat(chat), nil)],
            open: .page(.chatReader(reader)),
            stack: outcome(.push(Self.main), shows: .chatReader(reader), back: .session(chat)),
            split: outcome(.push(Self.main), shows: .chatReader(reader), back: .session(chat))),
        Row(journey: "a workspace's list → Files", start: [(.place(.sessions(workspace)), nil)],
            open: .page(.fileBrowser(folder)), from: .row(Self.main, workspace: workspace),
            stack: outcome(.push(Self.main), shows: .fileBrowser(folder), back: .workspace(workspace), place: inWorkspace),
            split: outcome(.push(Self.main), shows: .fileBrowser(folder), back: .workspace(workspace), place: inWorkspace)),
        Row(journey: "Pinned → a file", start: [(.place(.utility(.pinned)), nil)],
            open: .page(.linkedFile(file)),
            stack: outcome(.push(Self.main), shows: .linkedFile(file), back: .utility(.pinned), place: .utility(.pinned)),
            split: outcome(.push(Self.main), shows: .linkedFile(file), back: .utility(.pinned), place: .utility(.pinned))),
        Row(journey: "a chat → a file link in it", start: [(.chat(chat), nil)],
            open: .page(.linkedFile(file)), from: .link,
            stack: outcome(.push(Self.main), shows: .linkedFile(file), back: .session(chat)),
            split: outcome(.push(Self.main), shows: .linkedFile(file), back: .session(chat))),
        Row(journey: "a folder → the same folder", start: [(.page(.fileBrowser(folder)), nil)],
            open: .page(.fileBrowser(folder)),
            stack: outcome(.stay, shows: .fileBrowser(folder), back: .allSessions),
            split: outcome(.stay, shows: .fileBrowser(folder), back: .allSessions)),
        Row(journey: "a workspace's list → Workspace Settings", start: [(.place(.sessions(workspace)), nil)],
            open: .page(.workspaceConfiguration(workspace)),
            stack: outcome(.onPlace(Self.main, inWorkspace), shows: .workspaceConfiguration(workspace), back: .workspace(workspace), place: inWorkspace),
            split: outcome(.onPlace(Self.main, inWorkspace), shows: .workspaceConfiguration(workspace), back: .workspace(workspace), place: inWorkspace)),
        Row(journey: "Settings → Server Settings", start: [(.place(.utility(.appSettings)), nil)],
            open: .page(.serverDetails(serverDetails)),
            stack: outcome(.push(Self.main), shows: .serverDetails(serverDetails), back: .utility(.appSettings), place: .utility(.appSettings)),
            split: outcome(.push(Self.main), shows: .serverDetails(serverDetails), back: .utility(.appSettings), place: .utility(.appSettings))),
        Row(journey: "a chat → a link to a server not paired", start: [(.chat(chat), nil)],
            open: .page(.entry(entry)), from: .external,
            stack: outcome(.push(Self.main), shows: .entry(entry), back: .session(chat)),
            split: outcome(.push(Self.main), shows: .entry(entry), back: .session(chat))),

        // Terminals: a page over its list or chat, which the window knows is there.
        Row(journey: "Rex → a session's terminal", start: [(.place(rex), nil)],
            open: .page(.terminal(terminal)),
            stack: outcome(.push(Self.main), shows: .terminal(terminal), back: .utility(.rex), place: rex),
            split: outcome(.push(Self.main), shows: .terminal(terminal), back: .utility(.rex), place: rex)),
        Row(journey: "a chat → its folder terminal", start: [(.chat(chat), nil)],
            open: .page(.terminal(terminal)),
            stack: outcome(.push(Self.main), shows: .terminal(terminal), back: .session(chat)),
            split: outcome(.push(Self.main), shows: .terminal(terminal), back: .session(chat))),
        // A chat replaces a terminal as it replaces any page: the shell lives on in the
        // terminal registry, reachable again from its list.
        Row(journey: "a terminal → a notification's chat",
            start: [(.place(terminals), nil), (.page(.terminal(terminal)), nil)],
            open: .chat(chat), from: .external,
            stack: outcome(.onPlace(Self.main, .allSessions), shows: .session(chat), back: .allSessions),
            split: outcome(.onPlace(Self.main, .allSessions), shows: .session(chat), back: .allSessions)),
        Row(journey: "a terminal → All Sessions", start: [(.place(rex), nil), (.page(.terminal(terminal)), nil)],
            open: .place(.allSessions),
            stack: outcome(.root(Self.main, .allSessions), shows: .allSessions, back: nil),
            split: outcome(.root(Self.main, .allSessions), shows: .allSessions, back: nil)),

        // The host switcher's jobs.
        Row(journey: "All Sessions → Server Settings in the host switcher",
            open: .serverJob(.serverSettings, serverId: server),
            stack: outcome(.replacingServerPages(Self.main), shows: .serverDetails(serverDetails), back: .allSessions),
            split: outcome(.onPlace(Self.main, .allSessions), shows: .serverDetails(serverDetails), back: .allSessions)),
        Row(journey: "a chat's Server Settings → Usage in the host switcher",
            start: [(.chat(chat), nil), (.serverJob(.serverSettings, serverId: server), nil)],
            open: .serverJob(.usage, serverId: server),
            stack: outcome(.replacingServerPages(Self.main), shows: .utility(.manageServers), back: .session(chat)),
            split: outcome(.root(Self.main, .utility(.manageServers)), shows: .utility(.manageServers), back: nil, place: .utility(.manageServers))),
        Row(journey: "Usage → All Sessions in the host switcher", start: [(.serverJob(.usage, serverId: server), nil)],
            open: .serverJob(.inbox, serverId: server),
            stack: outcome(.replacingServerPages(Self.main), shows: .allSessions, back: nil),
            split: outcome(.root(Self.main, .allSessions), shows: .allSessions, back: nil)),
        Row(journey: "Usage → Usage in the host switcher", start: [(.serverJob(.usage, serverId: server), nil)],
            open: .serverJob(.usage, serverId: server),
            stack: outcome(.stay, shows: .utility(.manageServers), back: .allSessions),
            split: outcome(.stay, shows: .utility(.manageServers), back: nil, place: .utility(.manageServers))),
    ]

    @Test func everyOpenLandsWhereTheRuleSaysInTheStackShellTheSplitShellAndBesideASidePane() {
        for row in Self.rows {
            for layout in Layout.allCases {
                let expected = layout.presentation == .split ? row.split : row.stack
                let navigation = Self.navigation(in: layout)
                for (destination, origin) in row.start { navigation.open(destination, from: origin) }
                let sidePanes = navigation.panes.splitLeaves
                #expect(sidePanes.isEmpty == (layout != .splitShellBesideASidePane))

                let journey = "\(row.journey) in \(layout)"
                let placement = navigation.open(row.open, from: row.from, beside: row.beside)
                #expect(placement == expected.placement, "\(journey)")
                let shown = Self.shown(navigation)
                #expect(shown.last == expected.shows, "\(journey): \(shown)")
                #expect(navigation.currentPlace == expected.place, "\(journey): highlights \(navigation.currentPlace)")
                #expect(navigation.panes.splitLeaves == sidePanes, "\(journey): a main-pane open left the side panes alone")

                guard shown.count > 1 else {
                    #expect(expected.back == nil, "\(journey): nothing to go back from, \(shown)")
                    continue
                }
                navigation.popShownStack(toDepth: shown.count - 2)
                #expect(Self.shown(navigation).last == expected.back, "\(journey): Back shows \(Self.shown(navigation))")
            }
        }
    }

    /// Rotation never changes where Back goes: an open whose Back lands on the same screen in both
    /// shells still lands there after the window turned between the open and the Back.
    @Test func aRotationBetweenOpenAndBackKeepsWhereBackGoes() {
        let rows = Self.rows.filter { $0.stack.back != nil && $0.stack.back == $0.split.back && $0.stack.placement != .stay }
        #expect(rows.count >= 10)
        for row in rows {
            for (opening, back) in [(Layout.stackShell, Layout.splitShell), (.splitShell, .stackShell)] {
                let navigation = Self.navigation(in: opening)
                for (destination, origin) in row.start { navigation.open(destination, from: origin) }
                navigation.open(row.open, from: row.from)
                navigation.setWorkspaceNavigationPresentation(back.presentation)

                let journey = "\(row.journey), opened in \(opening), Back in \(back)"
                #expect(Self.shown(navigation).last == row.stack.shows, "\(journey): \(Self.shown(navigation))")
                navigation.popShownStack(toDepth: Self.shown(navigation).count - 2)
                #expect(Self.shown(navigation).last == row.stack.back, "\(journey): \(Self.shown(navigation))")
            }
        }
    }

    /// A locked destination does not open until its lock allows it; then the same open lands.
    @Test func aLockedDestinationOpensOnlyOnceItsLockAllows() {
        let serverId = "server-locked-\(UUID().uuidString)"
        let workspace = WorkspaceNavTarget(serverId: serverId, workspace: makeTestWorkspace(id: "workspace-locked"))
        let lock = ScopedLockTarget.workspace(serverId: serverId, workspaceId: "workspace-locked")
        ScopedLockService.shared.lock(lock.scope)
        defer { ScopedLockService.shared.forgetServer(serverId) }
        let navigation = Self.navigation(in: .stackShell)
        navigation.open(.chat(Self.chat))

        navigation.open(.place(.sessions(workspace)))
        #expect(navigation.workspaceStackRouteElements == [.session(Self.chat)], "a locked workspace opened")

        // What a successful device authentication records for this generation.
        ScopedLockService.shared.noteCreated(lock)
        navigation.open(.place(.sessions(workspace)))
        #expect(navigation.workspaceStackRouteElements == [.workspace(workspace)])
    }

    /// The chat's scoped lock and its routes read its workspace, which a row
    /// of a workspace's list knows when the session record does not.
    @Test func aChatOpenedFromAWorkspaceScreenBelongsToThatWorkspace() {
        let navigation = Self.navigation(in: .stackShell)
        navigation.open(.place(.sessions(Self.workspace)))

        navigation.open(
            .chat(WorkspaceSessionNavTarget(serverId: Self.server, sessionId: "unscoped")),
            from: .row(Self.main, workspace: Self.workspace)
        )

        guard case .session(let opened)? = navigation.workspaceStackRouteElements.last else {
            Issue.record("no chat on top: \(navigation.workspaceStackRouteElements)")
            return
        }
        #expect(opened.workspaceId == "workspace-1")
    }

    /// The window in `layout`, with a file in a side pane for `splitShellBesideASidePane`.
    private static func navigation(in layout: Layout) -> SceneNavigation {
        let navigation = SceneNavigation()
        navigation.app.launchPhase = .ready
        navigation.app.showOnboarding = false
        navigation.setWorkspaceNavigationPresentation(layout.presentation)
        if layout == .splitShellBesideASidePane {
            let panes = navigation.panes
            _ = panes.split(
                panes.mainLeafID, edge: .right,
                showing: .entry(PaneStackEntry(serverId: server, route: .file(.host, path: "notes/b.md", line: nil)))
            )
        }
        return navigation
    }

    /// What the main pane shows, root first, in either shell.
    private static func shown(_ navigation: SceneNavigation) -> [WorkspaceStackRouteElement] {
        navigation.mainPaneRoute.routes(split: navigation.workspaceNavigationPresentation == .split)
    }
}

/// Side content through the one entry, in a window with a pane host: a pane
/// already showing its kind (or a launcher) takes it in place of what it
/// showed, else a new pane opens beside the pane it came from, and a chat
/// never opens beside at all.
@Suite("Where side content lands")
@MainActor
struct PaneSideContentPlacementTests {
    private func host(width: CGFloat = 1133, height: CGFloat = 744) -> PaneTestHost {
        PaneTestHost(width: width, height: height, inNavigation: true)
    }

    private func file(_ path: String) -> NavigationDestination {
        .page(.entry(PaneStackEntry(serverId: "s", route: .file(.host, path: path, line: nil))))
    }

    @Test func aFileOpenedFromTheChatSplitsAPaneBesideItAndTheNextFillsThatPane() throws {
        let host = self.host()
        defer { host.hide() }
        let navigation = host.root.navigation
        let panes = host.scenePanes
        let chat = panes.mainLeafID

        navigation.open(file("/tmp/a.md"), from: .row(chat), beside: .file)
        let opened = try #require(panes.splitLeaves.first?.id, "a pane beside the chat")
        #expect(panes.stack(of: opened)?.top == .entry(PaneStackEntry(serverId: "s", route: .file(.host, path: "/tmp/a.md", line: nil))))
        #expect(host.panes.focusedCell == opened, "the file's pane has focus")

        navigation.open(file("/tmp/b.md"), from: .row(chat), beside: .file)
        #expect(panes.splitLeaves.map(\.id) == [opened], "the file's pane takes the next file")
        #expect(panes.stack(of: opened)?.top == .entry(PaneStackEntry(serverId: "s", route: .file(.host, path: "/tmp/b.md", line: nil))))
    }

    @Test func aChatNeverOpensBesideAndACompactWindowFallsBackToTheMainPane() throws {
        let host = self.host()
        defer { host.hide() }
        let navigation = host.root.navigation
        let panes = host.scenePanes

        let chat = WorkspaceSessionNavTarget(serverId: "s", sessionId: "s-1", workspaceId: "w")
        navigation.open(.chat(chat), from: .row(panes.mainLeafID), beside: .sessions)
        #expect(panes.splitLeaves.isEmpty, "a chat never opens beside")
        #expect(navigation.mainPaneRoute.top == .session(chat))

        navigation.open(file("/tmp/a.md"), from: .row(panes.mainLeafID), beside: .file)
        #expect(panes.splitLeaves.count == 1, "a file opens beside on a wide window")

        let compact = self.host(width: 400, height: 800)
        defer { compact.hide() }
        // A compact window keeps one pane: no room for one beside.
        compact.act {
            compact.window.traitOverrides.horizontalSizeClass = .compact
            compact.panes.updatePropertiesIfNeeded()
        }
        compact.root.navigation.open(file("/tmp/b.md"), from: .row(compact.scenePanes.mainLeafID), beside: .file)
        #expect(compact.scenePanes.splitLeaves.isEmpty, "a compact window has one pane")
        #expect(compact.root.navigation.mainPaneRoute.top == .entry(PaneStackEntry(serverId: "s", route: .file(.host, path: "/tmp/b.md", line: nil))))
    }

    /// The chat rule through the caller that names kinds: side content opened
    /// from a pane that lists a session lands in the main pane, never beside.
    @Test func sideContentThatNamesAChatOpensInTheMainPane() throws {
        let host = self.host()
        defer { host.hide() }
        let navigation = host.root.navigation
        let panes = host.scenePanes
        let listEntry = PaneStackEntry(serverId: "s", route: .files(workspace: "w", path: nil))
        let list = try #require(panes.split(panes.mainLeafID, edge: .right, showing: .entry(listEntry)))
        host.root.opener.followOrigin = .row(list)

        // A session link's pane content, named as the session list a row would
        // open it as.
        host.root.opener.openSideContent(PaneOpenContent(entry: PaneStackEntry(serverId: "s", route: .session("s-1"))), kind: .sessions)

        #expect(navigation.mainPaneRoute.top == .entry(PaneStackEntry(serverId: "s", route: .session("s-1"))),
                "the chat's page shows in the main pane")
        #expect(panes.stack(of: list)?.top == .entry(listEntry), "the side pane keeps its folder")
    }

    /// A list's row opens its chat in the pane the list is drawn in, over the
    /// list, and Back returns to it (Stage 4a). The main pane keeps what it
    /// showed: the list's own pane is where its chat belongs, and a session
    /// shows in one leaf.
    @Test func aListsRowOpensItsChatInThePaneTheListIsDrawnIn() throws {
        let host = self.host()
        defer { host.hide() }
        let navigation = host.root.navigation
        let panes = host.scenePanes
        let entry = PaneStackEntry(serverId: "s", route: .sessions(workspace: "w"))
        let list = try #require(panes.split(panes.mainLeafID, edge: .right, showing: .entry(entry)))

        let chat = WorkspaceSessionNavTarget(serverId: "s", sessionId: "s-1", workspaceId: "w")
        #expect(navigation.open(.chat(chat), from: .row(list)) == .push(list))
        #expect(panes.stack(of: list)?.stack == [.entry(entry), .session(chat)], "the chat opens over the list that stays under it")
        #expect(navigation.mainPaneRoute.top != .session(chat), "the pane the person was in keeps what it showed")
    }
}
