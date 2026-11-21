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

enum SessionNavigationSource: Sendable, Equatable {
    /// Incoming app URL, Live Activity, or notification: replace the visible route.
    case externalURL
    /// User tapped a session hyperlink inside the app: preserve the current back stack.
    case inAppHyperlink
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

/// What the split shell's detail column shows of the window's one stack
/// (`SceneNavigation.workspaceStackRouteElements`): the place at its root and
/// everything above the place pushed over it, as the compact stack pushes it
/// over All Sessions, so Back returns to the same screen in both shells. The
/// place is the stack's last sidebar place (a workspace's sessions or a
/// utility), else All Sessions. Each pushed screen keeps the stack index it
/// came from, so a pop in the column cuts the stack at the same screen.
struct SplitDetailColumn: Equatable {
    var root: ShellRoute
    /// The stack index of the root's screen; nil when the root is a list.
    var rootIndex: Int?
    var pushed: [(route: ShellRoute, index: Int)]

    var routes: [ShellRoute] { [root] + pushed.map(\.route) }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.root == rhs.root && lhs.rootIndex == rhs.rootIndex
            && lhs.pushed.map(\.route) == rhs.pushed.map(\.route) && lhs.pushed.map(\.index) == rhs.pushed.map(\.index)
    }

    init(stack: [WorkspaceStackRouteElement]) {
        let place = stack.lastIndex { element in
            switch element {
            case .workspace, .utility: true
            default: false
            }
        }
        root = place.map { ShellRoute(stack[$0]) } ?? .inbox
        rootIndex = place.flatMap { if case .utility = stack[$0] { $0 } else { nil } }
        pushed = stack.indices.dropFirst(place.map { $0 + 1 } ?? 0).map { (ShellRoute(stack[$0]), $0) }
    }

    /// Whether the sidebar shows beside this column, from the screen on top:
    /// hidden under a chat, a file or a page of one, shown beside a list, a
    /// configuration, a utility or a server page.
    var visibility: SplitColumnVisibility {
        switch routes.last ?? root {
        case .session, .fileBrowser, .linkedFile, .chatReader, .paneEntry: .detailOnly
        default: .all
        }
    }

