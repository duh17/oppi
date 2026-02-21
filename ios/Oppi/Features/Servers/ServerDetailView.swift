import SwiftUI

/// Detail view for a paired oppi server.
///
/// Shows server metadata, stats, security info, and management actions.
/// Data is fetched on-demand from `GET /server/info`.
struct ServerDetailView: View {
    let server: PairedServer

    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(AppNavigation.self) private var navigation
    @Environment(ServerStore.self) private var serverStore
    @Environment(\.dismiss) private var dismiss

    @State private var info: ServerInfo?
    @State private var isLoading = true
    @State private var error: String?
    @State private var showRemoveConfirmation = false

    private var pairedServer: PairedServer {
        serverStore.server(for: server.id) ?? server
    }

    var body: some View {
        List {
            if isLoading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("Loading server info…")
                        Spacer()
                    }
                }
            } else if let error {
                Section {
                    VStack(spacing: 8) {
                        Label("Unable to reach server", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.themeComment)
                    }
                }
            }

            if let info {
                Section("Server") {
                    LabeledContent("Host", value: "\(pairedServer.host):\(pairedServer.port)")
                    LabeledContent("Uptime", value: info.uptimeLabel)
                    LabeledContent("Platform", value: info.platformLabel)
                }

                Section("Stats") {
                    LabeledContent("Workspaces", value: String(info.stats.workspaceCount))
                    LabeledContent("Active Sessions", value: String(info.stats.activeSessionCount))
                    LabeledContent("Skills", value: String(info.stats.skillCount))
                }

            }

            Section("Badge") {
                HStack {
                    Text("Preview")
                    Spacer()
                    RuntimeBadge(
                        compact: true,
                        icon: pairedServer.resolvedBadgeIcon,
                        badgeColor: pairedServer.resolvedBadgeColor
                    )
                }

                Picker("Icon", selection: badgeIconSelection) {
                    ForEach(ServerBadgeIcon.allCases) { icon in
                        Label(icon.title, systemImage: icon.symbolName)
                            .tag(icon)
                    }
                }

                Picker("Color", selection: badgeColorSelection) {
                    ForEach(ServerBadgeColor.allCases) { color in
                        Text(color.title)
                            .tag(color)
                    }
                }
            }

            Section("Workspaces") {
                NavigationLink {
                    WorkspaceListView(server: pairedServer)
                } label: {
                    Label("Manage Workspaces", systemImage: "square.grid.2x2")
                }
            }

            Section("Connection") {
                LabeledContent("Paired", value: pairedServer.addedAt.formatted(date: .abbreviated, time: .shortened))
            }

            Section {
                Button(role: .destructive) {
                    showRemoveConfirmation = true
                } label: {
                    Label("Remove Paired Server", systemImage: "trash")
                }
            } header: {
                Text("Danger Zone")
            } footer: {
                Text("This only removes pairing from this iPhone. It does not delete the server or its data.")
            }
        }
        .navigationTitle(pairedServer.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await load()
        }
        .task {
            await load()
        }
        .confirmationDialog(
            removeDialogTitle,
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button(removeDialogButtonTitle, role: .destructive) {
                removeServer()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removeDialogMessage)
        }
    }

    private var badgeIconSelection: Binding<ServerBadgeIcon> {
        Binding(
            get: { pairedServer.resolvedBadgeIcon },
            set: { serverStore.setBadgeIcon(id: pairedServer.id, to: $0) }
        )
    }

    private var badgeColorSelection: Binding<ServerBadgeColor> {
        Binding(
            get: { pairedServer.resolvedBadgeColor },
            set: { serverStore.setBadgeColor(id: pairedServer.id, to: $0) }
        )
    }

    private var removingLastServer: Bool {
        serverStore.servers.count == 1 && serverStore.servers.first?.id == pairedServer.id
    }

    private var removeDialogTitle: String {
        if removingLastServer {
            return "Remove your only paired server?"
        }
        return "Remove \(pairedServer.name)?"
    }

    private var removeDialogButtonTitle: String {
        removingLastServer ? "Remove Last Server" : "Remove Server"
    }

    private var removeDialogMessage: String {
        if removingLastServer {
            return "This is the only paired server on this device. Removing it will disconnect Oppi and return you to onboarding. You'll need to pair again before using the app."
        }
        return "This removes the server from this iPhone only. It does not delete anything on the server, and you can pair it again later."
    }

    private func removeServer() {
        coordinator.removeServer(id: pairedServer.id)

        if serverStore.servers.isEmpty {
            navigation.showOnboarding = true
            return
        }

        dismiss()
    }

    private func load() async {
        guard let baseURL = pairedServer.baseURL else {
            error = "Invalid server address"
            isLoading = false
            return
        }

        let api = APIClient(baseURL: baseURL, token: pairedServer.token)

        do {
            info = try await api.serverInfo()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }
}
