import Observation
import UIKit

/// Launch resolution phase — gates UI until credentials + cache are checked.
///
/// Prevents the flash of wrong content on cold launch (onboarding screen
/// briefly visible for paired users, empty workspace list before cache loads).
@MainActor
enum PairedLaunchSequence {
    static func revealThenPrepare<Prepared>(
        loadLocalState: () async -> Void,
        reveal: () -> Void,
        prepare: () async -> Prepared
    ) async -> Prepared {
        await loadLocalState()
        reveal()
        return await prepare()
    }
}

enum AppLaunchRoute: Equatable {
    /// Paired servers are not known yet: keep the blank launch canvas.
    case keepResolving
    case onboarding
    case pairedShell
}

enum AppLaunchPairingPolicy {
    /// Onboarding only after the pairing list was read and is empty. A store
    /// that could not read the Keychain (device locked) is not an empty one.
    static func route(loadState: ServerStore.LoadState, pairedServerCount: Int) -> AppLaunchRoute {
        guard loadState == .loaded else { return .keepResolving }
        return pairedServerCount == 0 ? .onboarding : .pairedShell
    }

    /// The server launch opens: the last active one (`LastActiveServer`)
    /// while it is still paired, else the first paired server.
    static func launchServer(lastActiveId: String?, servers: [PairedServer]) -> PairedServer? {
        servers.first { $0.id == lastActiveId } ?? servers.first
    }
}

enum AppLaunchPhase: Sendable, Equatable {
    /// Credential check + cache load in progress. UI shows blank canvas.
    case resolving
    /// Launch resolved. `showOnboarding` is authoritative.
    case ready
}

enum WorkspaceNavigationPresentation: Sendable, Equatable {
    case stack
    case split

    /// The split shell needs room both ways: regular width for two columns,
    /// regular height for the sidebar list, and a window at least as wide as
    /// it is tall. That covers iPad landscape and the iPhone Duo inner display
    /// in landscape (951×669pt). Compact width (Duo outer display, iPhone, iPad
    /// Slide Over), compact height (a large iPhone in landscape), and
    /// taller-than-wide windows keep the stack. No point threshold: the old
    /// 980pt floor was a device-size guess that excluded the Duo.
    static func resolve(
        horizontalSizeClass: UIUserInterfaceSizeClass,
        verticalSizeClass: UIUserInterfaceSizeClass,
        size: CGSize
    ) -> Self {
        guard horizontalSizeClass == .regular, verticalSizeClass == .regular else { return .stack }
        return size.width >= size.height ? .split : .stack
    }

    var telemetryLabel: String {
        switch self {
        case .stack: "stack"
        case .split: "split"
        }
    }
}

/// Which columns the split shell shows.
enum SplitColumnVisibility: Sendable, Equatable {
    /// UIKit decides from the window.
    case automatic
    /// The workspace sidebar beside the detail.
    case all
    /// The detail alone; the sidebar is hidden.
    case detailOnly
}

enum ServerResourceDetailKind: Hashable, Sendable {
    case `extension`
}

/// Server identity travels with every resource route so a server switch or
/// adaptive-layout transition can never issue a detail request to the wrong host.
struct ServerResourceDetailNavTarget: Hashable, Sendable {
    let serverId: String
    let kind: ServerResourceDetailKind
    let resourceId: String
}

/// One file of a Skill on one server (`ServerSkillFileViewController`), by Skill-relative path.
struct ServerSkillFileNavTarget: Hashable, Sendable {
    let serverId: String
    let resourceId: String
    let path: String
}

struct ServerDetailsNavTarget: Hashable, Sendable {
    let serverId: String
}

struct ModelProvidersNavTarget: Hashable, Sendable {
    let serverId: String
}

/// One pane leaf's route: its root place (nil for a side leaf, whose bottom
/// screen is its content), which the sidebar and drawer highlight on the main
/// leaf, and the screens opened over it. The split shell shows the place at its
/// detail root; the compact stack keeps All Sessions under it
/// (`routes(split:)`).
struct PaneStack: Equatable {
    var place: NavigationPlace?
    /// What opened on the place: content and its pages. On the compact
    /// stack the host switcher's Usage and Server Metrics are pages here too
    /// (`PanePlacement.replacingServerPages`).
    var stack: [WorkspaceStackRouteElement] = []

    /// The place's own screen (none for All Sessions), then the stack.
    var elements: [WorkspaceStackRouteElement] {
        (place?.screen.map { [$0] } ?? []) + stack
    }

    /// The screen on top.
    var top: WorkspaceStackRouteElement? { stack.last ?? place?.screen }

    /// What the leaf's stack shows, root first: its content alone for a side
    /// leaf, and the place's screen under the stack, with All Sessions under
    /// it on the compact stack.
    func routes(split: Bool) -> [WorkspaceStackRouteElement] {
        guard let place else { return stack }
        let root = place.screen ?? .allSessions
        guard !split, place != .allSessions else { return [root] + stack }
        return [.allSessions, root] + stack
    }

    /// Back to `depth` screens above the root of `routes(split:)`. On the
    /// compact stack, popping the place's own screen opens All Sessions.
    mutating func pop(toDepth depth: Int, split: Bool) {
        let placeLayer = split || place == nil || place == .allSessions ? 0 : 1
        guard depth < placeLayer + stack.count else { return }
        if depth < placeLayer {
            self = Self(place: .allSessions)
        } else {
            stack.removeLast(stack.count - (depth - placeLayer))
        }
    }

    /// Whether the sidebar shows beside the split shell's column, from the
    /// screen on top: hidden under a chat, a file, a terminal or a page of one, shown
    /// beside a list, a configuration, a utility or a server page.
    var visibility: SplitColumnVisibility {
        switch stack.last {
        case .session?, .fileBrowser?, .linkedFile?, .chatReader?, .entry?, .terminal?: .detailOnly
        default: .all
        }
    }

