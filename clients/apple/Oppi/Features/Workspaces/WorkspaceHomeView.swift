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

    var isReleaseEnabled: Bool {
        switch self {
        case .agents, .schedules, .skills, .extensions, .mcpServers, .sshTerminal,
             .manageServers, .serverMetrics, .appSettings:
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

    /// Presents `WorkspaceCreateView` in a sheet with a navigation bar, from a
    /// UIKit screen (the workspace sidebar). `onDismiss` runs after any dismissal.
    @MainActor
    func present(root: AppRootEnvironment, from presenter: UIViewController, onDismiss: @escaping () -> Void) {
        let context = self
        Router.present(
            root: root,
            presentation: .sheet.inNavigation(),
            from: presenter,
            onDismiss: onDismiss
        ) {
            WorkspaceCreateView(
                server: context.server,
                presentation: context.presentation,
                prefillName: context.prefillName,
                prefillPath: context.prefillPath
            )
        }
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

// MARK: - Server Switcher

enum HostSwitcherDestination: Hashable {
    case inbox
    case usage
    case serverMetrics
    case modelProviders
    case serverSettings

    static let allMenuItems: [Self] = [
        .modelProviders,
        .usage,
        .serverMetrics,
        .serverSettings,
    ]

    /// Server Metrics is opt-in: its row shows only once the server is known to
    /// sample. Server Settings is the on-ramp, so unknown hides it like off.
    static func menuItems(serverMetricsEnabled: Bool?) -> [Self] {
        serverMetricsEnabled == true ? allMenuItems : allMenuItems.filter { $0 != .serverMetrics }
    }

    var title: String {
        switch self {
        case .inbox: "All Sessions"
        case .usage: "Usage"
        case .serverMetrics: "Server Metrics"
        case .modelProviders: "Model Providers"
        case .serverSettings: "Server Settings"
        }
    }

    var menuTitle: String {
        switch self {
        case .inbox: title
        case .usage: "Usage"
        case .serverMetrics: "Server Metrics"
        case .modelProviders: "Model Providers"
        case .serverSettings: "Server Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .inbox: "tray.full"
        case .usage: "chart.bar"
        case .serverMetrics: "gauge.with.dots.needle.50percent"
        case .modelProviders: "cpu"
        case .serverSettings: "gearshape"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .inbox: "hostSwitcher.inbox"
        case .usage: "hostSwitcher.usage"
        case .serverMetrics: "hostSwitcher.serverMetrics"
        case .modelProviders: "workspace.modelProviders.open"
        case .serverSettings: "hostSwitcher.serverSettings"
        }
    }

    func shouldNavigate(from current: Self) -> Bool {
        self != current
    }
}

/// The server switcher in the Settings and admin toolbars. `HostSwitcherModel`
/// owns its rows and actions; the session lists draw the same model in UIKit
/// (`SessionListServerSwitcher`).
struct HostSwitcherMenu: View {
    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(ServerStore.self) private var serverStore
    @Environment(AppNavigation.self) private var navigation

    let current: PairedServer
    let destination: HostSwitcherDestination
    var fitsVerticalRail = false
    var onSwitch: ((PairedServer) -> Void)?

    var body: some View {
        let model = HostSwitcherModel(
            coordinator: coordinator,
            serverStore: serverStore,
            navigation: navigation,
            current: current,
            destination: destination,
            onSwitch: onSwitch
        )
        Menu {
            ForEach(model.servers) { server in
                Button {
                    model.switchHost(server)
                } label: {
                    Label(model.menuTitle(for: server), systemImage: model.menuImage(for: server))
                }
                .accessibilityValue(model.menuAccessibilityValue(for: server))
            }

            Section("Connection") {
                let connection = model.connection
                // Menu Labels render disabled. A Button keeps the healthy
                // checkmark on the same visual footing as the selected server.
                Button {
                    model.retryConnection()
                } label: {
                    Label(connection.title, systemImage: connection.systemImage)
                }
                .accessibilityLabel("Connection")
                .accessibilityValue(connection.title)
            }

            Divider()

            ForEach(model.destinations, id: \.self) { item in
                Button {
                    model.open(item)
                } label: {
                    Label(item.menuTitle, systemImage: item.systemImage)
                }
                .accessibilityIdentifier(item.accessibilityIdentifier)
            }
        } label: {
            ServerSwitcherPill(
                server: current,
                connectionState: model.badgeState(for: current),
                fitsVerticalRail: fitsVerticalRail,
                lockBadge: model.currentLockBadge
            )
        }
        .accessibilityLabel(model.accessibilityLabel)
        .accessibilityValue(model.badgeState(for: current).title)
        .task(id: current.id) {
            await model.loadServerMetricsEnabled()
        }
    }
}

/// The server switcher's one owner: the servers it lists, how each row reads,
/// the connection row, the destinations, and what choosing one does. The
/// SwiftUI menu (Settings and admin toolbars) and the session lists' UIKit
/// menu (`SessionListServerSwitcher`) only render it.
@MainActor
struct HostSwitcherModel {
    let coordinator: ConnectionCoordinator
    let serverStore: ServerStore
    let navigation: AppNavigation
    let current: PairedServer
    let destination: HostSwitcherDestination
    var onSwitch: ((PairedServer) -> Void)?

    private var locks: ScopedLockService { .shared }

    var servers: [PairedServer] { serverStore.servers }

    func badgeState(for server: PairedServer) -> ServerBadgeConnectionState {
        HostSwitcherBadgeState.make(for: server, coordinator: coordinator)
    }

    var currentLockBadge: ScopedLockState { locks.badge(.server(current.id)) }

    var accessibilityLabel: String { "Current server: \(current.name)" }

    func menuTitle(for server: PairedServer) -> String {
        let state = badgeState(for: server)
        return state == .connected ? server.name : "\(server.name) — \(state.title)"
    }

    /// Menu rows cannot draw a trailing badge, so a gated server's row uses
    /// the lock symbol as its image (the current server keeps its checkmark).
    func menuImage(for server: PairedServer) -> String {
        if server.id == current.id { return "checkmark.circle.fill" }
        switch locks.badge(.server(server.id)) {
        case .locked: return "lock.fill"
        case .unlocked: return "lock.open.fill"
        case .none: return server.resolvedBadgeIcon.symbolName
        }
    }

    func menuAccessibilityValue(for server: PairedServer) -> String {
        let state = badgeState(for: server).title
        switch locks.badge(.server(server.id)) {
        case .locked: return "\(state), Locked"
        case .unlocked: return "\(state), Unlocked"
        case .none: return state
        }
    }

    /// The Connection row: the current server's lane, and a retry when it is not connected.
    var connection: (title: String, systemImage: String, state: ServerBadgeConnectionState) {
        let state = badgeState(for: current)
        let title = ServerConnectionLanePresentation.title(
            server: current,
            connection: coordinator.connection(for: current.id),
            state: state,
            isPreparing: coordinator.preparingServerIds.contains(current.id)
        )
        return (title, state.systemImage, state)
    }

    func retryConnection() {
        guard badgeState(for: current) != .connected else { return }
        let coordinator = coordinator
        let serverId = current.id
        Task { await coordinator.retryServerConnection(serverId) }
    }

    var destinations: [HostSwitcherDestination] {
        HostSwitcherDestination.menuItems(
            serverMetricsEnabled: coordinator.connection(for: current.id)?.serverMetricsEnabled
        )
    }

    func open(_ item: HostSwitcherDestination) {
        guard item.shouldNavigate(from: destination) else { return }
        navigation.openHostSwitcherDestination(item, serverId: current.id)
    }

    func switchHost(_ server: PairedServer) {
        // Capture now: the unlock callback runs after this update.
        let coordinator = coordinator
        let onSwitch = onSwitch
        let perform: @MainActor () -> Void = {
            // Selection is local; a failed HTTPS bootstrap must not keep the old host selected.
            guard coordinator.restoreActiveServer(server.id) else { return }
            onSwitch?(server)
            Task {
                // Preparation updates this host's transport, never the current selection.
                await coordinator.prepareSelectedServerShell(for: server)
            }
        }
        // A locked server asks first; cancel keeps the current host.
        if locks.gate(.server(server.id), onUnlock: perform) {
            perform()
        }
    }

    /// Once per connection: a known value is never refetched.
    func loadServerMetricsEnabled() async {
        await coordinator.loadServerMetricsEnabledIfNeeded(for: current.id)
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
            isFocusedStreamRecovering: connection.isFocusedSessionStreamRecovering,
            hasConnectionEvidence: connection.hasViableConfiguredTransport
                || connection.workspaceStore.lastSuccessfulSyncAt != nil
                || connection.sessionStore.lastSuccessfulSyncAt != nil
        )
    }
}

struct ServerSwitcherPill: View {
    let server: PairedServer
    let connectionState: ServerBadgeConnectionState
    /// The toolbar button already draws the capsule, and the side rail button
    /// already draws the circle. A fill inside either one stacks a second pill.
    /// The menu's accessibility value still speaks the state word.
    var fitsVerticalRail = false
    var lockBadge: ScopedLockState = .none

    var body: some View {
        if fitsVerticalRail {
            verticalRailLabel
        } else {
            horizontalLabel
                .foregroundStyle(.themeFg)
        }
    }

    private var horizontalLabel: some View {
        HStack(spacing: 6) {
            statusBadge
            Text(server.name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            LockBadge(state: lockBadge)
            if connectionState != .connected {
                statusIndicator
                Text(connectionState.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(connectionState.tintColor)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.themeComment)
        }
    }

    /// The rail button already draws one circle. A badge or pill inside it
    /// stacks more rings, so this pose is only the status-colored icon.
    private var verticalRailLabel: some View {
        Image(systemName: server.resolvedBadgeIcon.symbolName)
            .font(.body.weight(.semibold))
            .foregroundStyle(connectionState.tintColor)
            .accessibilityHidden(true)
    }

    private var statusBadge: some View {
        RuntimeBadge(
            compact: true,
            icon: server.resolvedBadgeIcon,
            tint: connectionState.tintColor
        )
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if connectionState == .connecting || connectionState == .recovering {
            ProgressView()
                .controlSize(.mini)
                .tint(connectionState.tintColor)
        }
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

/// Moves a control onto the side rail when that rail exists. A pinned item
/// sits with the status cluster, under the wifi mark on Duo. A bottom-anchored
/// item starts from the rail's lower end; spacers cannot push a rail item down.
@ToolbarContentBuilder
func verticalRailToolbarItem<Content: View>(
    joinsVerticalRail: Bool,
    pinnedUnderStatus: Bool = false,
    anchorsToRailBottom: Bool = false,
    @ViewBuilder content: @escaping () -> Content
) -> some ToolbarContent {
    if #available(iOS 27.1, *), joinsVerticalRail {
        ToolbarItem(
            placement: anchorsToRailBottom
                ? .bottomBar
                : pinnedUnderStatus ? .topBarPinnedTrailing : .topBarTrailing,
            content: content
        )
        .axisBehavior(.verticalPreferred)
    } else {
        ToolbarItem(placement: .topBarTrailing, content: content)
    }
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

extension View {
    /// Host switcher on the side rail when the system has a vertical edge.
    @ViewBuilder
    func hostSwitcherRailToolbar(
        server: PairedServer,
        destination: HostSwitcherDestination
    ) -> some View {
        if #available(iOS 27.1, *) {
            modifier(HostSwitcherRailToolbar(server: server, destination: destination))
        } else {
            toolbar {
                verticalRailToolbarItem(joinsVerticalRail: false) {
                    HostSwitcherMenu(current: server, destination: destination)
                }
            }
        }
    }
}

@available(iOS 27.1, *)
private struct HostSwitcherRailToolbar: ViewModifier {
    let server: PairedServer
    let destination: HostSwitcherDestination
    @Environment(\.toolbarVerticalEdge) private var edge

    func body(content: Content) -> some View {
        let joinsRail = edge != nil
        content.toolbar {
            verticalRailToolbarItem(joinsVerticalRail: joinsRail) {
                HostSwitcherMenu(
                    current: server,
                    destination: destination,
                    fitsVerticalRail: joinsRail
                )
            }
        }
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
