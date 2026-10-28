import SwiftUI

func workspaceListSummary(
    for workspaceId: String,
    in summaries: [String: WorkspaceListSummary]
) -> WorkspaceListSummary {
    summaries[workspaceId] ?? WorkspaceListSummary(
        workspaceId: workspaceId,
        activeCount: 0,
        stoppedCount: 0,
        hasAttention: false
    )
}

func sortedWorkspacesForList(
    _ workspaces: [Workspace],
    summaries: [String: WorkspaceListSummary]
) -> [Workspace] {
    workspaces.sorted { lhs, rhs in
        let lhsSummary = workspaceListSummary(for: lhs.id, in: summaries)
        let rhsSummary = workspaceListSummary(for: rhs.id, in: summaries)

        if lhsSummary.hasAttention != rhsSummary.hasAttention {
            return lhsSummary.hasAttention
        }
        if (lhsSummary.activeCount > 0) != (rhsSummary.activeCount > 0) {
            return lhsSummary.activeCount > 0
        }

        let lhsLatest = lhsSummary.latestActivity ?? .distantPast
        let rhsLatest = rhsSummary.latestActivity ?? .distantPast
        if lhsLatest != rhsLatest {
            return lhsLatest > rhsLatest
        }

        let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
        }
        return lhs.id < rhs.id
    }
}

/// Shared accessibility identifiers for workspace-open controls.
/// Production mounts `SessionInboxViewController`; this namespace keeps the existing
/// identifier helper without a dead SwiftUI screen.
enum WorkspaceHomeView {
    static func workspaceOpenAccessibilityIdentifier(workspaceName: String) -> String {
        "workspace.open.\(workspaceName)"
    }
}

/// Navigation target pairing a workspace with its server for on-demand connection switching.
struct WorkspaceNavTarget: Hashable {
    let serverId: String
    let workspace: Workspace
}

/// Navigation target for opening a session directly from the workspace overview.
struct WorkspaceSessionNavTarget: Hashable {
    let serverId: String
    let sessionId: String
    let routeScope: SessionRouteScope?

    var workspaceId: String? { routeScope?.workspaceId }

    init(
        serverId: String,
        sessionId: String,
        workspaceId: String? = nil,
        routeScope: SessionRouteScope? = nil
    ) {
        self.serverId = serverId
        self.sessionId = sessionId
        if let routeScope {
            self.routeScope = routeScope
        } else if let workspaceId = Self.normalizedWorkspaceId(workspaceId) {
            self.routeScope = .workspace(workspaceId)
        } else {
            self.routeScope = nil
        }
    }

    func withWorkspaceIdIfMissing(_ workspaceId: String?) -> Self {
        guard routeScope == nil else { return self }
        return Self(
            serverId: serverId,
            sessionId: sessionId,
            routeScope: Self.normalizedWorkspaceId(workspaceId).map(SessionRouteScope.workspace)
        )
    }

