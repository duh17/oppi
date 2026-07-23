import SwiftUI

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

enum AppLaunchPairingPolicy {
    static func shouldShowOnboardingAfterInviteFailure(pairedServerCount: Int) -> Bool {
        pairedServerCount == 0
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
}

enum ServerResourceDetailKind: Hashable, Sendable {
    case skill
    case `extension`
}

/// Server identity travels with every resource route so a server switch or
/// adaptive-layout transition can never issue a detail request to the wrong host.
struct ServerResourceDetailNavTarget: Hashable, Sendable {
    let serverId: String
    let kind: ServerResourceDetailKind
    let resourceId: String
}

struct ServerSkillBrowserNavTarget: Hashable, Sendable {
    let serverId: String
    let resourceId: String
}

struct ServerSkillFileNavTarget: Hashable, Sendable {
    let serverId: String
    let resourceId: String
    let path: String
}

/// Detail-column target for the regular-width workspace split shell.
///
/// The sidebar keeps the workspace catalog visible. The detail pane hosts the
/// global sessions inbox, workspace detail, chat, files, configuration, or
/// utility views. Compact width keeps using `workspacePath` pushes.
enum WorkspaceSplitDetailTarget: Hashable {
    case session(WorkspaceSessionNavTarget)
    case fileBrowser(FileBrowserNavTarget)
    case linkedFile(WorkspaceLinkedFileNavTarget)
    case workspaceConfiguration(WorkspaceNavTarget)
    case utility(WorkspaceUtilityNavTarget)
}

enum WorkspaceSplitDetailPathElement: Hashable {
    case session(WorkspaceSessionNavTarget)
    case fileBrowser(FileBrowserNavTarget)
    case linkedFile(WorkspaceLinkedFileNavTarget)
    case serverResourceDetail(ServerResourceDetailNavTarget)
    case serverSkillBrowser(ServerSkillBrowserNavTarget)
    case serverSkillFile(ServerSkillFileNavTarget)
}

struct WorkspaceConfigurationNavTarget: Hashable {
    let workspaceTarget: WorkspaceNavTarget
}

private enum WorkspaceStackRouteElement: Hashable {
    case workspace(WorkspaceNavTarget)
    case session(WorkspaceSessionNavTarget)
    case fileBrowser(FileBrowserNavTarget)
    case linkedFile(WorkspaceLinkedFileNavTarget)
    case workspaceConfiguration(WorkspaceNavTarget)
    case utility(WorkspaceUtilityNavTarget)
    case serverResourceDetail(ServerResourceDetailNavTarget)
    case serverSkillBrowser(ServerSkillBrowserNavTarget)
    case serverSkillFile(ServerSkillFileNavTarget)
    case unknown
}

struct WorkspaceStackDiagnosticContext: Equatable, Sendable {
    let screen: String
    let sessionId: String?
    let workspaceId: String?

    static let inboxAll = WorkspaceStackDiagnosticContext(
        screen: "workspace_inbox_all",
        sessionId: nil,
        workspaceId: nil
    )

    static let unknown = WorkspaceStackDiagnosticContext(
        screen: "workspace_stack_unknown",
        sessionId: nil,
        workspaceId: nil
    )
}

/// Navigation state for the app.
@MainActor @Observable
final class AppNavigation {
    var selectedTab: AppTab = .workspaces
    var showOnboarding: Bool = true
    var showWhatsNew: Bool = false

    /// Current workspace navigation shell. Compact width keeps the existing
    /// push stack; regular width selects workspace/session columns directly.
    var workspaceNavigationPresentation: WorkspaceNavigationPresentation = .stack

    /// Workspace selection retained while moving between stack and split shells.
    /// Nil means the global sessions inbox is visible for the active server.
    var selectedWorkspaceFilter: WorkspaceNavTarget?

    /// Selection backing the regular-width split shell.
    var splitSelectedWorkspace: WorkspaceNavTarget?
    var splitDetailTarget: WorkspaceSplitDetailTarget?

