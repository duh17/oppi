import Foundation

// The server switcher's model and its destinations. `HostSwitcherModel` owns the
// rows and actions; the UIKit menu (`SessionListServerSwitcher`) renders it for the
// session lists, Model Providers, Server Metrics, Usage, and Server Settings.

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

/// The server switcher's one owner: the servers it lists, how each row reads,
/// the connection row, the destinations, and what choosing one does. The
/// UIKit menu (`SessionListServerSwitcher`) only renders it.
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

    /// The bar's switcher, on the rail or as the pill. Tests find it by this id and read the
    /// current server from its label.
    static let switcherIdentifier = "server.switcher"

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
