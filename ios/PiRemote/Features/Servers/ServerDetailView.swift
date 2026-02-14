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
                    LabeledContent("Host", value: server.host)
                    LabeledContent("Port", value: String(server.port))
                    LabeledContent("Uptime", value: info.uptimeLabel)
                    LabeledContent("Platform", value: info.platformLabel)
                    LabeledContent("Pi Version", value: info.piVersion)
                    LabeledContent("Server Version", value: info.version)
                    LabeledContent("Node", value: info.nodeVersion)
                }

                Section("Stats") {
                    LabeledContent("Workspaces", value: String(info.stats.workspaceCount))
                    LabeledContent("Active Sessions", value: String(info.stats.activeSessionCount))
                    LabeledContent("Total Sessions", value: String(info.stats.totalSessionCount))
                    LabeledContent("Skills", value: String(info.stats.skillCount))
                    LabeledContent("Models", value: String(info.stats.modelCount))
                }

                if let identity = info.identity {
                    Section("Security") {
                        if let profile = server.securityProfile {
                            LabeledContent("Profile", value: profile)
                        }
                        LabeledContent("Algorithm", value: identity.algorithm)
                        LabeledContent("Key ID", value: identity.keyId)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Fingerprint")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack {
                                Text(identity.fingerprint)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                Spacer()
                                Button {
                                    UIPasteboard.general.string = identity.fingerprint
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .font(.caption)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }

            Section("Connection") {
                LabeledContent("Paired", value: server.addedAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Server ID", value: String(server.id.prefix(24)) + "…")
                    .font(.caption.monospaced())
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