    /// Navigation path owned by the regular-width detail column.
    ///
    /// Keeps detail-only pushes, such as file browser directory drilling, out of
    /// the workspace sidebar/content stack.
    var splitDetailPath = NavigationPath() {
        didSet { trimSplitDetailElementsToPathCount() }
    }
    private var splitDetailPathElements: [WorkspaceSplitDetailPathElement] = []

    /// Backward-compatible session selection facade for existing tests and call sites.
    var splitSelectedSession: WorkspaceSessionNavTarget? {
        get {
            guard case .session(let target) = splitDetailTarget else { return nil }
            return target
        }
        set {
            if let newValue {
                splitDetailTarget = .session(newValue)
                resetSplitDetailPath()
            } else if case .session = splitDetailTarget {
                splitDetailTarget = nil
                resetSplitDetailPath()
            }
        }
    }

    /// Column visibility backing the regular-width split shell. The system
    /// sidebar affordance and edge gestures update this binding, so iPad users
    /// can reveal or hide workspace/session columns without custom chrome.
    var splitColumnVisibility: NavigationSplitViewVisibility = .automatic

    /// Launch phase gate. While `.resolving`, ContentView shows a blank
    /// canvas until local pairing and cache state are known.
    var launchPhase: AppLaunchPhase = .resolving

    /// Reveal the normal app shell for an existing pairing before transport
    /// preparation finishes. Connectivity failures must never masquerade as
    /// missing credentials and route a paired user back through onboarding.
    func revealPairedServerShell() {
        showOnboarding = false
        launchPhase = .ready
    }

    /// Set after a fresh pairing when the server had no workspaces.
    /// The workspace navigation shell consumes this to present guided creation.
    var shouldGuideWorkspaceCreation: Bool = false

    /// When set, the Quick Session sheet is presented over the current view.
    var showQuickSession: Bool = false

    /// Programmatic navigation path for the workspace tab.
    /// Set externally (e.g. by QuickSessionSheet) to deep-link to a session.
    var workspacePath = NavigationPath() {
        didSet {
            synchronizeWorkspaceStackMetadata()
            if workspaceNavigationPresentation == .stack, workspacePath.count == 0 {
                selectedWorkspaceFilter = nil
            }
        }
    }
    private var workspaceStackDiagnosticContexts: [WorkspaceStackDiagnosticContext] = []
    private var workspaceStackRouteElements: [WorkspaceStackRouteElement] = []

    var workspaceStackDiagnosticContext: WorkspaceStackDiagnosticContext {
        workspaceStackDiagnosticContexts.last ?? .inboxAll
    }

    func setWorkspaceNavigationPresentation(_ presentation: WorkspaceNavigationPresentation) {
        guard workspaceNavigationPresentation != presentation else { return }
        let preservedStackState = presentation == .stack ? stackStateForCurrentSplitSelection() : nil
        let preservedSplitState = presentation == .split ? splitStateForCurrentStackSelection() : nil

        workspaceNavigationPresentation = presentation
        switch presentation {
        case .stack:
            selectedWorkspaceFilter = splitSelectedWorkspace ?? selectedWorkspaceFilter
            if let preservedStackState {
                replaceWorkspaceStack(
                    path: preservedStackState.path,
                    diagnosticContexts: preservedStackState.contexts,
                    routeElements: preservedStackState.routeElements
                )
            }
            splitSelectedWorkspace = nil
            splitDetailTarget = nil
            resetSplitDetailPath()
            splitColumnVisibility = .automatic
        case .split:
            splitSelectedWorkspace = preservedSplitState?.workspace ?? selectedWorkspaceFilter
            splitDetailTarget = preservedSplitState?.detail
            installSplitDetailPath(preservedSplitState?.detailPathElements ?? [])
            replaceWorkspaceStack(path: NavigationPath(), diagnosticContexts: [], routeElements: [])
            splitColumnVisibility = splitVisibility(for: splitDetailTarget)
        }
    }