    /// A page of the server rather than of the window's work (the host
    /// switcher's destinations and an Extension's detail).
    var showsServerPage: Bool {
        switch top {
        case .serverDetails?, .modelProviders?, .serverResourceDetail?,
             .utility(.manageServers)?, .utility(.serverMetrics)?: true
        default: false
        }
    }
}

/// Where the window is: a sidebar row, whose screen is the main pane's root.
/// Content (a chat, a file, a page) opens on top of a place.
enum NavigationPlace: Hashable {
    /// All Sessions (nil), or one workspace's sessions.
    case sessions(WorkspaceNavTarget?)
    case utility(WorkspaceUtilityNavTarget)

    static let allSessions = Self.sessions(nil)
}

/// A screen of a leaf's route: a place's own screen (`NavigationPlace.screen`)
/// or one opened over it (`PaneStack.stack`). Every shell route is one of
/// these, so a leaf's stack is its route in both shells.
enum WorkspaceStackRouteElement: Hashable {
    /// All Sessions, under a place or a chat on the compact stack.
    case allSessions
    case workspace(WorkspaceNavTarget)
    case session(WorkspaceSessionNavTarget)
    case fileBrowser(FileBrowserNavTarget)
    case linkedFile(WorkspaceLinkedFileNavTarget)
    case chatReader(ChatReaderNavTarget)
    case workspaceConfiguration(WorkspaceNavTarget)
    case utility(WorkspaceUtilityNavTarget)
    case serverDetails(ServerDetailsNavTarget)
    case modelProviders(ModelProvidersNavTarget)
    case serverResourceDetail(ServerResourceDetailNavTarget)
    /// A screen no link names: a launcher, a browser's page, a game, Rex, a
    /// terminal, a workspace's Git, or a restored entry shown through its leaf
    /// state until its content can open.
    case entry(PaneStackEntry)
    /// A terminal: a live shell, or the screen that connects one.
    case terminal(TerminalNavTarget)
}

extension WorkspaceStackRouteElement {
    /// What a pane beside takes this screen as; nil for the window's own
    /// screens (a place, a chat, a settings page, a reader). A terminal is a
    /// kind of its own: a split of it opens the workspace's terminal.
    var contentKind: PaneContentKind? {
        switch self {
        case .fileBrowser: .folder
        case .linkedFile: .file
        case .entry(let entry): PaneContentKind(entry.route)
        case .terminal: .terminal
        default: nil
        }
    }

    /// Whether the screen is a chat: one shows in one pane, the window's main
    /// one, so it never opens beside.
    var isChat: Bool {
        switch self {
        case .session: true
        case .entry(let entry):
            switch entry.route {
            case .session, .panel, .read: true
            default: false
            }
        default: false
        }
    }

    /// The server and session of the chat this screen shows; nil for anything
    /// else. A panel or a reader of a chat is not the chat: a leaf that holds
    /// one has no chat of its own to show.
    var chatSession: (serverId: String, sessionId: String)? {
        switch self {
        case .session(let target):
            return (target.serverId, target.sessionId)
        case .entry(let entry):
            // A chat entry whose session its server has not listed yet is still
            // the chat's place in the leaf.
            guard case .session(let sessionId) = entry.route else { return nil }
            return (entry.serverId, sessionId)
        default:
            return nil
        }
    }

    /// Whether the screen is a New Pane launcher, the empty pane a kind fills.
    var isLauncher: Bool {
        if case .entry(let entry) = self, case .local(let token) = entry.route,
           case .launcher? = PaneLocalScreen(token) { return true }
        return false
    }
}

/// A terminal as a route: the live shell a connect flow reached (a host,
/// Rex or folder terminal), or the screen that connects one (a chat's folder
/// terminal, a Rex link's host list). Only its opener can make the screen,
/// so the target carries the opener's recipe and is equal only to itself;
/// it is never saved. The main pane's stack holds it like a chat, so the
/// window knows a terminal shows; a side pane builds it from its entry
/// (`ScenePanes.remember`) as it builds a file opened from a chat.
///
/// The screen is made once and kept while a stack shows it: a rotation or a
/// route change below moves the same screen (`ShellNavigationController`), so
/// the shell is never dialled again. A target asked again after its screen
/// went (Undo of a closed pane) makes a new one from the same recipe.
@MainActor
final class TerminalNavTarget: Hashable {
    private let make: () -> UIViewController
    private weak var made: UIViewController?
    /// The workspace the terminal works in, when its opener knows one (the
    /// chat bar's folder terminal): a split of its pane opens that
    /// workspace's own terminal. Nil for a Rex pane or a Rex link's list.
    let workspaceId: String?

    init(workspaceId: String? = nil, _ make: @escaping () -> UIViewController) {
        self.workspaceId = workspaceId
        self.make = make
    }

    var screen: UIViewController {
        if let made { return made }
        let screen = make()
        made = screen
        return screen
    }

    nonisolated static func == (lhs: TerminalNavTarget, rhs: TerminalNavTarget) -> Bool {
        lhs === rhs
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    /// Shows the terminal over `opener`: on the main pane's stack when
    /// `opener` is one of its routed screens or a page one of them pushed,
    /// else pushed in `opener`'s own stack (a side pane, a sheet).
    func show(from opener: UIViewController) {
        if let stack = opener.navigationController as? ShellNavigationController, stack.leaf == nil,
           let navigation = AppRootEnvironment.near(opener)?.navigation {
            navigation.open(.page(.terminal(self)))
        } else {
            Router.push(screen, from: opener)
        }
    }
}

struct WorkspaceStackDiagnosticContext: Equatable, Sendable {
    let screen: String
    let sessionId: String?
    let workspaceId: String?

