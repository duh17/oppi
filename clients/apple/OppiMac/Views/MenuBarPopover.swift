import AppKit
import SwiftUI

/// A compact companion for server status and app-level actions.
struct MenuBarPopover: View {
    let processManager: ServerProcessManager
    let healthMonitor: ServerHealthMonitor
    let sessionMonitor: MacSessionMonitor

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusLabel)
                        .fontWeight(.medium)
                    if let serverURL = healthMonitor.serverInfo?.serverURL {
                        Text(serverURL)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let summary = MenuBarStatsSummary.line(from: sessionMonitor.stats) {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("mac.menubar.statsSummary")
                    }
                }
                Spacer()
            }

            Divider()

            Button("Open Oppi") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut("o")

            Button("Server Stats...") {
                NotificationCenter.default.post(
                    name: .revealMacHostTool,
                    object: MacSettingsPane.stats
                )
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            .accessibilityIdentifier("mac.menubar.openStats")

            Divider()

            Button("Quit Oppi") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 280)
    }

    private var statusColor: Color {
        switch processManager.state {
        case .running: .green
        case .starting, .stopping: .yellow
        case .failed: .red
        case .stopped: .gray
        }
    }

    private var statusLabel: String {
        switch processManager.state {
        case .stopped: "Server Stopped"
        case .starting: "Server Starting..."
        case .running:
            processManager.processOwner == .externalProcess
                ? "Server Running (Background)"
                : "Server Running"
        case .stopping: "Server Stopping..."
        case .failed(let reason): "Server Failed: \(reason)"
        }
    }
}