    func openWorkspace(_ target: WorkspaceNavTarget) {
        selectedTab = .workspaces
        selectedWorkspaceFilter = target
        switch workspaceNavigationPresentation {
        case .stack:
            replaceWorkspaceStack(
                path: Self.workspaceInboxPath(target),
                diagnosticContexts: [Self.workspaceInboxDiagnosticContext(target)],
                routeElements: [.workspace(target)]
            )
        case .split:
            splitSelectedWorkspace = target
            splitDetailTarget = nil
            resetSplitDetailPath()
            splitColumnVisibility = .all
        }
    }

    func showAllWorkspaceSessions() {
        selectedTab = .workspaces
        selectedWorkspaceFilter = nil
        switch workspaceNavigationPresentation {
        case .stack:
            replaceWorkspaceStack(path: NavigationPath(), diagnosticContexts: [], routeElements: [])
        case .split:
            splitSelectedWorkspace = nil
            splitDetailTarget = nil
            resetSplitDetailPath()
            splitColumnVisibility = .all
        }
    }

    func openWorkspaceSession(_ target: WorkspaceSessionNavTarget, workspace: WorkspaceNavTarget? = nil) {
        selectedTab = .workspaces
        let resolvedTarget = target.withWorkspaceIdIfMissing(workspace?.workspace.id)
        let wasShowingWorkspaceInbox = workspace.map {
            selectedWorkspaceFilter == $0 && workspacePath.count == 1
        } ?? false
        // The all-sessions inbox is the stack root. Opening a session from
        // there appends the chat so swiping back returns to all sessions
        // instead of the session's workspace-scoped inbox. The workspace hint
        // still rides on the session target for server scoping.
        let isAtAllSessionsRoot = selectedWorkspaceFilter == nil && workspacePath.count == 0
        if let workspace, !(workspaceNavigationPresentation == .stack && isAtAllSessionsRoot) {
            selectedWorkspaceFilter = workspace
        }
        switch workspaceNavigationPresentation {
        case .stack:
            let sessionContext = Self.sessionDiagnosticContext(resolvedTarget)
            if let workspace, !isAtAllSessionsRoot {
                if wasShowingWorkspaceInbox {
                    appendWorkspaceStack(
                        resolvedTarget,
                        diagnosticContext: sessionContext,
                        routeElement: .session(resolvedTarget)
                    )
                } else {
                    replaceWorkspaceStack(
                        path: Self.workspaceSessionPath(
                            workspace: workspace,
                            session: resolvedTarget
                        ),
                        diagnosticContexts: [
                            Self.workspaceInboxDiagnosticContext(workspace),
                            sessionContext,
                        ],
                        routeElements: [
                            .workspace(workspace),
                            .session(resolvedTarget),
                        ]
                    )
                }
            } else {
                appendWorkspaceStack(
                    resolvedTarget,
                    diagnosticContext: sessionContext,
                    routeElement: .session(resolvedTarget)
                )
            }
        case .split:
            if case .utility = splitDetailTarget {
                pushSplitDetailSession(resolvedTarget)
                splitColumnVisibility = .detailOnly
                return
            }
            if let workspace {
                splitSelectedWorkspace = workspace
            }
            splitDetailTarget = .session(resolvedTarget)
            resetSplitDetailPath()
            splitColumnVisibility = .detailOnly
        }
    }

    func openWorkspaceFileBrowser(_ target: FileBrowserNavTarget, workspace: WorkspaceNavTarget? = nil) {
        selectedTab = .workspaces
        if let workspace {
            selectedWorkspaceFilter = workspace
        }
        switch workspaceNavigationPresentation {
        case .stack:
            appendWorkspaceStack(
                target,
                diagnosticContext: Self.fileBrowserDiagnosticContext(target),
                routeElement: .fileBrowser(target)
            )
        case .split:
            if let workspace {
                splitSelectedWorkspace = workspace
            }
            splitDetailTarget = .fileBrowser(target)
            resetSplitDetailPath()
            splitColumnVisibility = .detailOnly
        }
    }

