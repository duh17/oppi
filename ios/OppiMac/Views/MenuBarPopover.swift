import SwiftUI

struct MenuBarPopover: View {

    let processManager: ServerProcessManager
    let healthMonitor: ServerHealthMonitor
    let permissionState: TCCPermissionState
    let checkForUpdates: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusLabel)
                    .font(.headline)
            }

            if let info = healthMonitor.serverInfo {
                Text(info.serverURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // TCC permission summary
            HStack(spacing: 4) {
                Image(systemName: permissionState.requiredGranted ? "checkmark.shield" : "exclamationmark.shield")
                    .foregroundStyle(permissionState.requiredGranted ? .green : .orange)
                    .font(.caption)
                Text("Permissions: \(permissionState.summary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            switch processManager.state {
            case .stopped, .failed:
                Button("Start Server") {
                    processManager.startWithDefaults()
                }
            case .running:
                Button("Restart Server") {
                    Task { await processManager.restart() }
                }
                Button("Stop Server") {
                    Task { await processManager.stop() }
                }
            case .starting, .stopping:
                Text("Please wait...")
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button("Check for Updates...") {
                checkForUpdates()
            }

            Button("Show Oppi") {
                if let url = URL(string: "oppiMac://main") {
                    NSWorkspace.shared.open(url)
                }
            }

            Divider()

            Button("Quit Oppi") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 240)
    }

    private var statusColor: Color {
        switch processManager.state {
        case .running: .green
        case .starting: .yellow
        case .failed: .red
        case .stopped, .stopping: .gray
        }
    }

    private var statusLabel: String {
        switch processManager.state {
        case .stopped: "Server Stopped"
        case .starting: "Server Starting..."
        case .running: "Server Running"
        case .stopping: "Server Stopping..."
        case .failed(let reason): "Server Failed: \(reason)"
        }
    }
}
