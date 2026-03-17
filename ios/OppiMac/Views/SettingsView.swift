import SwiftUI
import ServiceManagement
import Sparkle

/// Settings view with launch-at-login, server path info, and update check.
struct SettingsView: View {

    let processManager: ServerProcessManager
    let checkForUpdates: @MainActor () -> Void

    @State private var launchAtLogin = false
    @State private var loginItemStatus: SMAppService.Status = .notRegistered

    var body: some View {
        Form {
            Section("Launch") {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }

                if loginItemStatus == .requiresApproval {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text("Requires approval in System Settings > Login Items")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button("Open Login Items Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
            }

            Section("Server") {
                if let cliPath = ServerProcessManager.resolveServerCLIPath() {
                    LabeledContent("CLI Path") {
                        Text(cliPath)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                } else {
                    LabeledContent("CLI Path") {
                        Text("Not found")
                            .foregroundStyle(.secondary)
                    }
                }

                if let nodePath = ServerProcessManager.resolveNodePath() {
                    LabeledContent("Node.js") {
                        Text(nodePath)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }

            Section("Updates") {
                Button("Check for Updates...") {
                    checkForUpdates()
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .task {
            refreshLoginItemStatus()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            refreshLoginItemStatus()
        }
    }

    private func refreshLoginItemStatus() {
        loginItemStatus = SMAppService.mainApp.status
        launchAtLogin = loginItemStatus == .enabled
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Refresh to reflect actual state
        }
        refreshLoginItemStatus()
    }
}