    func openWorkspaceLinkedFile(_ target: WorkspaceLinkedFileNavTarget, workspace: WorkspaceNavTarget? = nil) {
        selectedTab = .workspaces
        if let workspace {
            selectedWorkspaceFilter = workspace
        }
        switch workspaceNavigationPresentation {
        case .stack:
            appendWorkspaceStack(
                target,
                diagnosticContext: Self.linkedFileDiagnosticContext(target),
                routeElement: .linkedFile(target)
            )
        case .split:
            if let workspace {
                splitSelectedWorkspace = workspace
            }
            if splitDetailTarget == nil {
                splitDetailTarget = .linkedFile(target)
                resetSplitDetailPath()
            } else {
                pushSplitDetailLinkedFile(target)
            }
            splitColumnVisibility = .detailOnly
        }
    }

    func openWorkspaceUtility(_ target: WorkspaceUtilityNavTarget) {
        guard target.isReleaseEnabled else { return }

        selectedTab = .workspaces
        switch workspaceNavigationPresentation {
        case .stack:
            appendWorkspaceStack(
                target,
                diagnosticContext: Self.utilityDiagnosticContext(target),
                routeElement: .utility(target)
            )
        case .split:
            selectedWorkspaceFilter = nil
            splitSelectedWorkspace = nil
            splitDetailTarget = .utility(target)
            resetSplitDetailPath()
            splitColumnVisibility = .all
        }
    }

    func openServerResourceDetail(_ target: ServerResourceDetailNavTarget) {
        selectedTab = .workspaces
        switch workspaceNavigationPresentation {
        case .stack:
            appendWorkspaceStack(
                target,
                diagnosticContext: Self.serverResourceDetailDiagnosticContext(target),
                routeElement: .serverResourceDetail(target)
            )
        case .split:
            splitDetailPath.append(target)
            splitDetailPathElements.append(.serverResourceDetail(target))
            splitColumnVisibility = .all
        }
    }

    func openServerSkillBrowser(_ target: ServerSkillBrowserNavTarget) {
        selectedTab = .workspaces
        switch workspaceNavigationPresentation {
        case .stack:
            appendWorkspaceStack(
                target,
                diagnosticContext: Self.serverSkillBrowserDiagnosticContext,
                routeElement: .serverSkillBrowser(target)
            )
        case .split:
            splitDetailPath.append(target)
            splitDetailPathElements.append(.serverSkillBrowser(target))
            splitColumnVisibility = .all
        }
    }

    func openServerSkillFile(_ target: ServerSkillFileNavTarget) {
        selectedTab = .workspaces
        switch workspaceNavigationPresentation {
        case .stack:
            appendWorkspaceStack(
                target,
                diagnosticContext: Self.serverSkillFileDiagnosticContext,
                routeElement: .serverSkillFile(target)
            )
        case .split:
            splitDetailPath.append(target)
            splitDetailPathElements.append(.serverSkillFile(target))
            splitColumnVisibility = .all
        }
    }

    func openWorkspaceConfiguration(_ target: WorkspaceNavTarget) {
        selectedTab = .workspaces
        selectedWorkspaceFilter = target
        switch workspaceNavigationPresentation {
        case .stack:
            appendWorkspaceStack(
                WorkspaceConfigurationNavTarget(workspaceTarget: target),
                diagnosticContext: Self.workspaceConfigurationDiagnosticContext(target),
                routeElement: .workspaceConfiguration(target)
            )
        case .split:
            splitSelectedWorkspace = target
            splitDetailTarget = .workspaceConfiguration(target)
            resetSplitDetailPath()
            splitColumnVisibility = .all
        }
    }

    func showWorkspaceListInSplitSidebar() {
        guard workspaceNavigationPresentation == .split else { return }
        selectedTab = .workspaces
        selectedWorkspaceFilter = nil
        splitSelectedWorkspace = nil
        replaceWorkspaceStack(path: NavigationPath(), diagnosticContexts: [], routeElements: [])
        splitColumnVisibility = .all
    }

