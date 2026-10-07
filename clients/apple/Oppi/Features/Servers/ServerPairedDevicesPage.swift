import SwiftUI

/// Devices paired with this server, with Revoke for every device but this one.
struct ServerPairedDevicesPage: View {
    let model: ServerSettingsModel
    let server: PairedServer

    @State private var showRevokeConfirmation = false
    @State private var devicePendingRevoke: PairedDeviceRoster.Row?

    private var state: ServerDetailPairedDevicesState {
        model.pairedDevicesState(currentDeviceId: server.deviceCredential?.deviceId)
    }

    var body: some View {
        List {
            Section {
                switch state {
                case .loading:
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .accessibilityIdentifier("server.pairedDevices.loading")
                case .loaded(let rows, let error):
                    if rows.isEmpty {
                        Text("No paired devices")
                            .foregroundStyle(.themeComment)
                    } else {
                        ForEach(rows) { row in
                            deviceRow(row)
                        }
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.themeOrange)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("server.pairedDevices.error")
                    }
                case .failed(let message):
                    VStack(alignment: .leading, spacing: 6) {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.themeOrange)
                        Button("Retry") {
                            Task { await model.reloadPairedDevices() }
                        }
                    }
                    .accessibilityIdentifier("server.pairedDevices.error")
                }
            } footer: {
                Text("Every paired device can see this list. Revoking disconnects that device immediately.")
            }
        }
        .settingsPage("Paired Devices")
        .accessibilityIdentifier("server.pairedDevices.list")
        .refreshable {
            await model.reloadPairedDevices()
        }
        .confirmationDialog(
            revokeTitle,
            isPresented: $showRevokeConfirmation,
            titleVisibility: .visible
        ) {
            Button("Revoke", role: .destructive) {
                if let row = devicePendingRevoke {
                    Task {
                        if await AppLockService.shared.authorizeProtectedAction(
                            reason: String(localized: "Revoke \(row.title)")
                        ) {
                            await model.revokeDevice(row)
                        }
                        devicePendingRevoke = nil
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                devicePendingRevoke = nil
            }
        } message: {
            Text("\(devicePendingRevoke?.title ?? "That device") will lose access immediately. Pair it again to restore access.")
        }
    }

    private var revokeTitle: String {
        if let title = devicePendingRevoke?.title, !title.isEmpty {
            return "Revoke \(title)?"
        }
        return "Revoke this device?"
    }

    @ViewBuilder
    private func deviceRow(_ row: PairedDeviceRoster.Row) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .foregroundStyle(.themeFg)
                Text(caption(row))
                    .font(.caption)
                    .foregroundStyle(.themeComment)
            }
            // Group only the text: a container-level identifier or label would also
            // overwrite the Revoke button's.
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(
                row.isThisDevice ? "server.pairedDevices.thisDevice" : "server.pairedDevices.row.\(row.id)"
            )
            Spacer(minLength: 8)
            if row.canRevoke {
                Button("Revoke", role: .destructive) {
                    devicePendingRevoke = row
                    showRevokeConfirmation = true
                }
                .buttonStyle(.borderless)
                .font(.footnote)
                .disabled(model.isRevokingDevice)
                .accessibilityLabel("Revoke \(row.title)")
                .accessibilityIdentifier("server.pairedDevices.revoke.\(row.id)")
            }
        }
    }

    private func caption(_ row: PairedDeviceRoster.Row) -> String {
        if row.isThisDevice {
            return "This device"
        }
        guard let lastUsedAt = row.lastUsedAt else {
            return "Never used"
        }
        let date = Date(timeIntervalSince1970: TimeInterval(lastUsedAt) / 1_000)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Last used \(formatter.localizedString(for: date, relativeTo: Date()))"
    }
}
