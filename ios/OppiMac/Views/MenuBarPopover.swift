import SwiftUI

struct MenuBarPopover: View {

    let processManager: ServerProcessManager
    let healthMonitor: ServerHealthMonitor
    let permissionState: TCCPermissionState
    let sessionMonitor: MacSessionMonitor
    let checkForUpdates: @MainActor () -> Void

    @Environment(\.openWindow) private var openWindow
    @State private var selectedTab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {

            // Status header
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

            permissionsRow

            Divider()

            // Tab switcher
            Picker("", selection: $selectedTab) {
                Text("Sessions").tag(0)
                Text("Stats").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            // Tab content
            Group {
                if selectedTab == 0 {
                    SessionsTabView(monitor: sessionMonitor)
                } else {
                    Text("Coming soon")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 16)
                }
            }

            Divider()

            serverControls

            Divider()

            Button("Check for Updates...") {
                checkForUpdates()
            }

            Button("Show Oppi") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }

            Divider()

            Button("Quit Oppi") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 280)
    }

    // MARK: - Subviews

    @ViewBuilder
    private var permissionsRow: some View {
        if permissionState.requiredGranted {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.shield")
                    .foregroundStyle(.green)
                    .font(.caption)
                Text("Permissions: \(permissionState.summary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Button {
                if let url = TCCPermissionState.PermissionKind.fullDiskAccess.systemSettingsURL {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.shield")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text("Permissions: \(permissionState.summary)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
        }
    }

    @ViewBuilder
    private var serverControls: some View {
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
    }

    // MARK: - Helpers

    private var statusColor: Color {
        switch processManager.state {
        case .running:          .green
        case .starting:         .yellow
        case .failed:           .red
        case .stopped, .stopping: .gray
        }
    }

    private var statusLabel: String {
        switch processManager.state {
        case .stopped:              "Server Stopped"
        case .starting:             "Server Starting..."
        case .running:              "Server Running"
        case .stopping:             "Server Stopping..."
        case .failed(let reason):   "Server Failed: \(reason)"
        }
    }
}
