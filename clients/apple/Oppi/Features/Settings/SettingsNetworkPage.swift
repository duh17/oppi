import SwiftUI

struct SettingsNetworkPage: View {
    @AppStorage(AppPreferences.Experiments.sshTerminalKey) private var sshTerminalEnabled = false

    var body: some View {
        List {
            Section {
                NavigationLink {
                    TailnetSettingsView()
                } label: {
                    LabeledContent("Tailscale") {
                        Text(TailnetSettingsView.statusLabel(TailnetNodeController.shared.state))
                            .foregroundStyle(.themeComment)
                    }
                }
                .accessibilityIdentifier("settings.tailscale")
            } footer: {
                Text("Reach *.ts.net servers from Oppi without the Tailscale VPN app.")
            }

            if sshTerminalEnabled {
                Section {
                    NavigationLink("SSH Hosts") {
                        SSHTerminalHostListView()
                    }
                    .accessibilityIdentifier("settings.sshTerminal")
                } footer: {
                    Text("Experimental SSH terminal hosts.")
                }
            }
        }
        .settingsPage("Network")
    }
}
