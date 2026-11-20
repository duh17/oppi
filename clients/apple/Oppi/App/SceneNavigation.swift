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
/// (`SceneNavigation.workspaceStackRouteElements`). The sidebar lists the
/// workspaces, so the stack's workspace layer is the sidebar's selection, not
/// a screen here: the column's root is the first session, file, configuration
/// or utility screen, else the selected workspace's sessions, else All
/// Sessions. A configuration or utility screen starts the column afresh.
/// Each shown screen keeps the stack index it came from, so a pop in the
/// column cuts the stack at the same screen.
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

    init(stack: [WorkspaceStackRouteElement], selectedWorkspace: WorkspaceNavTarget?) {
        var root: (route: ShellRoute, index: Int)?
        var pushed: [(route: ShellRoute, index: Int)] = []
        for (index, element) in stack.enumerated() {
            switch element {
            case .workspace:
                continue
            case .session, .fileBrowser, .linkedFile:
                if root == nil {
                    // Pages pushed over the list stay under a new root.
                    root = (ShellRoute(element), index)
                    pushed = []
                } else {
                    pushed.append((ShellRoute(element), index))
                }
            case .workspaceConfiguration, .utility:
                root = (ShellRoute(element), index)
                pushed = []
            case .chatReader, .serverResourceDetail,
                 .serverDetails, .modelProviders, .paneEntry:
                pushed.append((ShellRoute(element), index))
            }
        }
        self.root = root?.route ?? selectedWorkspace.map(ShellRoute.workspace) ?? .inbox
        rootIndex = root?.index
        self.pushed = pushed
    }

    /// Whether the sidebar shows beside this column: hidden under a chat or a
    /// file, shown beside a list, a configuration or a utility.
    var visibility: SplitColumnVisibility {
        switch root {
        case .session, .fileBrowser, .linkedFile: .detailOnly
        default: .all
        }
    }
}