    static let inboxAll = Self(
        screen: "workspace_inbox_all",
        sessionId: nil,
        workspaceId: nil
    )
}

/// One window's navigation: its route stack, shell, pane tree, Quick
/// Session, and server. What the whole app shares (launch, onboarding, What's
/// New, Live Voice) is `app`, the one `AppState` every window reads.
@MainActor @Observable
final class SceneNavigation {
    /// The app-wide state, shared by every window.
    @ObservationIgnored let app: AppState
    /// The window's pane tree beyond its routes: the companion, restoration.
    @ObservationIgnored let panes = ScenePanes()
    /// The window this navigation drives, set when its scene connects. What
    /// opens with no screen of its own (a link, a keyboard command) opens in
    /// its focused leaf (`Router.focusedScreen(in:)`), never another window's.
    @ObservationIgnored weak var window: UIWindow?
    /// The window's pane area, which draws and lays out its panes. The shell
    /// sets it as it makes the area, which moves between layouts but stays one
    /// host; side content opens through it (`PanePlacement.sideContent`).
    @ObservationIgnored weak var paneArea: PaneHostController?

    init(app: AppState = AppState()) {
        self.app = app
    }

    // MARK: - The window's server

    /// The server this window last chose: launch, its host switcher, an open
    /// that lands on another server's list. Nil until it chooses.
    private(set) var chosenServerId: String?

    /// The server this window shows: its sidebar, session lists, server pages
    /// and lock cover. Leaves keep their own route's server and connection,
    /// so a switch here never changes what an open chat, file or panel reads,
    /// and a chat from another server opening here does not move this. The
    /// coordinator's `activeServerId` is the transport focus, which any
    /// window or leaf moves, so a window reads it only before it has chosen.
    /// A window whose server was removed shows the first paired one, as the
    /// coordinator does.
    func activeServerId(in coordinator: ConnectionCoordinator) -> String? {
        guard let chosenServerId else { return coordinator.activeServerId }
        if coordinator.serverStore.server(for: chosenServerId) != nil { return chosenServerId }
        return coordinator.serverStore.servers.first?.id
    }

    /// Makes the paired `serverId` this window's server now; its transport
    /// prepares after (`prepareSelectedServerShell`) for callers that ask.
    /// False for a server that is not paired.
    @discardableResult
    func chooseServer(_ serverId: String, coordinator: ConnectionCoordinator) -> Bool {
        guard coordinator.restoreActiveServer(serverId) else { return false }
        recordChosenServer(serverId)
        return true
    }

    /// Makes `serverId` this window's server once its transport is ready.
    /// A superseded or failed preparation leaves the window where it was.
    func switchServerReady(
        _ serverId: String,
        coordinator: ConnectionCoordinator,
        shouldActivate: @escaping @MainActor () -> Bool = { true }
    ) async -> Bool {
        guard await coordinator.switchToServerReady(serverId, shouldActivate: shouldActivate) else { return false }
        recordChosenServer(serverId)
        return true
    }

    /// The window's choice, for a server the coordinator already made active
    /// (launch, a pairing).
    func recordChosenServer(_ serverId: String) {
        if chosenServerId != serverId { chosenServerId = serverId }
        app.serverChosen(serverId)
    }

    /// Which shell the window shows: the compact stack or the split view.
    /// Both show the one stack below; a change of shell converts nothing.
    var workspaceNavigationPresentation: WorkspaceNavigationPresentation = .stack

    /// The split shell's columns: what the detail column shows decides
    /// (`PaneStack.visibility`), unless the person showed or hid the
    /// sidebar themselves (its toggle, Toggle Sidebar, the system's sidebar
    /// gesture). Theirs is the answer for the screen they set it on, so Back
    /// to that screen keeps it and anything else derives its own; a change of
    /// shell drops it. Beside split panes a server page is the routed pane's
    /// content, so the sidebar stays out of the panes' room.
    var splitColumnVisibility: SplitColumnVisibility {
        get {
            guard isSplit else { return .automatic }
            if let sidebarChoice, sidebarChoice.route == mainPaneRoute { return sidebarChoice.visibility }
            if mainPaneRoute.showsServerPage, !panes.splitLeaves.isEmpty { return .detailOnly }
            return mainPaneRoute.visibility
        }
        set { sidebarChoice = SidebarChoice(route: mainPaneRoute, visibility: newValue) }
    }

    /// What the person last chose for one screen: showing or hiding the
    /// sidebar, and the route they were on.
    private struct SidebarChoice {
        let route: PaneStack
        let visibility: SplitColumnVisibility
    }

    /// The person's own show or hide of the sidebar, for the route it answers
    /// for (`SidebarChoice.route`).
    private var sidebarChoice: SidebarChoice?

    /// Session-list search lives on navigation so it survives a list's remount
    /// after Back or a change of shell. Each pane's list keeps its own, so a
    /// list in a side pane never shares the main pane's query.
    var sessionListSearch: [SessionListSearchKey: SessionListSearchNavigationPersistence.State] = [:]

    /// The search the list for `key` kept, and the one it keeps now.
    func search(of key: SessionListSearchKey) -> SessionListSearchNavigationPersistence.State {
        sessionListSearch[key] ?? .init()
    }

    func setSearch(_ state: SessionListSearchNavigationPersistence.State, of key: SessionListSearchKey) {
        sessionListSearch[key] = state
    }

    /// A pane keeps no list search: its own, when a list resets its host or
    /// leaves the window.
    func clearSearch(in pane: PaneID?) {
        let pane = pane ?? panes.mainLeafID
        for key in sessionListSearch.keys where key.pane == pane { sessionListSearch[key] = nil }
    }

    /// Set after a fresh pairing when the server had no workspaces.
    /// The workspace navigation shell consumes this to present guided creation.
    var shouldGuideWorkspaceCreation: Bool = false

    /// When set, the Quick Session sheet is presented over the current view.
    var showQuickSession: Bool = false

    /// Consume-once start of the presented Quick Session: target, mode, and initial
    /// content. Set by `presentQuickSession`; the sheet takes it as it sets up.
    var pendingQuickSessionStart: QuickSessionStart?

