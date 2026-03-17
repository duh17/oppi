import SwiftUI
import AppKit

/// Step 2: Guide the user to grant required TCC permissions (primarily Full Disk Access).
struct PermissionsStepView: View {

    let permissionState: TCCPermissionState
    let onContinue: () -> Void
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                Text("macOS Permissions")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Oppi needs Full Disk Access so the server can read workspace files in protected folders like ~/Desktop and ~/Documents.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
            }
            .padding(.top, 24)

            Spacer()

            VStack(alignment: .leading, spacing: 12) {
                ForEach(permissionState.permissions) { permission in
                    PermissionStepRow(permission: permission)
                }
            }
            .frame(maxWidth: 400)

            Spacer()

            HStack {
                Button("Back") {
                    onBack()
                }
                Spacer()
                Button("Continue") {
                    onContinue()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!permissionState.requiredGranted)
            }
            .padding(20)
        }
        .task {
            await permissionState.refresh()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            Task { await permissionState.refresh() }
        }
    }
}

// MARK: - Row

private struct PermissionStepRow: View {

    let permission: TCCPermissionState.Permission

    var body: some View {
        HStack {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(permission.name)
                        .fontWeight(.medium)
                    Text(permission.required ? "Required" : "Optional")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            permission.required
                                ? Color.orange.opacity(0.2)
                                : Color.secondary.opacity(0.15)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                Text(permission.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if permission.status != .granted,
               let url = permission.kind.systemSettingsURL {
                Button("Grant") {
                    NSWorkspace.shared.open(url)
                }
                .controlSize(.small)
            }
        }
    }

    private var statusIcon: String {
        switch permission.status {
        case .granted: "checkmark.circle.fill"
        case .denied: "xmark.circle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    private var statusColor: Color {
        switch permission.status {
        case .granted: .green
        case .denied: .red
        case .unknown: .secondary
        }
    }
}
