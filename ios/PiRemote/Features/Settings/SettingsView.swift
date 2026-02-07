import SwiftUI

struct SettingsView: View {
    @Environment(ServerConnection.self) private var connection
    @Environment(AppNavigation.self) private var navigation

    var body: some View {
        List {
            Section("Server") {
                if let creds = connection.credentials {
                    LabeledContent("Host", value: creds.host)
                    LabeledContent("Port", value: String(creds.port))
                } else {
                    Text("Not connected")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Circle()
                        .fill(connection.isConnected ? .green : .red)
                        .frame(width: 8, height: 8)
                    Text(connection.isConnected ? "Connected" : "Disconnected")
                        .font(.subheadline)
                }
            }

            Section("Workspaces") {
                NavigationLink {
                    WorkspaceListView()
                } label: {
                    Label("Manage Workspaces", systemImage: "square.grid.2x2")
                }
            }

            Section("Account") {
                Button("Disconnect & Sign Out", role: .destructive) {
                    signOut()
                }
            }

            Section("About") {
                LabeledContent("Version", value: "1.0.0")
                LabeledContent("Build", value: "Phase 1")
            }
        }
        .navigationTitle("Settings")
    }

    private func signOut() {
        connection.disconnectSession()
        KeychainService.deleteCredentials()
        navigation.showOnboarding = true
    }
}
