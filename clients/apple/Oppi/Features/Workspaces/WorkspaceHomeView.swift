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
/// Production mounts `SessionInboxView`; this namespace keeps the existing
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

    func withWorkspaceIdIfMissing(_ workspaceId: String?) -> WorkspaceSessionNavTarget {
        guard routeScope == nil else { return self }
        return WorkspaceSessionNavTarget(
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

    init(
        serverId: String,
        workspaceId: String,
        worktreeId: String? = nil,
        kind: WorkspaceLinkedFileKind,
        navigationContext: FileBrowserNavigationContext? = nil,
        lineAnchor: SourceLineAnchor? = nil,
        sourceSessionId: String? = nil
    ) {
        self.serverId = serverId
        self.workspaceId = workspaceId
        self.worktreeId = worktreeId
        self.kind = kind
        self.navigationContext = navigationContext
        self.lineAnchor = lineAnchor
        self.sourceSessionId = sourceSessionId
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
    ) -> WorkspaceLinkedFileNavTarget {
        let resolvedFileName: String
        if let fileName, !fileName.isEmpty {
            resolvedFileName = fileName
        } else {
            resolvedFileName = path.split(separator: "/").last.map(String.init) ?? path
        }

        return WorkspaceLinkedFileNavTarget(
            serverId: serverId,
            workspaceId: workspaceId,
            worktreeId: worktreeId,
            kind: .workspaceFile(path: path, fileName: resolvedFileName),
            navigationContext: navigationContext,
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
        sourceSessionId: String? = nil
    ) -> WorkspaceLinkedFileNavTarget {
        let resolvedFileName: String
        if let fileName, !fileName.isEmpty {
            resolvedFileName = fileName
        } else {
            resolvedFileName = path.split(separator: "/").last.map(String.init) ?? path
        }

        return WorkspaceLinkedFileNavTarget(
            serverId: serverId,
            workspaceId: workspaceId,
            kind: .hostFile(path: path, fileName: resolvedFileName),
            lineAnchor: lineAnchor,
            sourceSessionId: sourceSessionId
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
    case manageServers
    case appSettings

    var isReleaseEnabled: Bool {
        switch self {
        case .schedules, .agents:
            ReleaseFeatures.agentAndScheduleManagementEnabled
        case .skills, .extensions, .manageServers, .appSettings:
            true
        }
    }
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
}

struct WorkspaceScopedDestinationView: View {
    @Environment(ConnectionCoordinator.self) private var coordinator
    let target: WorkspaceNavTarget

    @State private var scopedConnection: ServerConnection?

    var body: some View {
        Group {
            if let connection = scopedConnection {
                WorkspaceDetailView(workspace: target.workspace)
                    .withServerScopedEnvironment(connection)
            } else {
                ProgressView("Connecting…")
            }
        }
        .task(id: target.serverId) {
            guard await coordinator.switchToServerReady(target.serverId) else { return }
            scopedConnection = coordinator.connection(for: target.serverId)
        }
    }
}

struct WorkspaceSessionScopedDestinationView: View {
    @Environment(ConnectionCoordinator.self) private var coordinator
    let target: WorkspaceSessionNavTarget

    @State private var scopedConnection: ServerConnection?

    var body: some View {
        Group {
            if let connection = resolvedConnection {
                ChatView(
                    sessionId: target.sessionId,
                    serverIdHint: target.serverId,
                    workspaceIdHint: target.workspaceId,
                    routeScope: target.routeScope,
                    ownsWorkspacePathBackNavigation: true
                )
                .withServerScopedEnvironment(connection)
            } else {
                ProgressView("Connecting…")
            }
        }
        .task(id: target.serverId) {
            guard await coordinator.switchToServerReady(target.serverId) else { return }
            scopedConnection = coordinator.connection(for: target.serverId)
        }
    }

    /// Notification/deep-link open already awaited `switchToServerReady`.
    /// Reuse that connection immediately so ChatView can bind the normal
    /// session stream instead of sitting on "Connecting…".
    private var resolvedConnection: ServerConnection? {
        scopedConnection ?? coordinator.connection(for: target.serverId)
    }
}

struct WorkspaceFileBrowserDestinationView: View {
    @Environment(ConnectionCoordinator.self) private var coordinator
    let target: FileBrowserNavTarget

    @State private var scopedConnection: ServerConnection?

    private var targetServerId: String {
        target.serverId
    }

    private var resolvedConnection: ServerConnection? {
        scopedConnection
    }

    var body: some View {
        Group {
            if let connection = resolvedConnection {
                FileBrowserView(
                    serverId: targetServerId,
                    workspaceId: target.workspaceId,
                    worktreeId: target.worktreeId,
                    initialPath: target.path
                )
                .withServerScopedEnvironment(connection)
            } else {
                ProgressView("Connecting…")
            }
        }
        .task(id: targetServerId) {
            guard await coordinator.switchToServerReady(targetServerId) else { return }
            scopedConnection = coordinator.connection(for: targetServerId)
        }
    }
}

struct WorkspaceLinkedFileDestinationView: View {
    @Environment(ConnectionCoordinator.self) private var coordinator
    let target: WorkspaceLinkedFileNavTarget

    @State private var scopedConnection: ServerConnection?
    @State private var markdownViewportRestore = FullScreenMarkdownViewportRestoreState()

    var body: some View {
        Group {
            if let connection = scopedConnection {
                switch target.kind {
                case .workspaceFile(let path, let fileName):
                    workspaceFileContent(
                        path: path,
                        fileName: fileName,
                        workspaceRuntime: connection.workspaceStore.workspaces.first(where: { $0.id == target.workspaceId })?.runtime,
                        onLineAnchorNotice: { connection.extensionToast = $0 },
                        store: $markdownViewportRestore
                    )
                    .environment(\.reviewCommentSelectionScope, reviewCommentSelectionScope)
                    .withServerScopedEnvironment(connection)
                case .hostFile(let path, let fileName):
                    hostFileContent(
                        path: path,
                        fileName: fileName,
                        onLineAnchorNotice: { connection.extensionToast = $0 },
                        store: $markdownViewportRestore
                    )
                    .environment(\.reviewCommentSelectionScope, reviewCommentSelectionScope)
                    .withServerScopedEnvironment(connection)
                }
            } else {
                ProgressView("Connecting…")
            }
        }
        .background {
            if let addToChatDestination {
                ComposerCanvasDestinationAnchor(destination: addToChatDestination)
            }
        }
        .task(id: target.serverId) {
            guard await coordinator.switchToServerReady(target.serverId) else { return }
            scopedConnection = coordinator.connection(for: target.serverId)
        }
    }

    private var reviewCommentSelectionScope: ReviewCommentSelectionScope? {
        Self.reviewCommentSelectionScope(sourceSessionId: target.sourceSessionId)
    }

    private var addToChatDestination: ComposerCanvasDestination? {
        Self.capturedAddToChatDestination(
            sourceSessionId: target.sourceSessionId,
            current: ComposerCanvasActiveDestination.current
        )
    }

    private func workspaceFileContent(
        path: String,
        fileName: String,
        workspaceRuntime: WorkspaceRuntime?,
        onLineAnchorNotice: (@MainActor @Sendable (String) -> Void)?,
        store: Binding<FullScreenMarkdownViewportRestoreState>
    ) -> FileBrowserContentView {
        FileBrowserContentView(
            workspaceId: target.workspaceId,
            worktreeId: target.worktreeId,
            serverId: target.serverId,
            filePath: path,
            fileName: fileName,
            sessionId: target.sourceSessionId,
            workspaceRuntime: workspaceRuntime,
            navigationContext: target.navigationContext,
            lineAnchor: target.lineAnchor,
            onLineAnchorNotice: onLineAnchorNotice,
            markdownViewportRestore: FileBrowserContentView.restoreStore(
                for: .workspaceLinkedDestination,
                store: store
            ),
            addToChatDestination: addToChatDestination
        )
    }

    private func hostFileContent(
        path: String,
        fileName: String,
        onLineAnchorNotice: (@MainActor @Sendable (String) -> Void)?,
        store: Binding<FullScreenMarkdownViewportRestoreState>
    ) -> FileBrowserContentView {
        FileBrowserContentView(
            workspaceId: target.workspaceId,
            serverId: target.serverId,
            filePath: path,
            fileName: fileName,
            source: .hostFile,
            sessionId: target.sourceSessionId,
            lineAnchor: target.lineAnchor,
            onLineAnchorNotice: onLineAnchorNotice,
            markdownViewportRestore: FileBrowserContentView.restoreStore(
                for: .workspaceLinkedDestination,
                store: store
            ),
            addToChatDestination: addToChatDestination
        )
    }
}

extension WorkspaceLinkedFileDestinationView {
    static func reviewCommentSelectionScope(sourceSessionId: String?) -> ReviewCommentSelectionScope? {
        guard let sourceSessionId,
              let router = ReviewCommentSelectionActiveRouter.router(for: sourceSessionId) else {
            return nil
        }
        return .activeSession(router)
    }

    static func capturedAddToChatDestination(
        sourceSessionId: String?,
        current: ComposerCanvasDestination?
    ) -> ComposerCanvasDestination? {
        guard let sourceSessionId, let current, current.sessionId == sourceSessionId else {
            return nil
        }
        return current
    }
}

#if DEBUG
extension WorkspaceLinkedFileDestinationView {
    func debugWorkspaceFileContentForTesting(
        store: Binding<FullScreenMarkdownViewportRestoreState>
    ) -> FileBrowserContentView {
        guard case .workspaceFile(let path, let fileName) = target.kind else {
            preconditionFailure("debugWorkspaceFileContentForTesting requires a workspace file target")
        }
        return workspaceFileContent(
            path: path,
            fileName: fileName,
            workspaceRuntime: nil,
            onLineAnchorNotice: nil,
            store: store
        )
    }

    func debugHostFileContentForTesting(
        store: Binding<FullScreenMarkdownViewportRestoreState>
    ) -> FileBrowserContentView {
        guard case .hostFile(let path, let fileName) = target.kind else {
            preconditionFailure("debugHostFileContentForTesting requires a host file target")
        }
        return hostFileContent(
            path: path,
            fileName: fileName,
            onLineAnchorNotice: nil,
            store: store
        )
    }
}
#endif

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
}

// MARK: - Server Switcher

enum HostSwitcherDestination: Hashable {
    case inbox
    case usage
    case modelProviders
    case serverSettings

    static let menuItems: [HostSwitcherDestination] = [
        .modelProviders,
        .usage,
        .serverSettings,
    ]

    var title: String {
        switch self {
        case .inbox: "All Sessions"
        case .usage: "Usage"
        case .modelProviders: "Model Providers"
        case .serverSettings: "Server"
        }
    }

    var menuTitle: String {
        switch self {
        case .inbox: title
        case .usage: "Usage"
        case .modelProviders: "Model Providers"
        case .serverSettings: "Server Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .inbox: "tray.full"
        case .usage: "chart.bar"
        case .modelProviders: "cpu"
        case .serverSettings: "gearshape"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .inbox: "hostSwitcher.inbox"
        case .usage: "hostSwitcher.usage"
        case .modelProviders: "workspace.modelProviders.open"
        case .serverSettings: "hostSwitcher.serverSettings"
        }
    }

    func shouldNavigate(from current: HostSwitcherDestination) -> Bool {
        self != current
    }
}

struct HostSwitcherMenu: View {
    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(ServerStore.self) private var serverStore
    @Environment(AppNavigation.self) private var navigation

    let current: PairedServer
    let destination: HostSwitcherDestination
    var onSwitch: ((PairedServer) async -> Void)?

    private var servers: [PairedServer] {
        serverStore.servers
    }

    var body: some View {
        Menu {
            ForEach(servers) { server in
                Button {
                    Task { await switchHost(server) }
                } label: {
                    Label(
                        menuTitle(for: server),
                        systemImage: server.id == current.id
                            ? "checkmark.circle.fill"
                            : server.resolvedBadgeIcon.symbolName
                    )
                }
                .accessibilityValue(badgeState(for: server).title)
            }

            Section("Connection") {
                let state = badgeState(for: current)
                Label(
                    ServerConnectionLanePresentation.title(
                        server: current,
                        connection: coordinator.connection(for: current.id),
                        state: state,
                        isPreparing: coordinator.preparingServerIds.contains(current.id)
                    ),
                    systemImage: state.systemImage
                )

                if state != .connected {
                    Button {
                        Task { await coordinator.retryServerConnection(current.id) }
                    } label: {
                        Label("Retry Connection", systemImage: "arrow.clockwise")
                    }
                }
            }

            Divider()

            ForEach(HostSwitcherDestination.menuItems, id: \.self) { item in
                Button {
                    guard item.shouldNavigate(from: destination) else { return }
                    navigation.openHostSwitcherDestination(item, serverId: current.id)
                } label: {
                    Label(item.menuTitle, systemImage: item.systemImage)
                }
                .accessibilityIdentifier(item.accessibilityIdentifier)
            }
        } label: {
            ServerSwitcherPill(
                server: current,
                connectionState: badgeState(for: current)
            )
        }
        .accessibilityLabel("Current server: \(current.name)")
        .accessibilityValue(badgeState(for: current).title)
    }

    private func switchHost(_ server: PairedServer) async {
        if let onSwitch {
            await onSwitch(server)
            return
        }
        _ = await coordinator.switchToServerReady(server)
    }

    private func menuTitle(for server: PairedServer) -> String {
        let state = badgeState(for: server)
        return state == .connected ? server.name : "\(server.name) — \(state.title)"
    }

    private func badgeState(for server: PairedServer) -> ServerBadgeConnectionState {
        HostSwitcherBadgeState.make(for: server, coordinator: coordinator)
    }
}

enum HostSwitcherBadgeState {
    @MainActor
    static func make(
        for server: PairedServer,
        coordinator: ConnectionCoordinator
    ) -> ServerBadgeConnectionState {
        guard let connection = coordinator.connection(for: server.id) else {
            return ServerBadgeConnectionState(
                WorkspaceServerStatusPresentation.derive(
                    health: ServerHealth.derive(
                        freshnessState: .offline,
                        freshnessLabel: "Offline",
                        transportStates: [.disconnected],
                        hasCachedCatalog: false
                    )
                ),
                isPreparing: coordinator.preparingServerIds.contains(server.id)
            )
        }
        return ServerBadgeConnectionState(
            WorkspaceServerStatusPresentation.derive(
                health: connection.serverHealth(forServer: server.id)
            ),
            hasSyncFailure: connection.workspaceStore.lastSyncFailed
                || connection.sessionStore.lastSyncFailed,
            isPreparing: coordinator.preparingServerIds.contains(server.id),
            isFocusedStreamRecovering: connection.isFocusedSessionStreamRecovering
        )
    }
}

struct ServerSwitcherPill: View {
    let server: PairedServer
    let connectionState: ServerBadgeConnectionState

    var body: some View {
        HStack(spacing: 6) {
            RuntimeBadge(
                compact: true,
                icon: server.resolvedBadgeIcon,
                tint: connectionState.tintColor
            )

            Text(server.name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)

            if connectionState != .connected {
                if connectionState == .connecting || connectionState == .recovering {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(connectionState.tintColor)
                }
                Text(connectionState.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(connectionState.tintColor)
                    .lineLimit(1)
            }

            Image(systemName: "chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.themeComment)
        }
        .foregroundStyle(.themeFg)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.themeComment.opacity(0.14), in: Capsule())
    }
}

#if DEBUG
enum HostSwitcherPreviewData {
    static let server: PairedServer = {
        let credentials = ServerCredentials(
            host: "mac-studio.local",
            port: 7749,
            token: "sk_preview",
            name: "mac-studio",
            serverFingerprint: "sha256:preview-host"
        )
        guard let server = PairedServer(from: credentials, sortOrder: 0) else {
            preconditionFailure("HostSwitcherPreviewData requires a server fingerprint")
        }
        return server
    }()
}
#endif
