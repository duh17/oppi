import SwiftUI

/// Detail view for a paired oppi server.
///
/// Shows server metadata, stats, security info, and management actions.
/// Data is fetched on-demand from `GET /server/info`.
struct ServerDetailView: View {
    let server: PairedServer

    @State private var info: ServerInfo?
    @State private var isLoading = true
    @State private var error: String?

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
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let info {
                Section("Server") {
                    LabeledContent("Host", value: "\(server.host):\(server.port)")
                    LabeledContent("Uptime", value: info.uptimeLabel)
                    LabeledContent("Platform", value: info.platformLabel)
                }

                Section("Stats") {
                    LabeledContent("Workspaces", value: String(info.stats.workspaceCount))
                    LabeledContent("Active Sessions", value: String(info.stats.activeSessionCount))
                    LabeledContent("Skills", value: String(info.stats.skillCount))
                }

            }

            Section("Connection") {
                LabeledContent("Paired", value: server.addedAt.formatted(date: .abbreviated, time: .shortened))
            }
        }
        .navigationTitle(server.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await load()
        }
        .task {
            await load()
        }
    }

    private func load() async {
        guard let baseURL = server.baseURL else {
            error = "Invalid server address"
            isLoading = false
            return
        }

        let api = APIClient(baseURL: baseURL, token: server.token)

        do {
            info = try await api.serverInfo()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }
}