    func completeWorkspaceConfiguration(_ target: WorkspaceNavTarget) {
        guard workspaceNavigationPresentation == .split else { return }
        guard splitDetailTarget == .workspaceConfiguration(target) else { return }
        showSessionInboxInSplit()
    }

    func showSessionInboxInSplit() {
        guard workspaceNavigationPresentation == .split else { return }
        selectedTab = .workspaces
        splitDetailTarget = nil
        resetSplitDetailPath()
        splitColumnVisibility = .all
    }

    func clearWorkspaceSelections() {
        selectedWorkspaceFilter = nil
        replaceWorkspaceStack(path: NavigationPath(), diagnosticContexts: [], routeElements: [])
        splitSelectedWorkspace = nil
        splitDetailTarget = nil
        resetSplitDetailPath()
        splitColumnVisibility = workspaceNavigationPresentation == .split ? .all : .automatic
    }

    /// Replace the workspace stack with a session destination in one state write.
    ///
    /// Avoid clearing the path and appending in separate writes: SwiftUI may
    /// briefly re-appear the previous chat view during the intermediate empty
    /// stack, and that old view can steal the focused session stream back.
    func setWorkspaceSessionPath(serverId: String, sessionId: String, workspaceId: String? = nil) {
        let target = WorkspaceSessionNavTarget(serverId: serverId, sessionId: sessionId, workspaceId: workspaceId)
        switch workspaceNavigationPresentation {
        case .stack:
            replaceWorkspaceStack(
                path: Self.workspaceSessionPath(
                    serverId: serverId,
                    sessionId: sessionId,
                    workspaceId: workspaceId
                ),
                diagnosticContexts: [Self.sessionDiagnosticContext(target)],
                routeElements: [.session(target)]
            )
        case .split:
            splitDetailTarget = .session(target)
            resetSplitDetailPath()
            splitColumnVisibility = .detailOnly
        }
    }

    static func workspaceSessionPath(serverId: String, sessionId: String, workspaceId: String? = nil) -> NavigationPath {
        var path = NavigationPath()
        path.append(WorkspaceSessionNavTarget(serverId: serverId, sessionId: sessionId, workspaceId: workspaceId))
        return path
    }

    private static func workspaceInboxPath(_ target: WorkspaceNavTarget) -> NavigationPath {
        var path = NavigationPath()
        path.append(target)
        return path
    }

    private static func workspaceSessionPath(
        workspace: WorkspaceNavTarget,
        session: WorkspaceSessionNavTarget
    ) -> NavigationPath {
        var path = workspaceInboxPath(workspace)
        path.append(session)
        return path
    }

    /// Pending workspace creation deep-link payload.
    /// The workspace navigation shell consumes this once and clears it.
    var pendingWorkspaceDeepLink: WorkspaceDeepLink.Payload?

    // MARK: - Quick Session Handoff
    //
    // These properties form a produce-once / consume-once handoff between
    // QuickSessionSheet (producer) and ContentView + ChatView (consumers).
    //
    // Flow:
    // 1. QuickSessionSheet sets `pendingQuickSessionNav` (atomic intent)
    // 2. QuickSessionSheet calls dismiss()
    // 3. ContentView.onDismiss reads nav, extracts message/images, builds path
    // 4. ChatView.task(id: sessionId) reads message/images, auto-sends

    /// Atomic navigation intent from QuickSessionSheet.
    /// Bundles target workspace, session ID, and optional auto-send data.
    /// Set before dismiss; consumed in ContentView.onDismiss.
    var pendingQuickSessionNav: QuickSessionNav?

    /// Message to auto-send when the quick session's ChatView opens.
    /// Extracted from `pendingQuickSessionNav` by ContentView.onDismiss.
    /// Consumed once by ChatView, then cleared.
    var pendingQuickSessionMessage: String?