/// A screen of the window's stack. The compact shell shows each above All
/// Sessions; the split shell shows them through `SplitDetailColumn`.
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
    var selectedTab: AppTab = .workspaces

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

    /// Column visibility backing the regular-width split shell. The system
    /// sidebar gestures update it too, so iPad users can reveal or hide the
    /// workspace column either way.
    var splitColumnVisibility: SplitColumnVisibility = .automatic

    /// Session-list search lives on navigation so it survives compact inbox
    /// remount after Back and split detail replacement on iPad.
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

    /// The split shell's detail column, read from the stack.
    var splitDetailColumn: SplitDetailColumn {
        SplitDetailColumn(stack: workspaceStackRouteElements, selectedWorkspace: selectedWorkspaceFilter)
    }

    /// What covers a session list, for its search: the screens over it on
    /// the compact stack (none in the split shell, where the list sits in the
    /// detail column's root), and whether a split detail replaced the list.
    var sessionListCover: (stackDepth: Int, detailReplacesList: Bool) {
        isSplit ? (0, splitDetailColumn.rootIndex != nil) : (workspaceStackRouteElements.count, false)
    }

    var workspaceStackDiagnosticContext: WorkspaceStackDiagnosticContext {
        workspaceStackRouteElements.last.map(Self.diagnosticContext(for:)) ?? .inboxAll
    }

    var visibleSplitDiagnosticContext: WorkspaceStackDiagnosticContext {
        let column = splitDetailColumn
        if let index = column.pushed.last?.index ?? column.rootIndex {
            return Self.diagnosticContext(for: workspaceStackRouteElements[index])
        }
        guard let workspace = selectedWorkspaceFilter else {
            return WorkspaceStackDiagnosticContext(screen: "workspace_split_inbox_all", sessionId: nil, workspaceId: nil)
        }
        return WorkspaceStackDiagnosticContext(
            screen: "workspace_split_inbox_filtered",
            sessionId: nil,
            workspaceId: workspace.workspace.id
        )
    }

    /// The window changed shells. The stack stays as it is; only the split
    /// sidebar's visibility starts from what the detail column shows.
    func setWorkspaceNavigationPresentation(
        _ presentation: WorkspaceNavigationPresentation,
        measurement: WorkspaceNavigationMeasurement? = nil
    ) {
        guard !isMediaOverlayActive else { return }
        guard workspaceNavigationPresentation != presentation else { return }
        let from = workspaceNavigationPresentation
        let fromSessionId = visibleDiagnosticSessionId()
        workspaceNavigationPresentation = presentation
        switch presentation {
        case .stack:
            splitColumnVisibility = .automatic
            // The compact stack lists the workspace only as a pushed layer.
            if selectedWorkspaceFilter != nil, workspaceStackRouteElements.isEmpty {
                selectedWorkspaceFilter = nil
            }
        case .split:
            splitColumnVisibility = splitDetailColumn.visibility
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
                splitColumnVisibility: splitColumnVisibility,
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

    /// The stack that shows `workspace`'s sessions with nothing over them.
    private static func workspaceLayer(_ workspace: WorkspaceNavTarget?) -> [WorkspaceStackRouteElement] {
        workspace.map { [.workspace($0)] } ?? []
    }

    func openWorkspace(_ target: WorkspaceNavTarget) {
        guard scopedLockAllows(.workspace(serverId: target.serverId, workspaceId: target.workspace.id), retry: {
            self.openWorkspace(target)
        }) else { return }
        mediaOverlayYieldsToUserNavigation()
        selectedTab = .workspaces
        selectedWorkspaceFilter = target
        workspaceStackRouteElements = [.workspace(target)]
        if isSplit { splitColumnVisibility = .all }
    }

    func showAllWorkspaceSessions() {
        mediaOverlayYieldsToUserNavigation()
        selectedTab = .workspaces
        selectedWorkspaceFilter = nil
        workspaceStackRouteElements = []
        if isSplit { splitColumnVisibility = .all }
    }

    /// If the deleted workspace is the current selection, leave it through the
    /// all-sessions inbox. Manage-list deletes of an unselected workspace stay put.
    func leaveDeletedWorkspace(serverId: String, workspaceId: String) {
        guard let selected = selectedWorkspaceFilter,
              selected.serverId == serverId, selected.workspace.id == workspaceId else {
            return
        }
        showAllWorkspaceSessions()
    }

    func openWorkspaceSession(_ target: WorkspaceSessionNavTarget, workspace: WorkspaceNavTarget? = nil) {
        let resolvedTarget = target.withWorkspaceIdIfMissing(workspace?.workspace.id)
        guard scopedLockAllows(Self.lockTarget(resolvedTarget), retry: {
            self.openWorkspaceSession(target, workspace: workspace)
        }) else { return }
        mediaOverlayYieldsToUserNavigation()
        selectedTab = .workspaces
        if isSplit {
            // A session opened over a utility pushes onto it; any other
            // replaces the detail column beside the sidebar's list.
            if case .utility = splitDetailColumn.root {
                workspaceStackRouteElements.append(.session(resolvedTarget))
                splitColumnVisibility = .detailOnly
                return
            }
            if let workspace, selectedWorkspaceFilter != nil {
                selectedWorkspaceFilter = workspace
            }
            workspaceStackRouteElements = Self.workspaceLayer(selectedWorkspaceFilter) + [.session(resolvedTarget)]
            splitColumnVisibility = .detailOnly
            return
        }
        let wasShowingWorkspaceInbox = workspace.map {
            selectedWorkspaceFilter == $0 && workspaceStackRouteElements.count == 1
        } ?? false
        // The all-sessions inbox is the visible back-stop. Opening a session
        // from there keeps chat on top of all sessions instead of inventing
        // the session's unvisited workspace inbox. The workspace hint still
        // rides on the session target for server scoping.
        let isAtAllSessionsRoot = selectedWorkspaceFilter == nil && workspaceStackRouteElements.isEmpty
        if let workspace, !isAtAllSessionsRoot {
            selectedWorkspaceFilter = workspace
        }
        if let workspace, !isAtAllSessionsRoot, !wasShowingWorkspaceInbox {
            workspaceStackRouteElements = [.workspace(workspace), .session(resolvedTarget)]
        } else {
            workspaceStackRouteElements.append(.session(resolvedTarget))
        }
    }

    /// Applies source-aware session navigation without conflating external deep
    /// links with user-tapped hyperlinks inside the current app hierarchy.
    func openSession(_ target: WorkspaceSessionNavTarget, source: SessionNavigationSource) {
        switch source {
        case .externalURL:
            setWorkspaceSessionPath(
                serverId: target.serverId,
                sessionId: target.sessionId,
                workspaceId: target.workspaceId
            )
        case .inAppHyperlink:
            openReferencedSession(target)
        }
    }

    /// The session whose chat is the visible screen: the stack's top, which in
    /// the split shell must be in the detail column.
    private var visibleChatSession: WorkspaceSessionNavTarget? {
        guard case .session(let current)? = workspaceStackRouteElements.last else { return nil }
        if isSplit, splitDetailColumn.routes.last != .session(current) { return nil }
        return current
    }

    /// Open a session from an in-app link (a chat's link, a Pinned session
    /// card): from a chat it pushes, keeping the compact or split back stack;
    /// elsewhere in the split it opens as a session row does. An exact
    /// self-link is a no-op.
    func openReferencedSession(_ target: WorkspaceSessionNavTarget) {
        guard scopedLockAllows(Self.lockTarget(target), retry: {
            self.openReferencedSession(target)
        }) else { return }
        selectedTab = .workspaces
        if let current = visibleChatSession, Self.isSameSession(current, target) {
            return
        }
        if isSplit {
            // A link in a chat, or in a page over one, pushes and keeps that
            // back stack. Anywhere else (a session list, Pinned's session
            // cards, any screen at the column's root with nothing over it)
            // the session opens as a session row does: the chat becomes the
            // column's root, so it carries the sidebar toggle, not a Back to
            // the screen it was picked from.
            let column = splitDetailColumn
            if column.rootIndex == nil || (column.pushed.isEmpty && column.visibility == .all) {
                workspaceStackRouteElements = Self.workspaceLayer(selectedWorkspaceFilter) + [.session(target)]
            } else {
                workspaceStackRouteElements.append(.session(target))
            }
            splitColumnVisibility = .detailOnly
        } else {
            workspaceStackRouteElements.append(.session(target))
        }
    }

    /// Push a wiki-linked file from the currently visible chat without changing
    /// the chat's all-sessions/workspace filter. This keeps Back on the file
    /// destination pointed at the source chat instead of a newly selected
    /// workspace inbox.
    func openReferencedWorkspaceLinkedFile(
        _ target: WorkspaceLinkedFileNavTarget,
        workspace: WorkspaceNavTarget? = nil,
        sourceSession: WorkspaceSessionNavTarget?
    ) {
        guard scopedLockAllows(WorkspaceLinkedFileViewController.lockTarget(for: target), retry: {
            self.openReferencedWorkspaceLinkedFile(target, workspace: workspace, sourceSession: sourceSession)
        }) else { return }
        selectedTab = .workspaces
        guard let sourceSession, let current = visibleChatSession, Self.isSameSession(current, sourceSession) else {
            openWorkspaceLinkedFile(target, workspace: workspace)
            return
        }
        workspaceStackRouteElements.append(.linkedFile(target))
        if isSplit { splitColumnVisibility = .detailOnly }
    }

    private static func isSameSession(
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

    func openChatReader(_ target: ChatReaderNavTarget) {
        selectedTab = .workspaces
        workspaceStackRouteElements.append(.chatReader(target))
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

    func openWorkspaceFileBrowser(_ target: FileBrowserNavTarget, workspace: WorkspaceNavTarget? = nil) {
        if case .workspace(let workspaceId, _) = target.scope {
            guard scopedLockAllows(.workspace(serverId: target.serverId, workspaceId: workspaceId), retry: {
                self.openWorkspaceFileBrowser(target, workspace: workspace)
            }) else { return }
        }
        selectedTab = .workspaces
        if let workspace {
            selectedWorkspaceFilter = workspace
        }
        if isSplit {
            workspaceStackRouteElements = Self.workspaceLayer(selectedWorkspaceFilter) + [.fileBrowser(target)]
            splitColumnVisibility = .detailOnly
        } else {
            workspaceStackRouteElements.append(.fileBrowser(target))
        }
    }

    func openWorkspaceLinkedFile(_ target: WorkspaceLinkedFileNavTarget, workspace: WorkspaceNavTarget? = nil) {
        guard scopedLockAllows(WorkspaceLinkedFileViewController.lockTarget(for: target), retry: {
            self.openWorkspaceLinkedFile(target, workspace: workspace)
        }) else { return }
        selectedTab = .workspaces
        if let workspace {
            selectedWorkspaceFilter = workspace
        }
        if isSplit {
            // Over the list it becomes the column's root; over a detail it pushes.
            if splitDetailColumn.rootIndex == nil {
                workspaceStackRouteElements = Self.workspaceLayer(selectedWorkspaceFilter) + [.linkedFile(target)]
            } else {
                workspaceStackRouteElements.append(.linkedFile(target))
            }
            splitColumnVisibility = .detailOnly
        } else {
            workspaceStackRouteElements.append(.linkedFile(target))
        }
    }

    func openWorkspaceUtility(_ target: WorkspaceUtilityNavTarget) {
        selectedTab = .workspaces
        if isSplit {
            selectedWorkspaceFilter = nil
            workspaceStackRouteElements = [.utility(target)]
            splitColumnVisibility = .all
        } else {
            workspaceStackRouteElements.append(.utility(target))
        }
    }

    /// Pushes a server-scoped page over what the window shows; the split
    /// shell keeps its sidebar beside it.
    private func pushServerPage(_ element: WorkspaceStackRouteElement) {
        selectedTab = .workspaces
        workspaceStackRouteElements.append(element)
        showSidebarBesideServerPage()
    }

    /// The split shell shows its sidebar beside a server page, unless the
    /// window has split panes: there the page is the routed pane's content,
    /// beside the other panes, and the sidebar shows only when the person
    /// asks for it (the page's sidebar toggle).
    private func showSidebarBesideServerPage() {
        guard isSplit, panes.splitLeaves.isEmpty else { return }
        splitColumnVisibility = .all
    }

    func openServerDetails(_ target: ServerDetailsNavTarget) {
        pushServerPage(.serverDetails(target))
    }

    func openModelProviders(_ target: ModelProvidersNavTarget) {
        pushServerPage(.modelProviders(target))
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

    func openHostSwitcherDestination(_ destination: HostSwitcherDestination, serverId: String) {
        guard destination.shouldNavigate(from: visibleHostSwitcherDestination) else { return }

        selectedTab = .workspaces
        let page: WorkspaceStackRouteElement? = switch destination {
        case .inbox: nil
        case .usage: .utility(.manageServers)
        case .serverMetrics: .utility(.serverMetrics)
        case .serverSettings: .serverDetails(ServerDetailsNavTarget(serverId: serverId))
        case .modelProviders: .modelProviders(ModelProvidersNavTarget(serverId: serverId))
        }
        if isSplit {
            // Each job replaces the detail column beside the sidebar.
            selectedWorkspaceFilter = nil
            showSidebarBesideServerPage()
            workspaceStackRouteElements = page.map { [$0] } ?? []
            return
        }
        while Self.hostSwitcherDestination(from: workspaceStackRouteElements.last) != nil {
            workspaceStackRouteElements.removeLast()
        }
        if let page { workspaceStackRouteElements.append(page) }
    }

    private static func hostSwitcherDestination(
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

    func openServerResourceDetail(_ target: ServerResourceDetailNavTarget) {
        pushServerPage(.serverResourceDetail(target))
    }

    func openWorkspaceConfiguration(_ target: WorkspaceNavTarget) {
        guard scopedLockAllows(.workspace(serverId: target.serverId, workspaceId: target.workspace.id), retry: {
            self.openWorkspaceConfiguration(target)
        }) else { return }
        selectedTab = .workspaces
        selectedWorkspaceFilter = target
        if isSplit {
            workspaceStackRouteElements = [.workspace(target), .workspaceConfiguration(target)]
            splitColumnVisibility = .all
        } else {
            workspaceStackRouteElements.append(.workspaceConfiguration(target))
        }
    }

    /// The split sidebar goes back to the workspace list; the detail column
    /// stays.
    func showWorkspaceListInSplitSidebar() {
        guard isSplit else { return }
        selectedTab = .workspaces
        selectedWorkspaceFilter = nil
        workspaceStackRouteElements.removeAll { element in
            if case .workspace = element { return true }
            return false
        }
        splitColumnVisibility = .all
    }

    func completeWorkspaceConfiguration(_ target: WorkspaceNavTarget) {
        guard isSplit, splitDetailColumn.root == .workspaceConfiguration(target) else { return }
        showSessionInboxInSplit()
    }

    /// The split detail column closes back to the selected list.
    func showSessionInboxInSplit() {
        guard isSplit else { return }
        mediaOverlayYieldsToUserNavigation()
        selectedTab = .workspaces
        workspaceStackRouteElements = Self.workspaceLayer(selectedWorkspaceFilter)
        splitColumnVisibility = .all
    }

    func clearWorkspaceSelections() {
        selectedWorkspaceFilter = nil
        workspaceStackRouteElements = []
        splitColumnVisibility = isSplit ? .all : .automatic
    }

    /// Replaces the workspace stack with a session destination in one state
    /// write, so the shell never shows the empty stack in between.
    func setWorkspaceSessionPath(serverId: String, sessionId: String, workspaceId: String? = nil) {
        let target = WorkspaceSessionNavTarget(serverId: serverId, sessionId: sessionId, workspaceId: workspaceId)
        guard scopedLockAllows(Self.lockTarget(target), retry: {
            self.setWorkspaceSessionPath(serverId: serverId, sessionId: sessionId, workspaceId: workspaceId)
        }) else { return }
        if isSplit {
            workspaceStackRouteElements = Self.workspaceLayer(selectedWorkspaceFilter) + [.session(target)]
            splitColumnVisibility = .detailOnly
        } else {
            workspaceStackRouteElements = [.session(target)]
        }
    }

    // MARK: - Scoped locks

    /// Every open of a server-, workspace-, or session-scoped destination
    /// passes here. A locked target asks for device authentication and opens
    /// after success (`retry`); cancel leaves navigation where it was. The
    /// destination views gate again, which covers an unlock that expires
    /// under an open screen.
    private func scopedLockAllows(_ target: ScopedLockTarget, retry: @escaping @MainActor () -> Void) -> Bool {
        ScopedLockService.shared.gate(target, onUnlock: retry)
    }

    private static func lockTarget(_ target: WorkspaceSessionNavTarget) -> ScopedLockTarget {
        ScopedLockService.shared.sessionTarget(
            serverId: target.serverId,
            sessionId: target.sessionId,
            workspaceId: target.workspaceId
        )
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
    func showThread(serverId: String, rootId: String) {
        showAllWorkspaceSessions()
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

    /// A file browser drilled into a folder: the folder pushes onto the stack.
    func pushWorkspaceFileBrowser(_ target: FileBrowserNavTarget) {
        workspaceStackRouteElements.append(.fileBrowser(target))
    }

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

    /// The screens the shell shows above its root, as `popShownStack` counts them.
    var shownStackDepth: Int {
        isSplit ? splitDetailColumn.pushed.count : workspaceStackRouteElements.count
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
        splitColumnVisibility = snapshot.splitColumnVisibility
        isRestoringMediaOverlay = false
    }

    private struct MediaOverlaySnapshot {
        let presentation: WorkspaceNavigationPresentation
        let selectedWorkspaceFilter: WorkspaceNavTarget?
        let workspaceStackRouteElements: [WorkspaceStackRouteElement]
        let splitColumnVisibility: SplitColumnVisibility
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

enum AppTab: Hashable {
    case workspaces
}
