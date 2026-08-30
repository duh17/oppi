import SwiftUI

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
        .themedListSurface()
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

struct MacShellEmptyDetail: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(.themeFg)
            .background {
                Rectangle()
                    .fill(.themeBg)
                    .ignoresSafeArea()
            }
    }
}

struct MacSidebarUtilityList: View {
    let section: MacSidebarSection

    var body: some View {
        MacCatalogListColumn(section: section)
            .themedListSurface()
    }
}

struct MacSidebarUtilityDetail: View {
    let section: MacSidebarSection

    var body: some View {
        MacCatalogDetailColumn(section: section)
            .themedScrollSurface()
    }
}
