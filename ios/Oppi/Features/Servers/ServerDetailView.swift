import SwiftUI

/// Detail view for a paired oppi server.
///
/// Shows server metadata, stats, security info, and management actions.
/// Data is fetched on-demand from `GET /server/info`.
struct ServerDetailView: View {
    let server: PairedServer

    @Environment(ServerStore.self) private var serverStore

    @State private var info: ServerInfo?
    @State private var isLoading = true
    @State private var error: String?

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
                    WorkspaceListView()
                } label: {
                    Label("Manage Workspaces", systemImage: "square.grid.2x2")
                }
            }

            Section("Connection") {
                LabeledContent("Paired", value: pairedServer.addedAt.formatted(date: .abbreviated, time: .shortened))
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