    /// True while native AVKit fullscreen is covering the workspace shell.
    private(set) var isMediaOverlayActive = false
    private var mediaOverlayDepth = 0
    private var mediaOverlaySnapshot: MediaOverlaySnapshot?
    private var isRestoringMediaOverlay = false
    /// A person's navigation ended the overlay's authority. A late AVKit end
    /// restores neither the chat route nor the server that navigation left.
    private var mediaOverlayEndedByUserNavigation = false

    /// The main leaf's route (`ScenePanes.stacks[mainLeafID]`). Only
    /// `open(_:from:)` and the owners of a route's own changes (a pop, a file
    /// browser's drill, restoration) write it; the person's own sidebar
    /// override answers only for the screen they set it on
    /// (`SidebarChoice.route`), and a change checks an active AVKit overlay's
    /// snapshot.
    var mainPaneRoute: PaneStack {
        get { panes.stacks[panes.mainLeafID] ?? PaneStack(place: .allSessions) }
        set {
            // A file browser's column drill rewrites its route in place; it
            // compares equal and is no navigation, but it is still the route.
            let changed = mainPaneRoute != newValue
            panes.setStack(newValue, for: panes.mainLeafID)
            guard changed, !isRestoringMediaOverlay else { return }
            restoreMediaOverlayRouteIfNeeded(
                snapshotCount: mediaOverlaySnapshot?.route.elements.count ?? 0,
                currentCount: workspaceStackRouteElements.count
            )
        }
    }

    /// The place's screen and the stack over it, bottom to top
    /// (`PaneStack.elements`).
    var workspaceStackRouteElements: [WorkspaceStackRouteElement] { mainPaneRoute.elements }

    /// A leaf's route; the main leaf's through `mainPaneRoute`, so the
    /// person's sidebar choice and an AVKit overlay follow a change there.
    func setRoute(_ route: PaneStack, in pane: PaneID) {
        if pane == panes.mainLeafID {
            mainPaneRoute = route
        } else {
            panes.setStack(route, for: pane)
        }
    }

    /// The place the main pane shows, which the sidebar and the drawer highlight.
    var currentPlace: NavigationPlace { mainPaneRoute.place ?? .allSessions }

    /// Whether a screen covers a session list in `pane` (the main leaf when
    /// nil), for its search: All Sessions (`workspaceId` nil) or a
    /// workspace's. The place's list is covered by anything opened on it; All
    /// Sessions also by any place on the compact stack, which keeps it
    /// underneath. A side leaf's list is its route's root, so nothing in the
    /// window's route covers it.
    func sessionListCovered(workspaceId: String?, in pane: PaneID? = nil) -> Bool {
        if let pane, pane != panes.mainLeafID { return false }
        if case .sessions(let shown) = currentPlace, shown?.workspace.id == workspaceId {
            return !mainPaneRoute.stack.isEmpty
        }
        return workspaceId == nil && !isSplit
    }

    var workspaceStackDiagnosticContext: WorkspaceStackDiagnosticContext {
        workspaceStackRouteElements.last.map(Self.diagnosticContext(for:)) ?? .inboxAll
    }

    var visibleSplitDiagnosticContext: WorkspaceStackDiagnosticContext {
        // Two chats can show in the split window, one pane each on two
        // servers: the focused pane's chat is the one the person is on.
        if panes.tree.focus != panes.mainLeafID, let top = panes.stack(of: panes.tree.focus)?.stack.last,
           case .session = top {
            return Self.diagnosticContext(for: top)
        }
        if let top = mainPaneRoute.stack.last { return Self.diagnosticContext(for: top) }
        switch currentPlace {
        case .utility(let utility):
            return Self.diagnosticContext(for: .utility(utility))
        case .sessions(let workspace?):
            return WorkspaceStackDiagnosticContext(
                screen: "workspace_split_inbox_filtered",
                sessionId: nil,
                workspaceId: workspace.workspace.id
            )
        case .sessions(nil):
            return WorkspaceStackDiagnosticContext(screen: "workspace_split_inbox_all", sessionId: nil, workspaceId: nil)
        }
    }

    /// The window changed shells. The stack stays as it is; the split
    /// sidebar starts from what the detail column shows.
    func setWorkspaceNavigationPresentation(
        _ presentation: WorkspaceNavigationPresentation,
        measurement: WorkspaceNavigationMeasurement? = nil
    ) {
        guard !isMediaOverlayActive else { return }
        guard workspaceNavigationPresentation != presentation else { return }
        let from = workspaceNavigationPresentation
        let fromSessionId = visibleDiagnosticSessionId()
        workspaceNavigationPresentation = presentation
        sidebarChoice = nil
        ClientLog.info(
            "Navigation",
            "Presentation changed",
            metadata: NavigationPresentationTelemetry.metadata(
                from: from.telemetryLabel,
                to: presentation.telemetryLabel,
                measurement: measurement,
                fromSessionId: fromSessionId,
                toSessionId: visibleDiagnosticSessionId()
            ),
            flush: true
        )
    }

    /// Shows or hides the split shell's sidebar column: the sidebar toggle's
    /// action, and the Toggle Sidebar keyboard command's.
    func toggleSplitSidebar() {
        splitColumnVisibility = splitColumnVisibility == .detailOnly ? .all : .detailOnly
    }

    /// Present Quick Session with `start` and record which control opened it, and
    /// whether a chat was the top view controller when it asked (a list bar's tap
    /// under a chat, or the intent path). The screen is captured before the flag
    /// flips, because the diagnostic label then becomes `quick_session`.
    func presentQuickSession(
        _ start: QuickSessionStart = QuickSessionStart(),
        from source: QuickSessionPresentationSource
    ) {
        guard !showQuickSession else { return }
        let screen = diagnosticScreenLabel()
        let presentation = workspaceNavigationPresentation.telemetryLabel
        let front = FrontScreens.current(in: window)
        pendingQuickSessionStart = start
        showQuickSession = true
        ClientLog.info(
            "Navigation",
            "Quick Session presented",
            metadata: [
                "source": source.rawValue,
                "mode": start.mode.rawValue,
                "screen": screen,
                "presentation": presentation,
                "chatOnTop": String(front.chatOnTop),
                "top": front.names,
            ],
            flush: true
        )
    }