    /// Attachments to auto-send when the quick session message opens.
    /// Extracted from `pendingQuickSessionNav` by ContentView.onDismiss.
    var pendingQuickSessionAttachments: [PendingAttachment]?

    // MARK: - Legacy Shell Routing

    /// Routes legacy tab selections into the Workspaces-primary navigation stack.
    ///
    /// Older persisted state and a few compatibility call sites can still set
    /// `.server` or `.settings`. They route to utility destinations in the
    /// Workspaces navigation shell and the selected tab resets to `.workspaces`.
    @discardableResult
    func routeLegacySelectedTabIfNeeded() -> WorkspaceUtilityNavTarget? {
        guard !showOnboarding else { return nil }
        guard case .ready = launchPhase else { return nil }

        let target: WorkspaceUtilityNavTarget
        switch selectedTab {
        case .workspaces:
            return nil
        case .server:
            target = .manageServers
        case .settings:
            target = .appSettings
        }

        switch workspaceNavigationPresentation {
        case .stack:
            var path = NavigationPath()
            path.append(target)
            replaceWorkspaceStack(
                path: path,
                diagnosticContexts: [Self.utilityDiagnosticContext(target)],
                routeElements: [.utility(target)]
            )
        case .split:
            splitDetailTarget = .utility(target)
            resetSplitDetailPath()
        }
        selectedTab = .workspaces
        return target
    }

    func pushWorkspaceFileBrowser(_ target: FileBrowserNavTarget) {
        appendWorkspaceStack(
            target,
            diagnosticContext: Self.fileBrowserDiagnosticContext(target),
            routeElement: .fileBrowser(target)
        )
    }

    func pushSplitDetailFileBrowser(_ target: FileBrowserNavTarget) {
        splitDetailPath.append(target)
        splitDetailPathElements.append(.fileBrowser(target))
    }

    func removeLastSplitDetailPath(_ count: Int) {
        guard count > 0 else { return }
        splitDetailPath.removeLast(count)
        trimSplitDetailElementsToPathCount()
    }

    private func pushSplitDetailLinkedFile(_ target: WorkspaceLinkedFileNavTarget) {
        splitDetailPath.append(target)
        splitDetailPathElements.append(.linkedFile(target))
    }

    private func resetSplitDetailPath() {
        installSplitDetailPath([])
    }

    private func installSplitDetailPath(_ elements: [WorkspaceSplitDetailPathElement]) {
        var path = NavigationPath()
        for element in elements {
            switch element {
            case .session(let target):
                path.append(target)
            case .fileBrowser(let target):
                path.append(target)
            case .linkedFile(let target):
                path.append(target)
            case .serverResourceDetail(let target):
                path.append(target)
            case .serverSkillBrowser(let target):
                path.append(target)
            case .serverSkillFile(let target):
                path.append(target)
            }
        }
        splitDetailPathElements = elements
        splitDetailPath = path
    }

    private func pushSplitDetailSession(_ target: WorkspaceSessionNavTarget) {
        splitDetailPath.append(target)
        splitDetailPathElements.append(.session(target))
    }

    private func trimSplitDetailElementsToPathCount() {
        guard splitDetailPathElements.count > splitDetailPath.count else { return }
        splitDetailPathElements.removeLast(splitDetailPathElements.count - splitDetailPath.count)
    }

    private func replaceWorkspaceStack(
        path: NavigationPath,
        diagnosticContexts: [WorkspaceStackDiagnosticContext],
        routeElements: [WorkspaceStackRouteElement]
    ) {
        workspaceStackDiagnosticContexts = Array(diagnosticContexts.prefix(path.count))
        workspaceStackRouteElements = Array(routeElements.prefix(path.count))
        workspacePath = path
        synchronizeWorkspaceStackMetadata()
    }

