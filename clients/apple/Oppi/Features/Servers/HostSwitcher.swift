import Foundation
import UIKit

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

    func badgeState(for server: PairedServer) -> ServerBadgeConnectionState {
        HostSwitcherBadgeState.make(for: server, coordinator: coordinator)
    }

    var currentLockBadge: ScopedLockState { locks.badge(.server(current.id)) }

    /// The bar's switcher, on the rail or as the pill. Tests find it by this id and read the
    /// current server from its label.
    static let switcherIdentifier = "server.switcher"

    var accessibilityLabel: String { "Current server: \(current.name)" }

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

    /// Makes `server` the active one. `ServerSwitchMenu` asks for the lock
    /// before it calls this, and this asks again: the guarantee must not rest
    /// on every caller remembering to. A second ask is harmless, because an
    /// unlocked server passes at once.
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

/// Every menu that lists paired servers: the session lists' switcher, a catalog
/// list's server row, and the locked cover's switch button. One owner for how a
/// server's row reads (its badge, a gated server's lock, the current server's
/// checkmark) and for what choosing one does (ask for its lock, then the
/// caller's activation). Rows are built each time the menu opens, so they list
/// current states and artwork.
@MainActor
struct ServerSwitchMenu {
    let coordinator: ConnectionCoordinator
    /// The server the menu marks as current. The menu's own checkmark says so,
    /// so that row keeps its badge.
    var currentServerId: String?
    /// A server the menu leaves out (a cover that is already that server).
    var omitting: String?
    /// The rows the caller adds after the servers: Connection, Usage, the
    /// switcher's destinations.
    var extras: () -> [UIMenuElement] = { [] }
    /// What choosing a server means. Runs once the server's lock is open.
    var activate: (PairedServer) -> Void

    private var locks: ScopedLockService { .shared }

    /// A menu whose rows are read when it opens.
    static func menu(_ elements: @escaping @MainActor () -> [UIMenuElement]) -> UIMenu {
        UIMenu(children: [UIDeferredMenuElement.uncached { completion in
            completion(elements())
        }])
    }

    func elements() -> [UIMenuElement] {
        let servers: [UIMenuElement] = coordinator.serverStore.servers
            .filter { $0.id != omitting }
            .map(row)
        return [UIMenu(options: .displayInline, children: servers)] + extras()
    }

    private func row(_ server: PairedServer) -> UIAction {
        let state = HostSwitcherBadgeState.make(for: server, coordinator: coordinator)
        let title = state == .connected ? server.name : "\(server.name) — \(state.title)"
        let action = UIAction.choice(
            title,
            .server(server.id, server.resolvedBadgeIcon),
            selected: server.id == currentServerId,
            assets: nil
        ) { [self] in choose(server) }
        // A menu cannot draw a trailing badge, so a gated server's row wears its
        // lock instead of its badge.
        let gate = locks.badge(.server(server.id))
        switch gate {
        case .locked: action.image = EntityIcon.menuMark("lock.fill")
        case .unlocked: action.image = EntityIcon.menuMark("lock.open.fill")
        case .none: break
        }
        action.accessibilityValue = switch gate {
        case .locked: "\(state.title), Locked"
        case .unlocked: "\(state.title), Unlocked"
        case .none: state.title
        }
        return action
    }

    private func choose(_ server: PairedServer) {
        let activate = activate
        // A locked server asks first; cancel keeps the current host.
        if locks.gate(.server(server.id), onUnlock: { activate(server) }) {
            activate(server)
        }
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
