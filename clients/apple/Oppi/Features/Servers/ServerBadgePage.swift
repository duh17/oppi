import SwiftUI

/// Badge Icon: preview of this server's badge plus the icon grid. The preview
/// tint is the live connection state, as in the host switcher.
struct ServerBadgePage: View {
    let server: PairedServer

    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(ServerStore.self) private var serverStore

    private var selection: Binding<ServerBadgeIcon> {
        Binding(
            get: { server.resolvedBadgeIcon },
            set: { serverStore.setBadgeIcon(id: server.id, to: $0) }
        )
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Preview")
                    Spacer()
                    RuntimeBadge(
                        compact: false,
                        icon: server.resolvedBadgeIcon,
                        tint: HostSwitcherBadgeState.make(for: server, coordinator: coordinator).tintColor
                    )
                }

                BadgeIconGrid(selection: selection, tint: .themeBlue)
            } footer: {
                Text("Badge color reflects connection status: green connected, blue connecting, red disconnected.")
            }
        }
        .settingsPage("Badge Icon")
        .accessibilityIdentifier("server.badge.list")
    }
}