    private static func normalizedWorkspaceId(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

enum WorkspaceLinkedFileKind: Hashable {
    case workspaceFile(path: String, fileName: String)
    case sessionFile(path: String, fileName: String, sessionId: String)
    case hostFile(path: String, fileName: String)
}

struct WorkspaceLinkedFileNavTarget: Hashable {
    let serverId: String
    let workspaceId: String
    let worktreeId: String?
    let kind: WorkspaceLinkedFileKind
    let navigationContext: FileBrowserNavigationContext?
    let lineAnchor: SourceLineAnchor?
    let sourceSessionId: String?
    /// Declared control-session cwd for resolving relative owner-host paths.
    let controlSessionId: String?

    init(
        serverId: String,
        workspaceId: String,
        worktreeId: String? = nil,
        kind: WorkspaceLinkedFileKind,
        navigationContext: FileBrowserNavigationContext? = nil,
        lineAnchor: SourceLineAnchor? = nil,
        sourceSessionId: String? = nil,
        controlSessionId: String? = nil
    ) {
        self.serverId = serverId
        self.workspaceId = workspaceId
        self.worktreeId = worktreeId
        self.kind = kind
        self.navigationContext = navigationContext
        self.lineAnchor = lineAnchor
        self.sourceSessionId = sourceSessionId
        self.controlSessionId = controlSessionId
    }

    static func workspaceFile(
        serverId: String,
        workspaceId: String,
        worktreeId: String? = nil,
        path: String,
        fileName: String? = nil,
        navigationContext: FileBrowserNavigationContext? = nil,
        lineAnchor: SourceLineAnchor? = nil,
        sourceSessionId: String? = nil
    ) -> Self {
        let resolvedFileName: String
        if let fileName, !fileName.isEmpty {
            resolvedFileName = fileName
        } else {
            resolvedFileName = path.split(separator: "/").last.map(String.init) ?? path
        }

        return Self(
            serverId: serverId,
            workspaceId: workspaceId,
            worktreeId: worktreeId,
            kind: .workspaceFile(path: path, fileName: resolvedFileName),
            navigationContext: navigationContext,
            lineAnchor: lineAnchor,
            sourceSessionId: sourceSessionId
        )
    }

    static func sessionFile(
        serverId: String,
        workspaceId: String,
        sessionId: String,
        path: String,
        fileName: String? = nil,
        lineAnchor: SourceLineAnchor? = nil,
        sourceSessionId: String? = nil
    ) -> Self {
        let resolvedFileName: String
        if let fileName, !fileName.isEmpty {
            resolvedFileName = fileName
        } else {
            resolvedFileName = path.split(separator: "/").last.map(String.init) ?? path
        }
        return Self(
            serverId: serverId,
            workspaceId: workspaceId,
            kind: .sessionFile(path: path, fileName: resolvedFileName, sessionId: sessionId),
            lineAnchor: lineAnchor,
            sourceSessionId: sourceSessionId
        )
    }

    static func hostFile(
        serverId: String,
        workspaceId: String,
        path: String,
        fileName: String? = nil,
        lineAnchor: SourceLineAnchor? = nil,
        sourceSessionId: String? = nil,
        controlSessionId: String? = nil
    ) -> Self {
        let resolvedFileName: String
        if let fileName, !fileName.isEmpty {
            resolvedFileName = fileName
        } else {
            resolvedFileName = path.split(separator: "/").last.map(String.init) ?? path
        }

        return Self(
            serverId: serverId,
            workspaceId: workspaceId,
            kind: .hostFile(path: path, fileName: resolvedFileName),
            lineAnchor: lineAnchor,
            sourceSessionId: sourceSessionId,
            controlSessionId: controlSessionId
        )
    }
}

/// Utility destinations that live under the Workspaces navigation stack.
/// These are intentionally not bottom-tab destinations; they are secondary
/// management surfaces reached from the server/environment menu.
enum WorkspaceUtilityNavTarget: Hashable {
    case schedules
    case agents
    /// Placeholder roots; dedicated navigation destinations land with the catalog views.
    case skills
    case extensions
    case mcpServers
    case sshTerminal
    case manageServers
    /// The active host's CPU, memory, disk, and Oppi process over time.
    case serverMetrics
    case appSettings
}

struct WorkspaceCreateSheetContext: Identifiable {
    let server: PairedServer
    let presentation: WorkspaceCreatePresentation
    let openWorkspaceAfterCreate: Bool
    let prefillName: String?
    let prefillPath: String?

    var id: String {
        [
            server.id,
            presentation == .guidedFirstWorkspace ? "guided" : "standard",
            openWorkspaceAfterCreate ? "open" : "stay",
            prefillName ?? "",
            prefillPath ?? ""
        ].joined(separator: "|")
    }

    /// The create screen for this context, to present in a sheet with a
    /// navigation bar. `onCreate` takes the workspace it created.
    @MainActor
    func makeScreen(
        root: AppRootEnvironment,
        onCreate: ((Workspace) -> Void)? = nil
    ) -> WorkspaceCreateViewController {
        WorkspaceCreateViewController(
            root: root,
            server: server,
            presentation: presentation,
            prefillName: prefillName,
            prefillPath: prefillPath,
            onCreate: onCreate
        )
    }

    /// Presents the create screen in a sheet with a navigation bar, from a
    /// UIKit screen (the workspace sidebar). `onDismiss` runs after any dismissal.
    @MainActor
    func present(root: AppRootEnvironment, from presenter: UIViewController, onDismiss: @escaping () -> Void) {
        Router.present(
            makeScreen(root: root),
            presentation: .sheet.inNavigation(),
            from: presenter,
            theme: root.themeStore,
            onDismiss: onDismiss
        )
    }
}

extension View {
    func withServerScopedEnvironment(_ connection: ServerConnection) -> some View {
        self
            .environment(connection)
            .environment(\.apiClient, connection.apiClient)
            .environment(\.iconAssetCache, connection.iconAssetCache)
            .environment(connection.chatState)
            .environment(connection.sessionStore)
            .environment(connection.workspaceStore)
            .environment(connection.serverResourceStore)
            .environment(connection.askRequestStore)
            .environment(connection.audioPlayer)
            .environment(connection.gitStatusStore)
            .environment(connection.fileIndexStore)
            .environment(connection.messageQueueStore)
    }

    /// Presenter-local services for a screen pushed or presented from a review
    /// or chat screen. A hosted screen starts from the app root (the active
    /// server), so the presenter's own server, API client, and `AppNavigation`
    /// go on explicitly. The API client wins over the server's for fixtures.
    func presenterScope(
        connection: ServerConnection,
        apiClient: APIClient?,
        navigation: AppNavigation
    ) -> some View {
        environment(\.apiClient, apiClient)
            .withServerScopedEnvironment(connection)
            .environment(navigation)
    }
}

/// Which rail items stay on the short Duo outer display.
///
/// Items overflow from the bottom. Navigation outranks the frequent actions,
/// and an accessory leaves before either.
enum VerticalRailItemPriority: Equatable {
    case navigation
    case keep
    case overflowFirst
}

/// Reads `@Environment(\.toolbarVerticalEdge)` at the call site.
///
/// The value is the system's preferred edge, not "a pill is on screen". It is
/// nil where iOS never places a vertical bar (a regular iPhone, a full-screen
/// iPad) and non-nil on Duo's outer display even before a toolbar item joins
/// the rail. `verticalPreferred` items are what make the system draw that rail.
/// Below iOS 27.1 the edge is nil.
@MainActor
@ViewBuilder
func readingToolbarVerticalEdge<Content: View>(
    @ViewBuilder content: @escaping (HorizontalEdge?) -> Content
) -> some View {
    if #available(iOS 27.1, *) {
        ToolbarVerticalEdgeReader(content: content)
    } else {
        content(nil)
    }
}

@available(iOS 27.1, *)
private struct ToolbarVerticalEdgeReader<Content: View>: View {
    @Environment(\.toolbarVerticalEdge) private var edge
    @ViewBuilder var content: (HorizontalEdge?) -> Content

    var body: some View {
        content(edge)
    }
}
