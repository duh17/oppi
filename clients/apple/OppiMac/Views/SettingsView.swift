import SwiftUI
import ServiceManagement
import Sparkle

/// Settings view with launch-at-login, server path info, and update check.
struct SettingsView: View {

    let processManager: ServerProcessManager
    let checkForUpdates: @MainActor () -> Void
    var apiClient: MacAPIClient?

    @State private var launchAtLogin = false
    @State private var loginItemStatus: SMAppService.Status = .notRegistered
    @State private var depUpdateState: DepUpdateState = .idle

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

            Section("Server Dependencies") {
                switch depUpdateState {
                case .idle:
                    Button("Update Server Dependencies") {
                        runDepUpdate()
                    }
                    .disabled(apiClient == nil)

                case .running:
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Updating dependencies...")
                            .foregroundStyle(.secondary)
                    }

                case .success(let result):
                    if let packages = result.updatedPackages, !packages.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("\(packages.count) package(s) updated", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            ForEach(packages, id: \.name) { pkg in
                                Text("\(pkg.name): \(pkg.from) -> \(pkg.to)")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            if result.restartRequired {
                                Label("Restart server to apply", systemImage: "arrow.clockwise")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    } else {
                        Label("All dependencies up to date", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }

                    Button("Check Again") {
                        depUpdateState = .idle
                    }
                    .controlSize(.small)

                case .failed(let message):
                    Label(message, systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)

                    Button("Retry") {
                        runDepUpdate()
                    }
                    .controlSize(.small)
                }
            }

            Section("App Updates") {
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

    private func runDepUpdate() {
        guard let client = apiClient else { return }
        depUpdateState = .running

        Task.detached {
            let result = await client.updateDependencies()
            await MainActor.run {
                if let result {
                    depUpdateState = result.ok
                        ? .success(result)
                        : .failed(result.message)
                } else {
                    depUpdateState = .failed("Could not reach server")
                }
            }
        }
    }
}

private enum DepUpdateState {
    case idle
    case running
    case success(RuntimeUpdateResult)
    case failed(String)
}