    private var visibleDiagnosticContext: WorkspaceStackDiagnosticContext {
        switch workspaceNavigationPresentation {
        case .stack: workspaceStackDiagnosticContext
        case .split: visibleSplitDiagnosticContext
        }
    }

    func diagnosticScreenLabel() -> String {
        guard app.launchPhase == .ready else { return "launch_resolving" }
        if app.showOnboarding { return "onboarding" }
        if showQuickSession { return "quick_session" }
        return visibleDiagnosticContext.screen
    }

    func visibleDiagnosticSessionId() -> String? {
        visibleDiagnosticContext.sessionId
    }

    func visibleDiagnosticWorkspaceId() -> String? {
        visibleDiagnosticContext.workspaceId
    }

    /// The server of the chat the diagnostics name, when they name one: the
    /// focused pane's chat, else the main pane's. Two chats can show on two
    /// servers (Stage 4a), and the transport's active server is neither's.
    var visibleDiagnosticServerId: String? {
        if workspaceNavigationPresentation == .split, panes.tree.focus != panes.mainLeafID,
           let top = panes.stack(of: panes.tree.focus)?.stack.last, case .session(let chat) = top {
            return chat.serverId
        }
        guard case .session(let chat)? = mainPaneRoute.stack.last else { return nil }
        return chat.serverId
    }

    /// Stack depth counts the pushed stack routes. Split depth counts a
    /// utility root plus each push, so a detail push is a route change even
    /// when the screen token stays the same.
    var navigationRouteDepth: Int {
        switch workspaceNavigationPresentation {
        case .stack:
            workspaceStackRouteElements.count
        case .split:
            if case .utility = currentPlace { mainPaneRoute.stack.count + 1 } else { mainPaneRoute.stack.count }
        }
    }

    var navigationRouteSnapshot: NavigationRouteSnapshot {
        NavigationRouteSnapshot(
            screen: diagnosticScreenLabel(),
            stackDepth: navigationRouteDepth,
            presentation: workspaceNavigationPresentation.telemetryLabel,
            sessionId: visibleDiagnosticSessionId(),
            workspaceId: visibleDiagnosticWorkspaceId()
        )
    }

    /// Snapshot the visible workspace route and selected server before AVKit
    /// fullscreen threatens to clear the stack or flip compact/split shells.
    /// A routed-stack pop is the person's own navigation: it ends the overlay
    /// instead of restoring this snapshot. Only non-pop clears restore.
    func beginMediaOverlay(activeServerId: String?) {
        if mediaOverlayDepth == 0 {
            mediaOverlayEndedByUserNavigation = false
            mediaOverlaySnapshot = MediaOverlaySnapshot(
                presentation: workspaceNavigationPresentation,
                route: mainPaneRoute,
                activeServerId: activeServerId
            )
        }
        mediaOverlayDepth = WorkspaceMediaOverlayNavigationPolicy.overlayDepth(
            after: .begin,
            current: mediaOverlayDepth
        )
        isMediaOverlayActive = WorkspaceMediaOverlayNavigationPolicy.isOverlayActive(
            depth: mediaOverlayDepth
        )
    }

    /// Restore the snapshotted chat route. Returns the snapshotted server id
    /// when the focused server changed during the overlay.
    @discardableResult
    func endMediaOverlay(currentServerId: String?) -> String? {
        mediaOverlayDepth = WorkspaceMediaOverlayNavigationPolicy.overlayDepth(
            after: .end,
            current: mediaOverlayDepth
        )
        isMediaOverlayActive = WorkspaceMediaOverlayNavigationPolicy.isOverlayActive(
            depth: mediaOverlayDepth
        )
        guard !isMediaOverlayActive, let snapshot = mediaOverlaySnapshot else {
            return nil
        }
        mediaOverlaySnapshot = nil
        let endedByUserNavigation = mediaOverlayEndedByUserNavigation
        mediaOverlayEndedByUserNavigation = false
        // The person moved on during full screen (Back, the sidebar, another
        // server's chat): the snapshot's chat and server are both stale.
        guard !endedByUserNavigation else { return nil }
        restoreMediaOverlaySnapshot(snapshot)
        if WorkspaceMediaOverlayNavigationPolicy.shouldRestoreServer(
            snapshotServerId: snapshot.activeServerId,
            currentServerId: currentServerId
        ) {
            return snapshot.activeServerId
        }
        return nil
    }

    private var isSplit: Bool { workspaceNavigationPresentation == .split }

    /// If the deleted workspace is the current selection, leave it through the
    /// all-sessions inbox. Manage-list deletes of an unselected workspace stay put.
    func leaveDeletedWorkspace(serverId: String, workspaceId: String) {
        guard let selected = currentPlace.workspace,
              selected.serverId == serverId, selected.workspace.id == workspaceId else {
            return
        }
        open(.place(.allSessions))
    }

    /// Focuses the leaf that shows this chat and brings the chat back over the
    /// pages opened from it (D7: a session shows in one leaf). False when no
    /// leaf shows it.
    @discardableResult
    func focusShownChat(_ sessionId: String, serverId: String) -> Bool {
        guard let leaf = panes.leaf(showingChatOf: sessionId, serverId: serverId) else { return false }
        if let revealed = panes.stackShowingChat(sessionId, serverId: serverId) {
            setRoute(revealed.stack, in: revealed.leaf)
        }
        if let paneArea {
            paneArea.focus(cell: leaf)
        } else {
            panes.focus(leaf)
        }
        return true
    }