    /// A page of the server rather than of the window's work (the host
    /// switcher's destinations and an Extension's detail).
    var showsServerPage: Bool {
        switch routes.last ?? root {
        case .serverDetails, .modelProviders, .serverResourceDetail,
             .utility(.manageServers), .utility(.serverMetrics): true
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

/// A screen of the window's stack. The compact shell shows each above All
/// Sessions; the split shell shows them above their place (`SplitDetailColumn`).
enum WorkspaceStackRouteElement: Hashable {
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
    /// A restored or linked pane entry shown through its leaf state.
    case paneEntry(PaneStackEntry)
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

    /// The workspace whose sessions the window lists: the split sidebar's
    /// selection, and the compact stack's workspace layer. Nil means All
    /// Sessions for the active server.
    var selectedWorkspaceFilter: WorkspaceNavTarget?

    /// The split shell's columns: what the detail column shows decides
    /// (`SplitDetailColumn.visibility`), unless the person showed or hid the
    /// sidebar themselves (its toggle, Toggle Sidebar, the system's sidebar
    /// gesture). Theirs holds until they go somewhere else: any change of the
    /// stack, or of shell, drops it. Beside split panes a server page is the
    /// routed pane's content, so the sidebar stays out of the panes' room.
    var splitColumnVisibility: SplitColumnVisibility {
        get {
            guard isSplit else { return .automatic }
            if let sidebarChoice { return sidebarChoice }
            let column = splitDetailColumn
            if column.showsServerPage, !panes.splitLeaves.isEmpty { return .detailOnly }
            return column.visibility
        }
        set { sidebarChoice = newValue }
    }

    /// The person's own show or hide of the sidebar, until they navigate.
    private var sidebarChoice: SplitColumnVisibility?

    /// Session-list search lives on navigation so it survives a list's
    /// remount after Back or a change of shell.
    var inboxSessionSearch = SessionListSearchNavigationPersistence.State()
    var workspaceSessionSearchByID: [String: SessionListSearchNavigationPersistence.State] = [:]

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

    /// The window's screens above All Sessions, bottom to top: the primary
    /// leaf's stack. The compact shell shows exactly these; the split shell
    /// shows the workspace layer as its sidebar selection and the rest in its
    /// detail column (`splitDetailColumn`).
    var workspaceStackRouteElements: [WorkspaceStackRouteElement] = [] {
        didSet {
            if isRestoringMediaOverlay { return }
            // A file browser's column drill rewrites its route in place; it
            // compares equal and is no navigation.
            if oldValue != workspaceStackRouteElements { sidebarChoice = nil }
            if restoreMediaOverlayRouteIfNeeded(
                snapshotCount: mediaOverlaySnapshot?.workspaceStackRouteElements.count ?? 0,
                currentCount: workspaceStackRouteElements.count
            ) {
                return
            }
            if workspaceNavigationPresentation == .stack, workspaceStackRouteElements.isEmpty {
                selectedWorkspaceFilter = nil
            }
        }
    }

    /// The place the window shows, which the sidebar highlights: the split column's
    /// root, or the compact stack's sessions.
    var currentPlace: NavigationPlace {
        guard isSplit else { return .sessions(selectedWorkspaceFilter) }
        switch splitDetailColumn.root {
        case .utility(let utility): return .utility(utility)
        case .workspace(let workspace): return .sessions(workspace)
        default: return .allSessions
        }
    }

    /// The split shell's detail column, read from the stack.
    var splitDetailColumn: SplitDetailColumn {
        SplitDetailColumn(stack: workspaceStackRouteElements)
    }

    /// What covers a session list, for its search: the screens over it on
    /// the compact stack (none in the split shell, where the list sits at the
    /// detail column's root), and whether a screen is pushed over the split's list.
    var sessionListCover: (stackDepth: Int, splitListCovered: Bool) {
        isSplit ? (0, !splitDetailColumn.pushed.isEmpty) : (workspaceStackRouteElements.count, false)
    }

    var workspaceStackDiagnosticContext: WorkspaceStackDiagnosticContext {
        workspaceStackRouteElements.last.map(Self.diagnosticContext(for:)) ?? .inboxAll
    }

    var visibleSplitDiagnosticContext: WorkspaceStackDiagnosticContext {
        let column = splitDetailColumn
        if let index = column.pushed.last?.index ?? column.rootIndex {
            return Self.diagnosticContext(for: workspaceStackRouteElements[index])
        }
        guard case .workspace(let workspace) = column.root else {
            return WorkspaceStackDiagnosticContext(screen: "workspace_split_inbox_all", sessionId: nil, workspaceId: nil)
        }
        return WorkspaceStackDiagnosticContext(
            screen: "workspace_split_inbox_filtered",
            sessionId: nil,
            workspaceId: workspace.workspace.id
        )
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
        // The compact stack lists the workspace only as a pushed layer.
        if presentation == .stack, selectedWorkspaceFilter != nil, workspaceStackRouteElements.isEmpty {
            selectedWorkspaceFilter = nil
        }
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

    /// Stack depth counts the pushed stack routes. Split depth counts the
    /// detail root plus each push, so a detail push is a route change even
    /// when the screen token stays the same.
    var navigationRouteDepth: Int {
        switch workspaceNavigationPresentation {
        case .stack:
            workspaceStackRouteElements.count
        case .split:
            splitDetailColumn.pushed.count + (splitDetailColumn.rootIndex == nil ? 0 : 1)
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
                selectedWorkspaceFilter: selectedWorkspaceFilter,
                workspaceStackRouteElements: workspaceStackRouteElements,
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
        guard let selected = selectedWorkspaceFilter,
              selected.serverId == serverId, selected.workspace.id == workspaceId else {
            return
        }
        open(.place(.allSessions))
    }

    /// The session whose chat is the visible screen: the stack's top.
    var visibleChatSession: WorkspaceSessionNavTarget? {
        guard case .session(let current)? = workspaceStackRouteElements.last else { return nil }
        return current
    }

    static func isSameSession(
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
        case .workspace, .fileBrowser, .workspaceConfiguration, .utility,
             .serverDetails, .modelProviders, .serverResourceDetail, .paneEntry:
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

    /// The stack's screens the shell shows: all of them on the compact
    /// stack, the detail column's in the split shell.
    private var shownElements: [WorkspaceStackRouteElement] {
        guard isSplit else { return workspaceStackRouteElements }
        let column = splitDetailColumn
        let indices = (column.rootIndex.map { [$0] } ?? []) + column.pushed.map(\.index)
        return indices.map { workspaceStackRouteElements[$0] }
    }

    func containsChatReader(_ target: ChatReaderNavTarget) -> Bool {
        shownElements.contains { element in
            if case .chatReader(let stacked) = element { return stacked == target }
            return false
        }
    }

    /// True when this session is still under a pushed reader or same-session
    /// linked file. ChatViewController uses this to skip teardown on a covering disappear.
    func isCoveringChat(sessionId: String) -> Bool {
        var skippedCover = false
        for element in shownElements.map(Self.coveringElement(from:)).reversed() {
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

    /// True while the workspace route still holds this session's chat, under
    /// anything pushed above it. False once it was popped or replaced. The
    /// route is the source of truth; UIKit's moving flags miss a shell route
    /// swap and see a lock-cover swap as a removal.
    func routeContainsSession(_ sessionId: String) -> Bool {
        shownElements.contains { element in
            if case .session(let target) = element { return target.sessionId == sessionId }
            return false
        }
    }

    /// Keeps a column drill on the file-browser route so a shell change
    /// rebuilds that folder and file. Identity stays the original path.
    func recordFileBrowserColumn(
        serverId: String,
        scope: FileBrowserScope,
        routePath: String,
        directoryPath: String,
        selectedFile: FileBrowserSelection?
    ) {
        guard let index = workspaceStackRouteElements.lastIndex(where: { element in
            if case .fileBrowser(let target) = element {
                return target.serverId == serverId && target.scope == scope && target.path == routePath
            }
            return false
        }), case .fileBrowser(var target) = workspaceStackRouteElements[index] else { return }
        target.columnDirectoryPath = directoryPath
        target.columnSelectedFile = selectedFile
        workspaceStackRouteElements[index] = .fileBrowser(target)
    }

    var visibleHostSwitcherDestination: HostSwitcherDestination {
        if let destination = Self.hostSwitcherDestination(from: workspaceStackRouteElements.last) {
            return destination
        }
        if isSplit, case .utility(let utility) = splitDetailColumn.root {
            return Self.hostSwitcherDestination(from: .utility(utility)) ?? .inbox
        }
        return .inbox
    }

    static func hostSwitcherDestination(
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
    func showThread(serverId: String, rootId: String, from origin: NavigationOrigin = .screen()) {
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
        var first = workspaceStackRouteElements.endIndex
        while first > workspaceStackRouteElements.startIndex,
              case .fileBrowser(let page) = workspaceStackRouteElements[first - 1],
              page.serverId == target.serverId, page.scope == target.scope {
            first -= 1
        }
        guard first < workspaceStackRouteElements.endIndex else { return }
        workspaceStackRouteElements.replaceSubrange(first..., with: [.fileBrowser(target)])
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

    /// The person popped the shown stack back to `depth` screens above its
    /// root: the compact stack's, or the split detail column's.
    func popShownStack(toDepth depth: Int) {
        let cut: Int
        if isSplit {
            let pushed = splitDetailColumn.pushed
            guard pushed.count > depth else { return }
            cut = pushed[depth].index
        } else {
            guard workspaceStackRouteElements.count > depth else { return }
            cut = depth
        }
        mediaOverlayYieldsToUserNavigation()
        workspaceStackRouteElements.removeLast(workspaceStackRouteElements.count - cut)
    }

    /// The all-sessions list with nothing pushed over it (compact stack or split detail).
    var showsAllSessionsRoot: Bool {
        selectedWorkspaceFilter == nil && workspaceStackRouteElements.isEmpty
    }

    private static func diagnosticContext(
        for element: WorkspaceStackRouteElement
    ) -> WorkspaceStackDiagnosticContext {
        switch element {
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
        case .paneEntry(let entry): paneEntryDiagnosticContext(entry)
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
        selectedWorkspaceFilter = snapshot.selectedWorkspaceFilter
        workspaceStackRouteElements = snapshot.workspaceStackRouteElements
        isRestoringMediaOverlay = false
    }

    private struct MediaOverlaySnapshot {
        let presentation: WorkspaceNavigationPresentation
        let selectedWorkspaceFilter: WorkspaceNavTarget?
        let workspaceStackRouteElements: [WorkspaceStackRouteElement]
        let activeServerId: String?
    }
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
