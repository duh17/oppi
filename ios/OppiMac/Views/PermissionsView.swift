import SwiftUI
import AppKit

/// Shows macOS TCC permission status and links to System Settings.
///
/// Auto-refreshes when the app becomes active (e.g. user returns from
/// granting a permission in System Settings).
struct PermissionsView: View {

    let permissionState: TCCPermissionState

    var body: some View {
        Form {
            Section {
                HStack {
                    Text(permissionState.summary)
                        .font(.headline)
                    Spacer()
                    if permissionState.requiredGranted {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }

            let required = permissionState.permissions.filter(\.required)
            if !required.isEmpty {
                Section("Required") {
                    ForEach(required) { permission in
                        PermissionRow(permission: permission)
                    }
                }
            }

            let optional = permissionState.permissions.filter { !$0.required }
            if !optional.isEmpty {
                Section("Optional") {
                    ForEach(optional) { permission in
                        PermissionRow(permission: permission)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Permissions")
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

private struct PermissionRow: View {

    let permission: TCCPermissionState.Permission

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                Text(permission.name)
                    .fontWeight(.medium)
                Spacer()
                Text(statusLabel)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(statusColor.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            Text(permission.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if permission.status != .granted,
               let url = permission.kind.systemSettingsURL {
                Button("Open System Settings") {
                    NSWorkspace.shared.open(url)
                }
                .controlSize(.small)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 2)
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

    private var statusLabel: String {
        switch permission.status {
        case .granted: "Granted"
        case .denied: "Not Granted"
        case .unknown: "Unknown"
        }
    }
}
