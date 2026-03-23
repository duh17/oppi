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
    @State private var isUpdatingRuntime = false
    @State private var runtimeUpdateMessage: String?

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
                            .foregroundStyle(.themeOrange)
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

                if let runtime = info.runtimeUpdate {
                    Section("Runtime Updates") {
                        LabeledContent("Current", value: runtime.currentVersion)
                        LabeledContent("Latest", value: runtime.latestVersion ?? "Unknown")
                        LabeledContent("Status", value: runtimeStatusLabel(runtime))

                        if let checkError = runtime.checkError, !checkError.isEmpty {
                            Text(checkError)
                                .font(.caption)
                                .foregroundStyle(.themeComment)
                        }

                        if let lastUpdateError = runtime.lastUpdateError, !lastUpdateError.isEmpty {
                            Text(lastUpdateError)
                                .font(.caption)
                                .foregroundStyle(.themeRed)
                        }

                        if runtime.canUpdate {
                            Button(isUpdatingRuntime ? "Updating Runtime…" : "Update Runtime") {
                                Task {
                                    await updateRuntime()
                                }
                            }
                            .disabled(isUpdatingRuntime || runtime.updateInProgress)
                        } else {
                            Text("Runtime updates are unavailable on this host.")
                                .font(.caption)
                                .foregroundStyle(.themeComment)
                        }

                        if runtime.restartRequired {
                            Text("Restart server required to apply installed runtime update.")
                                .font(.caption)
                                .foregroundStyle(.themeOrange)
                        }

                        if let runtimeUpdateMessage {
                            Text(runtimeUpdateMessage)
                                .font(.caption)
                                .foregroundStyle(.themeComment)
                        }
                    }
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
        .themedListSurface()
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

    private func runtimeStatusLabel(_ runtime: ServerInfo.RuntimeUpdateInfo) -> String {
        if isUpdatingRuntime || runtime.updateInProgress {
            return "Updating…"
        }
        if runtime.restartRequired {
            return "Restart required"
        }
        if runtime.checking {
            return "Checking…"
        }
        if runtime.updateAvailable {
            return "Update available"
        }
        if runtime.checkError != nil {
            return "Check failed"
        }
        return "Up to date"
    }

    private func updateRuntime() async {
        guard let baseURL = pairedServer.baseURL else {
            runtimeUpdateMessage = "Invalid server address"
            return
        }

        let api = APIClient(
            baseURL: baseURL,
            token: pairedServer.token,
            tlsCertFingerprint: pairedServer.tlsCertFingerprint
        )

        isUpdatingRuntime = true
        defer { isUpdatingRuntime = false }

        do {
            let response = try await api.updateRuntime()
            runtimeUpdateMessage = response.result.message
            if !response.ok || !response.result.ok, let error = response.result.error {
                runtimeUpdateMessage = error
            }
            await load()
        } catch {
            runtimeUpdateMessage = error.localizedDescription
        }
    }

    private func load() async {
        guard let baseURL = pairedServer.baseURL else {
            error = "Invalid server address"
            isLoading = false
            return
        }

        let api = APIClient(
            baseURL: baseURL,
            token: pairedServer.token,
            tlsCertFingerprint: pairedServer.tlsCertFingerprint
        )

        do {
            info = try await api.serverInfo()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }
}
