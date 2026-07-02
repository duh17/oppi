import SwiftUI

struct LocalServerShellList: View {
    let processManager: ServerProcessManager
    let healthMonitor: ServerHealthMonitor
    let permissionState: TCCPermissionState

    var body: some View {
        List {
            Section("Status") {
                Label(statusText, systemImage: statusIcon)
                Label(healthMonitor.isHealthy ? "Health check passed" : "Waiting for health", systemImage: "heart.text.square")
                Label("Permissions: \(permissionState.summary)", systemImage: "lock.shield")
                if let info = healthMonitor.serverInfo {
                    Label(info.serverURL, systemImage: "link")
                    Label("Version \(info.version)", systemImage: "number")
                }
            }
        }
        .navigationTitle("Local Server")
    }

    private var statusText: String {
        switch processManager.state {
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .running: processManager.processOwner == .externalProcess ? "Attached to background server" : "Running"
        case .stopping: "Stopping"
        case .failed(let message): "Failed: \(message)"
        }
    }

    private var statusIcon: String {
        switch processManager.state {
        case .running: "checkmark.circle"
        case .starting, .stopping: "clock"
        case .failed: "exclamationmark.triangle"
        case .stopped: "circle"
        }
    }
}

struct RemoteServersShellList: View {
    let processManager: ServerProcessManager
    let healthMonitor: ServerHealthMonitor
    let store: MacRemoteServerStore

    var body: some View {
        List {
            Section("Primary") {
                Label(localStatusText, systemImage: "desktopcomputer")
                if let info = healthMonitor.serverInfo {
                    Label(info.serverURL, systemImage: "link")
                } else {
                    Label("https://localhost:7749", systemImage: "link")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Remote") {
                if store.servers.isEmpty {
                    Label("No remote servers saved", systemImage: "network")
                        .foregroundStyle(.secondary)
                    Text("Save a URL in the detail pane to keep remote attachment ready without changing the local-first default.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.servers) { server in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.displayName)
                                Text(server.url.absoluteString)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "network")
                        }
                    }
                }
            }
        }
        .navigationTitle("Servers")
    }

    private var localStatusText: String {
        switch processManager.state {
        case .stopped: "Local server stopped"
        case .starting: "Local server starting"
        case .running: "Local server connected"
        case .stopping: "Local server stopping"
        case .failed: "Local server needs attention"
        }
    }
}

struct RemoteServersDetail: View {
    let processManager: ServerProcessManager
    let healthMonitor: ServerHealthMonitor
    let store: MacRemoteServerStore

    @State private var remoteURL = ""
    @State private var nickname = ""

    var body: some View {
        Form {
            Section("Local-first connection") {
                LabeledContent("Primary server") {
                    Text(localServerLabel)
                }
                LabeledContent("Role") {
                    Text("Default workspace, session, and admin source")
                }
                if let info = healthMonitor.serverInfo {
                    LabeledContent("URL") {
                        Text(info.serverURL)
                            .textSelection(.enabled)
                    }
                    LabeledContent("Version") {
                        Text(info.version)
                    }
                }
            }

            Section {
                TextField("Nickname", text: $nickname)
                TextField("https://example.com:7749", text: $remoteURL)
                HStack {
                    Button("Save Remote Server") {
                        store.add(nickname: nickname, urlText: remoteURL)
                        if store.lastError == nil {
                            nickname = ""
                            remoteURL = ""
                        }
                    }
                    .disabled(remoteURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text("Credentials and active remote switching come next; this stores the server source without replacing local admin.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = store.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Remote server attachment")
            } footer: {
                Text("The Mac client stays useful with only the local server. Remote servers attach beside the local source and feed the same Workspaces and Sessions views, not pairing or local admin.")
            }

            if !store.servers.isEmpty {
                Section("Saved remote servers") {
                    ForEach(store.servers) { server in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.displayName)
                                    .fontWeight(.medium)
                                Text(server.url.absoluteString)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            Button("Remove") {
                                store.remove(server)
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Remote Servers")
    }

    private var localServerLabel: String {
        switch processManager.state {
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .running: processManager.processOwner == .externalProcess ? "Attached" : "Running"
        case .stopping: "Stopping"
        case .failed(let message): "Failed: \(message)"
        }
    }
}

struct MacToolSummaryList: View {
    let title: String
    let rows: [MacToolSummaryRow]

    var body: some View {
        List {
            Section(title) {
                ForEach(rows) { row in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title)
                            Text(row.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: row.systemImage)
                    }
                }
            }
        }
        .navigationTitle(title)
    }
}

struct MacToolSummaryRow: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let systemImage: String

    init(title: String, subtitle: String, systemImage: String) {
        self.id = title
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
    }
}

struct MacShellEmptyDetail: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
