import Foundation
import Testing
import UIKit
@testable import Oppi

/// The one placement rule (`SceneNavigation.open(_:from:)`), as a table: every
/// kind of open, in each window layout, says where it goes, what then shows on
/// top of the main pane, where Back goes, and which place the sidebar (or the
/// drawer) highlights.
@Suite("Opening in the main pane")
@MainActor
struct MainPanePlacementTests {
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
        let placement: MainPanePlacement
        /// The main pane's top screen after the open.
        let shows: ShellRoute
        /// The top screen after Back; nil when the open left nothing to go back from.
        let back: ShellRoute?
        /// The place the sidebar or the drawer highlights after the open (`currentPlace`).
        let place: NavigationPlace
    }

    struct Row {
        let journey: String
        var start: [(NavigationDestination, MainPaneOrigin)] = []
        let open: NavigationDestination
        var from: MainPaneOrigin = .screen()
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
        _ placement: MainPanePlacement,
        shows: ShellRoute,
        back: ShellRoute?,
        place: NavigationPlace = .allSessions
    ) -> Outcome {
        Outcome(placement: placement, shows: shows, back: back, place: place)
    }

    static let rows: [Row] = [
        // Places.
        Row(journey: "a workspace's list → All Sessions", start: [(.place(.sessions(workspace)), .screen())],
            open: .place(.allSessions),
            stack: outcome(.root(.allSessions), shows: .inbox, back: nil),
            split: outcome(.root(.allSessions), shows: .inbox, back: nil)),
        Row(journey: "Agents → a workspace's list", start: [(.place(.utility(.agents)), .screen())],
            open: .place(.sessions(workspace)),
            stack: outcome(.root(inWorkspace), shows: .workspace(workspace), back: .inbox, place: inWorkspace),
            split: outcome(.root(inWorkspace), shows: .workspace(workspace), back: nil, place: inWorkspace)),
        // A place replaces the main pane's stack in both shells, opened from the sidebar, the drawer, a
        // link or a key; the stack shell keeps All Sessions under it.
        Row(journey: "a chat → Pinned", start: [(.chat(chat), .screen())],
            open: .place(.utility(.pinned)),
            stack: outcome(.root(.utility(.pinned)), shows: .utility(.pinned), back: .inbox, place: .utility(.pinned)),
            split: outcome(.root(.utility(.pinned)), shows: .utility(.pinned), back: nil, place: .utility(.pinned))),
        Row(journey: "a workspace's chat → oppi://pins",
            start: [(.place(.sessions(workspace)), .screen()), (.chat(chat), .screen(workspace: workspace))],
            open: .place(.utility(.pinned)), from: .external,
            stack: outcome(.root(.utility(.pinned)), shows: .utility(.pinned), back: .inbox, place: .utility(.pinned)),
            split: outcome(.root(.utility(.pinned)), shows: .utility(.pinned), back: nil, place: .utility(.pinned))),
        Row(journey: "a chat → Pinned → a pinned chat",
            start: [(.chat(chat), .screen()), (.place(.utility(.pinned)), .screen())],
            open: .chat(other),
            stack: outcome(.push, shows: .session(other), back: .utility(.pinned), place: .utility(.pinned)),
            split: outcome(.push, shows: .session(other), back: .utility(.pinned), place: .utility(.pinned))),

        // Chats from a list or a button.
        Row(journey: "All Sessions → chat",
            open: .chat(chat),
            stack: outcome(.push, shows: .session(chat), back: .inbox),
            split: outcome(.onPlace(.allSessions), shows: .session(chat), back: .inbox)),
        Row(journey: "a workspace's list → chat", start: [(.place(.sessions(workspace)), .screen())],
            open: .chat(chat), from: .screen(workspace: workspace),
            stack: outcome(.onPlace(inWorkspace), shows: .session(chat), back: .workspace(workspace), place: inWorkspace),
            split: outcome(.onPlace(inWorkspace), shows: .session(chat), back: .workspace(workspace), place: inWorkspace)),
        Row(journey: "Agents → chat", start: [(.place(.utility(.agents)), .screen())],
            open: .chat(chat),
            stack: outcome(.push, shows: .session(chat), back: .utility(.agents), place: .utility(.agents)),
            split: outcome(.push, shows: .session(chat), back: .utility(.agents), place: .utility(.agents))),
        Row(journey: "a chat's button → another chat", start: [(.chat(chat), .screen())],
            open: .chat(other),
            stack: outcome(.push, shows: .session(other), back: .session(chat)),
            split: outcome(.onPlace(.allSessions), shows: .session(other), back: .inbox)),
        Row(journey: "Quick Session at All Sessions → a chat in a workspace",
            open: .chat(chat), from: .screen(workspace: workspace),
            stack: outcome(.push, shows: .session(chat), back: .inbox),
            split: outcome(.onPlace(.allSessions), shows: .session(chat), back: .inbox)),
        Row(journey: "Quick Session at one workspace's list → a chat in another",
            start: [(.place(.sessions(otherWorkspace)), .screen())],
            open: .chat(chat), from: .screen(workspace: workspace),
            stack: outcome(.onPlace(inWorkspace), shows: .session(chat), back: .workspace(workspace), place: inWorkspace),
            split: outcome(.onPlace(inWorkspace), shows: .session(chat), back: .workspace(workspace), place: inWorkspace)),
        // Over All Sessions or a utility the stack shell pushes Quick Session's chat; the split
        // shell puts it on All Sessions, its column's place, or over the utility.
        Row(journey: "Quick Session over a chat at All Sessions → a chat in a workspace",
            start: [(.chat(other), .screen())],
            open: .chat(chat), from: .screen(workspace: workspace),
            stack: outcome(.push, shows: .session(chat), back: .session(other)),
            split: outcome(.onPlace(.allSessions), shows: .session(chat), back: .inbox)),
        Row(journey: "Quick Session from Agents → a chat in a workspace", start: [(.place(.utility(.agents)), .screen())],
            open: .chat(chat), from: .screen(workspace: workspace),
            stack: outcome(.push, shows: .session(chat), back: .utility(.agents), place: .utility(.agents)),
            split: outcome(.push, shows: .session(chat), back: .utility(.agents), place: .utility(.agents))),
        Row(journey: "Quick Session over a file → a chat in the file's workspace",
            start: [(.page(.linkedFile(file)), .screen())],
            open: .chat(chat), from: .screen(workspace: workspace),
            stack: outcome(.push, shows: .session(chat), back: .linkedFile(file)),
            split: outcome(.onPlace(.allSessions), shows: .session(chat), back: .inbox)),

        // Chats from a link.
        Row(journey: "a chat → a session link", start: [(.chat(chat), .screen())],
            open: .chat(other), from: .link,
            stack: outcome(.push, shows: .session(other), back: .session(chat)),
            split: outcome(.push, shows: .session(other), back: .session(chat))),
        Row(journey: "a chat → a link to itself", start: [(.chat(chat), .screen())],
            open: .chat(chat), from: .link,
            stack: outcome(.stay, shows: .session(chat), back: .inbox),
            split: outcome(.stay, shows: .session(chat), back: .inbox)),

        // Chats from outside the app.
        Row(journey: "Pinned → a notification's chat", start: [(.place(.utility(.pinned)), .screen())],
            open: .chat(chat), from: .external,
            stack: outcome(.onPlace(.allSessions), shows: .session(chat), back: .inbox),
            split: outcome(.onPlace(.allSessions), shows: .session(chat), back: .inbox)),
        Row(journey: "a workspace's chat → a notification's chat",
            start: [(.place(.sessions(workspace)), .screen()), (.chat(other), .screen(workspace: workspace))],
            open: .chat(chat), from: .external,
            stack: outcome(.onPlace(.allSessions), shows: .session(chat), back: .inbox),
            split: outcome(.onPlace(inWorkspace), shows: .session(chat), back: .workspace(workspace), place: inWorkspace)),

        // Pages.
        Row(journey: "a chat → a reader", start: [(.chat(chat), .screen())],
            open: .page(.chatReader(reader)),
            stack: outcome(.push, shows: .chatReader(reader), back: .session(chat)),
            split: outcome(.push, shows: .chatReader(reader), back: .session(chat))),
        Row(journey: "a workspace's list → Files", start: [(.place(.sessions(workspace)), .screen())],
            open: .page(.fileBrowser(folder)), from: .screen(workspace: workspace),
            stack: outcome(.push, shows: .fileBrowser(folder), back: .workspace(workspace), place: inWorkspace),
            split: outcome(.push, shows: .fileBrowser(folder), back: .workspace(workspace), place: inWorkspace)),
        Row(journey: "Pinned → a file", start: [(.place(.utility(.pinned)), .screen())],
            open: .page(.linkedFile(file)),
            stack: outcome(.push, shows: .linkedFile(file), back: .utility(.pinned), place: .utility(.pinned)),
            split: outcome(.push, shows: .linkedFile(file), back: .utility(.pinned), place: .utility(.pinned))),
        Row(journey: "a chat → a file link in it", start: [(.chat(chat), .screen())],
            open: .page(.linkedFile(file)), from: .link,
            stack: outcome(.push, shows: .linkedFile(file), back: .session(chat)),
            split: outcome(.push, shows: .linkedFile(file), back: .session(chat))),
        Row(journey: "a folder → the same folder", start: [(.page(.fileBrowser(folder)), .screen())],
            open: .page(.fileBrowser(folder)),
            stack: outcome(.stay, shows: .fileBrowser(folder), back: .inbox),
            split: outcome(.stay, shows: .fileBrowser(folder), back: .inbox)),
        Row(journey: "a workspace's list → Workspace Settings", start: [(.place(.sessions(workspace)), .screen())],
            open: .page(.workspaceConfiguration(workspace)),
            stack: outcome(.onPlace(inWorkspace), shows: .workspaceConfiguration(workspace), back: .workspace(workspace), place: inWorkspace),
            split: outcome(.onPlace(inWorkspace), shows: .workspaceConfiguration(workspace), back: .workspace(workspace), place: inWorkspace)),
        Row(journey: "Settings → Server Settings", start: [(.place(.utility(.appSettings)), .screen())],
            open: .page(.serverDetails(serverDetails)),
            stack: outcome(.push, shows: .serverDetails(serverDetails), back: .utility(.appSettings), place: .utility(.appSettings)),
            split: outcome(.push, shows: .serverDetails(serverDetails), back: .utility(.appSettings), place: .utility(.appSettings))),
        Row(journey: "a chat → a link to a server not paired", start: [(.chat(chat), .screen())],
            open: .page(.paneEntry(entry)), from: .external,
            stack: outcome(.push, shows: .paneEntry(entry), back: .session(chat)),
            split: outcome(.push, shows: .paneEntry(entry), back: .session(chat))),

        // Terminals: a page over its list or chat, which the window knows is there.
        Row(journey: "Rex → a session's terminal", start: [(.place(rex), .screen())],
            open: .page(.terminal(terminal)),
            stack: outcome(.push, shows: .terminal(terminal), back: .utility(.rex), place: rex),
            split: outcome(.push, shows: .terminal(terminal), back: .utility(.rex), place: rex)),
        Row(journey: "a chat → its folder terminal", start: [(.chat(chat), .screen())],
            open: .page(.terminal(terminal)),
            stack: outcome(.push, shows: .terminal(terminal), back: .session(chat)),
            split: outcome(.push, shows: .terminal(terminal), back: .session(chat))),
        // A chat replaces a terminal as it replaces any page: the shell lives on in the
        // terminal registry, reachable again from its list.
        Row(journey: "a terminal → a notification's chat",
            start: [(.place(terminals), .screen()), (.page(.terminal(terminal)), .screen())],
            open: .chat(chat), from: .external,
            stack: outcome(.onPlace(.allSessions), shows: .session(chat), back: .inbox),
            split: outcome(.onPlace(.allSessions), shows: .session(chat), back: .inbox)),
        Row(journey: "a terminal → All Sessions", start: [(.place(rex), .screen()), (.page(.terminal(terminal)), .screen())],
            open: .place(.allSessions),
            stack: outcome(.root(.allSessions), shows: .inbox, back: nil),
            split: outcome(.root(.allSessions), shows: .inbox, back: nil)),

        // The host switcher's jobs.
        Row(journey: "All Sessions → Server Settings in the host switcher",
            open: .serverJob(.serverSettings, serverId: server),
            stack: outcome(.replacingServerPages, shows: .serverDetails(serverDetails), back: .inbox),
            split: outcome(.onPlace(.allSessions), shows: .serverDetails(serverDetails), back: .inbox)),
        Row(journey: "a chat's Server Settings → Usage in the host switcher",
            start: [(.chat(chat), .screen()), (.serverJob(.serverSettings, serverId: server), .screen())],
            open: .serverJob(.usage, serverId: server),
            stack: outcome(.replacingServerPages, shows: .utility(.manageServers), back: .session(chat)),
            split: outcome(.root(.utility(.manageServers)), shows: .utility(.manageServers), back: nil, place: .utility(.manageServers))),
        Row(journey: "Usage → All Sessions in the host switcher", start: [(.serverJob(.usage, serverId: server), .screen())],
            open: .serverJob(.inbox, serverId: server),
            stack: outcome(.replacingServerPages, shows: .inbox, back: nil),
            split: outcome(.root(.allSessions), shows: .inbox, back: nil)),
        Row(journey: "Usage → Usage in the host switcher", start: [(.serverJob(.usage, serverId: server), .screen())],
            open: .serverJob(.usage, serverId: server),
            stack: outcome(.stay, shows: .utility(.manageServers), back: .inbox),
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
                let placement = navigation.mainPaneRoute.placement(of: row.open, from: row.from, split: layout.presentation == .split)
                #expect(placement == expected.placement, "\(journey)")
                navigation.open(row.open, from: row.from)
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
            from: .screen(workspace: Self.workspace)
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
            _ = panes.split(panes.mainLeafID, edge: .right, showing: PaneStackEntry(serverId: server, route: .file(.host, path: "notes/b.md", line: nil)))
        }
        return navigation
    }

    /// What the main pane shows, root first, in either shell.
    private static func shown(_ navigation: SceneNavigation) -> [ShellRoute] {
        navigation.mainPaneRoute.shellRoutes(split: navigation.workspaceNavigationPresentation == .split)
    }
}