    private func appendWorkspaceStack<Element: Hashable>(
        _ element: Element,
        diagnosticContext: WorkspaceStackDiagnosticContext,
        routeElement: WorkspaceStackRouteElement
    ) {
        workspaceStackDiagnosticContexts.append(diagnosticContext)
        workspaceStackRouteElements.append(routeElement)
        workspacePath.append(element)
    }

    private func synchronizeWorkspaceStackMetadata() {
        let pathCount = workspacePath.count
        synchronizeWorkspaceStackArray(&workspaceStackDiagnosticContexts, pathCount: pathCount, fill: .unknown)
        synchronizeWorkspaceStackArray(&workspaceStackRouteElements, pathCount: pathCount, fill: .unknown)
    }

    private func synchronizeWorkspaceStackArray<Element>(
        _ elements: inout [Element],
        pathCount: Int,
        fill: Element
    ) {
        if elements.count > pathCount {
            elements.removeLast(elements.count - pathCount)
        } else if elements.count < pathCount {
            elements.append(
                contentsOf: repeatElement(fill, count: pathCount - elements.count)
            )
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
        case .schedules: "schedules"
        case .agents: "agents"
        case .skills: "skills"
        case .extensions: "extensions"
        case .manageServers: "manage_servers"
        case .appSettings: "app_settings"
        }
        return WorkspaceStackDiagnosticContext(
            screen: "utility_\(label)",
            sessionId: nil,
            workspaceId: nil
        )
    }

    private static func serverResourceDetailDiagnosticContext(
        _ target: ServerResourceDetailNavTarget
    ) -> WorkspaceStackDiagnosticContext {
        WorkspaceStackDiagnosticContext(
            screen: target.kind == .skill ? "server_skill_detail" : "server_extension_detail",
            sessionId: nil,
            workspaceId: nil
        )
    }

    private static let serverSkillBrowserDiagnosticContext = WorkspaceStackDiagnosticContext(
        screen: "server_skill_browser",
        sessionId: nil,
        workspaceId: nil
    )

    private static let serverSkillFileDiagnosticContext = WorkspaceStackDiagnosticContext(
        screen: "server_skill_file",
        sessionId: nil,
        workspaceId: nil
    )

    private func stackStateForCurrentSplitSelection() -> (
        path: NavigationPath,
        contexts: [WorkspaceStackDiagnosticContext],
        routeElements: [WorkspaceStackRouteElement]
    )? {
        var path = NavigationPath()
        var contexts: [WorkspaceStackDiagnosticContext] = []
        var routeElements: [WorkspaceStackRouteElement] = []

        let includesWorkspaceDetail = switch splitDetailTarget {
        case .utility:
            false
        case .session, .fileBrowser, .linkedFile, .workspaceConfiguration, nil:
            true
        }
        if includesWorkspaceDetail, let splitSelectedWorkspace {
            path.append(splitSelectedWorkspace)
            contexts.append(Self.workspaceInboxDiagnosticContext(splitSelectedWorkspace))
            routeElements.append(.workspace(splitSelectedWorkspace))
        }

        switch splitDetailTarget {
        case .session(let target):
            path.append(target)
            contexts.append(Self.sessionDiagnosticContext(target))
            routeElements.append(.session(target))
        case .fileBrowser(let target):
            path.append(target)
            contexts.append(Self.fileBrowserDiagnosticContext(target))
            routeElements.append(.fileBrowser(target))
        case .linkedFile(let target):
            path.append(target)
            contexts.append(Self.linkedFileDiagnosticContext(target))
            routeElements.append(.linkedFile(target))
        case .workspaceConfiguration(let target):
            path.append(WorkspaceConfigurationNavTarget(workspaceTarget: target))
            contexts.append(Self.workspaceConfigurationDiagnosticContext(target))
            routeElements.append(.workspaceConfiguration(target))
        case .utility(let target):
            if target.isReleaseEnabled {
                path.append(target)
                contexts.append(Self.utilityDiagnosticContext(target))
                routeElements.append(.utility(target))
            }
        case nil:
            break
        }

        for element in splitDetailPathElements {
            switch element {
            case .session(let target):
                path.append(target)
                contexts.append(Self.sessionDiagnosticContext(target))
                routeElements.append(.session(target))
            case .fileBrowser(let target):
                path.append(target)
                contexts.append(Self.fileBrowserDiagnosticContext(target))
                routeElements.append(.fileBrowser(target))
            case .linkedFile(let target):
                path.append(target)
                contexts.append(Self.linkedFileDiagnosticContext(target))
                routeElements.append(.linkedFile(target))
            case .serverResourceDetail(let target):
                path.append(target)
                contexts.append(Self.serverResourceDetailDiagnosticContext(target))
                routeElements.append(.serverResourceDetail(target))
            case .serverSkillBrowser(let target):
                path.append(target)
                contexts.append(Self.serverSkillBrowserDiagnosticContext)
                routeElements.append(.serverSkillBrowser(target))
            case .serverSkillFile(let target):
                path.append(target)
                contexts.append(Self.serverSkillFileDiagnosticContext)
                routeElements.append(.serverSkillFile(target))
            }
        }

        return path.count > 0 ? (path, contexts, routeElements) : nil
    }