    /// Shows `chat` in `leaf` in place of the chat that leaf shows, and focuses
    /// it: one chat per server (Stage 4a), because that server's one connection,
    /// claim and stream show one chat. The leaf keeps everything under the old
    /// chat (the main leaf its place and any screens below the chat, a side
    /// leaf its list), so Back still returns there.
    @discardableResult
    func showChat(_ chat: WorkspaceSessionNavTarget, inServerLeaf leaf: PaneID) -> PanePlacement {
        setRoute(panes.stackReplacingChat(chat, in: leaf), in: leaf)
        if let paneArea {
            paneArea.syncSplitLeaves()
            paneArea.focus(cell: leaf)
        } else {
            panes.focus(leaf)
        }
        return .reuse(leaf)
    }

    /// A saved tree can hold two chats of one server (a build before this rule
    /// wrote it): the main leaf comes first, then each other leaf in tree
    /// order. The first leaf with a live chat of a server keeps it; each later
    /// leaf gives its chat of that server — and any pages pushed above that
    /// chat — up for what was under it, closing when that was all it showed.
    func repairChatsPerServer() {
        let leafIDs = [panes.mainLeafID] + panes.tree.leaves.map(\.id).filter { $0 != panes.mainLeafID }
        var claimedServers: Set<String> = []
        for id in leafIDs {
            guard var route = panes.stack(of: id) else { continue }
            var leafServers: Set<String> = []
            var removing = false
            var kept: [WorkspaceStackRouteElement] = []
            for element in route.stack {
                // Only a live chat takes its server (see `otherChatLeaf`).
                // Pages pushed above a removed duplicate chat go with it, up to
                // any later session screen.
                if case .session(let chat) = element {
                    removing = claimedServers.contains(chat.serverId)
                    if !removing { leafServers.insert(chat.serverId) }
                } else if case .entry(let entry) = element, case .session = entry.route {
                    removing = false
                }
                if !removing { kept.append(element) }
            }
            claimedServers.formUnion(leafServers)
            guard kept.count != route.stack.count else { continue }
            guard !kept.isEmpty || id == panes.mainLeafID else {
                panes.close(id, undoable: false)
                continue
            }
            route.stack = kept
            setRoute(route, in: id)
        }
    }

    nonisolated static func isSameSession(
        _ lhs: WorkspaceSessionNavTarget,
        _ rhs: WorkspaceSessionNavTarget
    ) -> Bool {
        lhs.serverId == rhs.serverId && lhs.sessionId == rhs.sessionId
    }

    enum ChatCoveringRouteElement {
        case session(String)
        case coveringPage(sourceSessionId: String?)
        case other
    }

    static func coveringElement(from element: WorkspaceStackRouteElement) -> ChatCoveringRouteElement {
        switch element {
        case .session(let target):
            return .session(target.sessionId)
        case .chatReader:
            return .coveringPage(sourceSessionId: nil)
        case .linkedFile(let target):
            return .coveringPage(sourceSessionId: coveringSourceSessionId(for: target))
        case .allSessions, .workspace, .fileBrowser, .workspaceConfiguration, .utility,
             .serverDetails, .modelProviders, .serverResourceDetail, .entry, .terminal:
            return .other
        }
    }

    private static func coveringSourceSessionId(for target: WorkspaceLinkedFileNavTarget) -> String? {
        if let sourceSessionId = target.sourceSessionId, !sourceSessionId.isEmpty {
            return sourceSessionId
        }
        if case .sessionFile(_, _, let sessionId) = target.kind {
            return sessionId
        }
        return nil
    }

    /// Whether a leaf's route still shows this reader: a reader opened from a
    /// chat opens in that chat's pane, which can be any leaf.
    func containsChatReader(_ target: ChatReaderNavTarget) -> Bool {
        panes.stacks.values.contains { stack in
            stack.stack.contains { element in
                if case .chatReader(let stacked) = element { return stacked == target }
                return false
            }
        }
    }

    /// True when this session is still under a pushed reader or same-session
    /// linked file. ChatViewController uses this to skip teardown on a covering disappear.
    func isCoveringChat(sessionId: String) -> Bool {
        var skippedCover = false
        for element in mainPaneRoute.stack.map(Self.coveringElement(from:)).reversed() {
            switch element {
            case .coveringPage(let sourceSessionId):
                if let sourceSessionId, sourceSessionId != sessionId {
                    return false
                }
                skippedCover = true
            case .session(let stackedSessionId) where stackedSessionId == sessionId:
                return skippedCover
            case .session, .other:
                return false
            }
        }
        return false
    }

    /// True while any of the window's leaves still holds this session's chat,
    /// under anything pushed above it. False once it was popped or replaced.
    /// The routes are the source of truth; UIKit's moving flags miss a shell
    /// route swap and see a lock-cover swap as a removal.
    func routeContainsSession(_ sessionId: String) -> Bool {
        panes.stacks.values.contains { stack in
            stack.elements.contains { element in
                if case .session(let target) = element { return target.sessionId == sessionId }
                return false
            }
        }
    }

    /// Keeps a column drill on the file-browser route so a shell change
    /// rebuilds that folder and file. Identity stays the original path.
    func recordFileBrowserColumn(
        serverId: String,
        scope: FileBrowserScope,
        routePath: String,
        directoryPath: String,
        selectedFile: FileBrowserSelection?,
        in pane: PaneID? = nil
    ) {
        let target = pane ?? panes.mainLeafID
        guard var route = panes.stack(of: target),
              let index = route.stack.lastIndex(where: { element in
                  if case .fileBrowser(let page) = element {
                      return page.serverId == serverId && page.scope == scope && page.path == routePath
                  }
                  return false
              }), case .fileBrowser(var page) = route.stack[index] else { return }
        page.columnDirectoryPath = directoryPath
        page.columnSelectedFile = selectedFile
        route.stack[index] = .fileBrowser(page)
        setRoute(route, in: target)
    }

