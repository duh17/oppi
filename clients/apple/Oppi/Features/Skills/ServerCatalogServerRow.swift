import SwiftUI

/// Shared selected-server row for the separate Skills and Extensions catalogs.
/// One paired server is passive; multiple servers use the same menu semantics as
/// All Sessions and keep the current utility route selected while switching.
struct ServerCatalogServerRow: View {
    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(ServerStore.self) private var serverStore
    @Environment(AppNavigation.self) private var navigation

    let selectedServer: PairedServer
    let onSwitch: @MainActor (PairedServer) async -> Void

    private var servers: [PairedServer] {
        serverStore.servers
    }

    var body: some View {
        if servers.count > 1 {
            Menu {
                ForEach(servers) { server in
                    Button {
                        Task { @MainActor in
                            guard await coordinator.switchToServerReady(server) else { return }
                            await onSwitch(server)
                        }
                    } label: {
                        Label(
                            menuTitle(for: server),
                            systemImage: server.id == selectedServer.id
                                ? "checkmark.circle.fill"
                                : server.resolvedBadgeIcon.symbolName
                        )
                    }
                    .accessibilityValue(connectionState(for: server).title)
                }

                Divider()

                Button {
                    navigation.openHostSwitcherDestination(.usage, serverId: selectedServer.id)
                } label: {
                    Label(HostSwitcherDestination.usage.menuTitle, systemImage: HostSwitcherDestination.usage.systemImage)
                }
                .accessibilityIdentifier(HostSwitcherDestination.usage.accessibilityIdentifier)
            } label: {
                rowLabel(showsDisclosure: true)
            }
            .accessibilityLabel("Current server: \(selectedServer.name)")
            .accessibilityValue(connectionState(for: selectedServer).title)
            .accessibilityIdentifier("serverCatalog.server.menu")
        } else {
            rowLabel(showsDisclosure: false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Current server: \(selectedServer.name)")
                .accessibilityValue(connectionState(for: selectedServer).title)
                .accessibilityIdentifier("serverCatalog.server.passive")
        }
    }

    private func rowLabel(showsDisclosure: Bool) -> some View {
        HStack(spacing: 12) {
            RuntimeBadge(
                compact: false,
                icon: selectedServer.resolvedBadgeIcon,
                tint: connectionState(for: selectedServer).tintColor
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(selectedServer.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.themeFg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(connectionState(for: selectedServer).title)
                    .font(.caption)
                    .foregroundStyle(.themeComment)
            }

            if showsDisclosure {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.themeComment)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private func menuTitle(for server: PairedServer) -> String {
        let state = connectionState(for: server)
        return state == .connected ? server.name : "\(server.name) — \(state.title)"
    }

    private func connectionState(for server: PairedServer) -> ServerBadgeConnectionState {
        guard let connection = coordinator.connection(for: server.id) else {
            return .disconnected
        }
        let skillsFailed = connection.serverResourceStore
            .syncState(for: .skills, serverId: server.id).lastSyncFailed
        let extensionsFailed = connection.serverResourceStore
            .syncState(for: .extensions, serverId: server.id).lastSyncFailed
        return ServerBadgeConnectionState(
            WorkspaceServerStatusPresentation.derive(
                health: connection.serverHealth(forServer: server.id)
            ),
            hasSyncFailure: skillsFailed && extensionsFailed
        )
    }
}