    private func splitStateForCurrentStackSelection() -> (
        workspace: WorkspaceNavTarget?,
        detail: WorkspaceSplitDetailTarget?,
        detailPathElements: [WorkspaceSplitDetailPathElement]
    ) {
        var workspace: WorkspaceNavTarget?
        var detail: WorkspaceSplitDetailTarget?
        var detailPathElements: [WorkspaceSplitDetailPathElement] = []

        for element in workspaceStackRouteElements {
            switch element {
            case .workspace(let target):
                workspace = target
            case .session(let target):
                if case .utility = detail {
                    detailPathElements.append(.session(target))
                } else {
                    detail = .session(target)
                    detailPathElements = []
                }
            case .fileBrowser(let target):
                if detail == nil {
                    detail = .fileBrowser(target)
                } else {
                    detailPathElements.append(.fileBrowser(target))
                }
            case .linkedFile(let target):
                if detail == nil {
                    detail = .linkedFile(target)
                } else {
                    detailPathElements.append(.linkedFile(target))
                }
            case .workspaceConfiguration(let target):
                workspace = target
                detail = .workspaceConfiguration(target)
                detailPathElements = []
            case .utility(let target):
                detail = target.isReleaseEnabled ? .utility(target) : nil
                detailPathElements = []
            case .serverResourceDetail(let target):
                detailPathElements.append(.serverResourceDetail(target))
            case .serverSkillBrowser(let target):
                detailPathElements.append(.serverSkillBrowser(target))
            case .serverSkillFile(let target):
                detailPathElements.append(.serverSkillFile(target))
            case .unknown:
                break
            }
        }

        return (workspace, detail, detailPathElements)
    }

    private func splitVisibility(
        for detail: WorkspaceSplitDetailTarget?
    ) -> NavigationSplitViewVisibility {
        switch detail {
        case .session, .fileBrowser, .linkedFile:
            .detailOnly
        case .workspaceConfiguration, .utility, nil:
            .all
        }
    }
}

/// Atomic navigation intent for quick session deep-link.
///
/// Bundles everything needed to navigate to a session and optionally
/// auto-send a message. Set as a single write by QuickSessionSheet,
/// consumed as a single read by ContentView.onDismiss.
struct QuickSessionNav {
    let target: WorkspaceNavTarget
    let sessionId: String
    let autoSendMessage: String?
    let autoSendAttachments: [PendingAttachment]?

    init(target: WorkspaceNavTarget, sessionId: String, autoSendMessage: String? = nil, autoSendAttachments: [PendingAttachment]? = nil) {
        self.target = target
        self.sessionId = sessionId
        self.autoSendMessage = autoSendMessage
        self.autoSendAttachments = autoSendAttachments
    }
}

enum AppTab: Hashable {
    case workspaces
    case server
    case settings
}