    var visibleHostSwitcherDestination: HostSwitcherDestination {
        mainPaneRoute.hostSwitcherDestination
    }

    nonisolated static func hostSwitcherDestination(
        from element: WorkspaceStackRouteElement?
    ) -> HostSwitcherDestination? {
        switch element {
        case .utility(.manageServers): .usage
        case .utility(.serverMetrics): .serverMetrics
        case .serverDetails: .serverSettings
        case .modelProviders: .modelProviders
        default: nil
        }
    }

    /// Pending workspace creation deep-link payload.
    /// The workspace navigation shell consumes this once and clears it.
    var pendingWorkspaceDeepLink: WorkspaceDeepLink.Payload?

    /// A thread link's target: All Sessions opens this thread in place and scrolls to its root,
    /// once. The list consumes it and clears it.
    struct ThreadFocus: Equatable, Sendable {
        let serverId: String
        /// The thread's root session, which the list shows as a row.
        let rootId: String
    }

    var pendingThreadFocus: ThreadFocus?

    /// Shows All Sessions (the matching list in a split layout) with the thread of `rootId` open.
    func showThread(serverId: String, rootId: String, from origin: OpenOrigin? = nil) {
        open(.place(.allSessions), from: origin)
        pendingThreadFocus = ThreadFocus(serverId: serverId, rootId: rootId)
    }

    // MARK: - Quick Session Handoff
    //
    // These properties form a produce-once / consume-once handoff between
    // QuickSessionModel (producer) and QuickSessionPresentation + ChatViewController
    // (consumers).
    //
    // Flow:
    // 1. QuickSessionModel sets `pendingQuickSessionNav` (atomic intent)
    // 2. QuickSessionModel dismisses Quick Session
    // 3. QuickSessionPresentation's dismiss reads nav, extracts message/images, opens the session
    // 4. ChatViewController reads message/images on appear, auto-sends

    /// Atomic navigation intent from QuickSessionModel.
    /// Bundles target workspace, session ID, and optional auto-send data.
    /// Set before dismiss; consumed when QuickSessionPresentation dismisses Quick Session.
    var pendingQuickSessionNav: QuickSessionNav?

    /// Message to auto-send when the quick session's ChatViewController opens.
    /// Extracted from `pendingQuickSessionNav` when Quick Session dismisses.
    /// Consumed once by ChatViewController, then cleared.
    var pendingQuickSessionMessage: String?

    /// Attachments to auto-send when the quick session message opens.
    /// Extracted from `pendingQuickSessionNav` when Quick Session dismisses.
    var pendingQuickSessionAttachments: [PendingAttachment]?

    /// A file browser's breadcrumb went above the folder its pages start at
    /// (a link opened it deeper): the first of the browser's pages on top of
    /// the stack shows `target`, and the folder pages above it close.
    func showFileBrowserAncestor(_ target: FileBrowserNavTarget) {
        let stack = mainPaneRoute.stack
        var first = stack.endIndex
        while first > stack.startIndex,
              case .fileBrowser(let page) = stack[first - 1],
              page.serverId == target.serverId, page.scope == target.scope {
            first -= 1
        }
        guard first < stack.endIndex else { return }
        mainPaneRoute.stack.replaceSubrange(first..., with: [.fileBrowser(target)])
    }

    /// The person's own Back while the media overlay is active proves it is
    /// over even when AVKit never calls its end. End it here and let the pop
    /// stand; the route snapshot otherwise pushes the chat back under every
    /// Back, which looks like a stuck back stack. A non-navigation clear (a
    /// server or lock reset) still restores through
    /// `restoreMediaOverlayRouteIfNeeded`.
    func mediaOverlayYieldsToUserNavigation() {
        guard isMediaOverlayActive else { return }
        mediaOverlayDepth = 0
        isMediaOverlayActive = false
        mediaOverlayEndedByUserNavigation = true
    }

    /// The person popped the main pane back to `depth` screens above its place.
    func popShownStack(toDepth depth: Int) {
        var route = mainPaneRoute
        route.pop(toDepth: depth, split: isSplit)
        guard route != mainPaneRoute else { return }
        mediaOverlayYieldsToUserNavigation()
        mainPaneRoute = route
    }

    /// The all-sessions list with nothing pushed over it (compact stack or split detail).
    var showsAllSessionsRoot: Bool { mainPaneRoute == PaneStack(place: .allSessions) }

    private static func diagnosticContext(
        for element: WorkspaceStackRouteElement
    ) -> WorkspaceStackDiagnosticContext {
        switch element {
        case .allSessions: WorkspaceStackDiagnosticContext(screen: "workspace_inbox_all", sessionId: nil, workspaceId: nil)
        case .workspace(let target): workspaceInboxDiagnosticContext(target)
        case .session(let target): sessionDiagnosticContext(target)
        case .fileBrowser(let target): fileBrowserDiagnosticContext(target)
        case .linkedFile(let target): linkedFileDiagnosticContext(target)
        case .chatReader: chatReaderDiagnosticContext
        case .workspaceConfiguration(let target): workspaceConfigurationDiagnosticContext(target)
        case .utility(let target): utilityDiagnosticContext(target)
        case .serverDetails: serverDetailsDiagnosticContext
        case .modelProviders: modelProvidersDiagnosticContext
        case .serverResourceDetail: serverResourceDetailDiagnosticContext
        case .terminal: terminalDiagnosticContext
        case .entry(let entry): paneEntryDiagnosticContext(entry)
        }
    }

    private static func workspaceInboxDiagnosticContext(
        _ target: WorkspaceNavTarget
    ) -> WorkspaceStackDiagnosticContext {
        WorkspaceStackDiagnosticContext(
            screen: "workspace_inbox_filtered",
            sessionId: nil,
            workspaceId: target.workspace.id
        )
    }

    private static func sessionDiagnosticContext(
        _ target: WorkspaceSessionNavTarget
    ) -> WorkspaceStackDiagnosticContext {
        WorkspaceStackDiagnosticContext(
            screen: "chat",
            sessionId: target.sessionId,
            workspaceId: target.workspaceId
        )
    }

    private static func fileBrowserDiagnosticContext(
        _ target: FileBrowserNavTarget
    ) -> WorkspaceStackDiagnosticContext {
        WorkspaceStackDiagnosticContext(
            screen: "file_browser",
            sessionId: nil,
            workspaceId: target.workspaceId
        )
    }

    private static func linkedFileDiagnosticContext(
        _ target: WorkspaceLinkedFileNavTarget
    ) -> WorkspaceStackDiagnosticContext {
        WorkspaceStackDiagnosticContext(
            screen: "linked_file",
            sessionId: nil,
            workspaceId: target.workspaceId
        )
    }

    private static let chatReaderDiagnosticContext = WorkspaceStackDiagnosticContext(
        screen: "chat_reader",
        sessionId: nil,
        workspaceId: nil
    )

    private static func workspaceConfigurationDiagnosticContext(
        _ target: WorkspaceNavTarget
    ) -> WorkspaceStackDiagnosticContext {
        WorkspaceStackDiagnosticContext(
            screen: "workspace_configuration",
            sessionId: nil,
            workspaceId: target.workspace.id
        )
    }

    private static func utilityDiagnosticContext(
        _ target: WorkspaceUtilityNavTarget
    ) -> WorkspaceStackDiagnosticContext {
        let label = switch target {
        case .pinned: "pinned"
        case .schedules: "schedules"
        case .agents: "agents"
        case .extensions: "extensions"
        case .pluginScreen: "plugin_screen"
        case .sshTerminal: "ssh_terminal"
        case .rex: "rex"
        case .manageServers: "manage_servers"
        case .serverMetrics: "server_metrics"
        case .appSettings: "app_settings"
        }
        return WorkspaceStackDiagnosticContext(
            screen: "utility_\(label)",
            sessionId: nil,
            workspaceId: nil
        )
    }

    private static let terminalDiagnosticContext = WorkspaceStackDiagnosticContext(
        screen: "terminal",
        sessionId: nil,
        workspaceId: nil
    )

    private static let serverResourceDetailDiagnosticContext = WorkspaceStackDiagnosticContext(
        screen: "server_extension_detail",
        sessionId: nil,
        workspaceId: nil
    )

    private static let serverDetailsDiagnosticContext = WorkspaceStackDiagnosticContext(
        screen: "server_details",
        sessionId: nil,
        workspaceId: nil
    )

    private static let modelProvidersDiagnosticContext = WorkspaceStackDiagnosticContext(
        screen: "model_providers",
        sessionId: nil,
        workspaceId: nil
    )

    @discardableResult
    private func restoreMediaOverlayRouteIfNeeded(
        snapshotCount: Int,
        currentCount: Int
    ) -> Bool {
        guard let snapshot = mediaOverlaySnapshot,
              WorkspaceMediaOverlayNavigationPolicy.shouldRestoreRoute(
                  overlayActive: isMediaOverlayActive,
                  snapshotPathCount: snapshotCount,
                  currentPathCount: currentCount
              ) else {
            return false
        }
        restoreMediaOverlaySnapshot(snapshot)
        return true
    }

    private func restoreMediaOverlaySnapshot(_ snapshot: MediaOverlaySnapshot) {
        isRestoringMediaOverlay = true
        workspaceNavigationPresentation = snapshot.presentation
        mainPaneRoute = snapshot.route
        isRestoringMediaOverlay = false
    }

    private struct MediaOverlaySnapshot {
        let presentation: WorkspaceNavigationPresentation
        let route: PaneStack
        let activeServerId: String?
    }
}

/// Which session list keeps a search: the pane it is drawn in, and the
/// workspace it lists (nil for All Sessions).
struct SessionListSearchKey: Hashable {
    let pane: PaneID
    let workspaceId: String?
}

struct QuickSessionLaunchContext: Equatable, Sendable {
    let serverId: String
    let agentId: String?
    let workspaceId: String?
    let worktreeId: String?

    /// A missing workspace follows last-used / default on `serverId`; a missing Agent
    /// follows Quick Session's remembered pick.
    init(
        serverId: String,
        agentId: String? = nil,
        workspaceId: String? = nil,
        worktreeId: String? = nil
    ) {
        self.serverId = serverId
        self.agentId = agentId
        self.workspaceId = workspaceId
        self.worktreeId = worktreeId
    }
}

/// Atomic navigation intent for quick session deep-link.
///
/// Bundles everything needed to navigate to a session and optionally
/// auto-send a message. Set as a single write by QuickSessionModel,
/// consumed as a single read when Quick Session dismisses.
struct QuickSessionNav {
    let target: WorkspaceNavTarget
    let sessionId: String
    let autoSendMessage: String?
    let autoSendAttachments: [PendingAttachment]?
    /// Start Live Voice on the new session once its chat opens.
    let startsLiveVoice: Bool

    init(
        target: WorkspaceNavTarget,
        sessionId: String,
        autoSendMessage: String? = nil,
        autoSendAttachments: [PendingAttachment]? = nil,
        startsLiveVoice: Bool = false
    ) {
        self.target = target
        self.sessionId = sessionId
        self.autoSendMessage = autoSendMessage
        self.autoSendAttachments = autoSendAttachments
        self.startsLiveVoice = startsLiveVoice
    }
}

extension UIViewController {
    /// The pane this screen's route is drawn in: its leaf's stack, or nil for
    /// the window's own stack (the main pane, the split detail, the sidebar).
    var paneLeaf: PaneID? { (navigationController as? RoutedScreenStack)?.leaf }
}
