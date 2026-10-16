import SwiftUI

/// Native prompt for a pending pairing approval on an already-paired device.
/// Presented by the router in a navigation controller.
struct PairingApprovalPrompt: View {
    let presented: PairingApprovalController.Presented
    let onApprove: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(presented.approval.deviceName)
                .font(.title2.bold())
                .accessibilityIdentifier("pairing.approval.deviceName")

            factRow("Method", PairingApprovalPromptFormatting.method(presented.approval.method))
                .accessibilityIdentifier("pairing.approval.method")
            if let source = PairingApprovalPromptFormatting.source(presented.approval.source) {
                factRow("Source", source)
                    .accessibilityIdentifier("pairing.approval.source")
            }
            factRow("Requested", PairingApprovalPromptFormatting.timestamp(presented.approval.requestedAt))
                .accessibilityIdentifier("pairing.approval.requested")
            TimelineView(.periodic(from: .now, by: 1)) { context in
                factRow(
                    "Expires",
                    PairingApprovalPromptFormatting.expiry(
                        presented.approval.expiresAt,
                        now: context.date
                    )
                )
                .accessibilityIdentifier("pairing.approval.expiry")
            }

            Text(presented.serverName)
                .font(.footnote)
                .foregroundStyle(.themeComment)

            if let errorMessage = presented.errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.themeRed)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("pairing.approval.error")
            }

            Spacer(minLength: 8)

            Button("Approve") { onApprove() }
                .buttonStyle(.borderedProminent)
                .disabled(presented.isBusy)
                .accessibilityIdentifier("pairing.approval.approve")
            Button("Deny", role: .destructive) { onDeny() }
                .disabled(presented.isBusy)
                .accessibilityIdentifier("pairing.approval.deny")
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .navigationTitle("Approve New Device?")
        .navigationBarTitleDisplayMode(.inline)
        // A container element, so the identifier does not replace the rows'.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pairing.approval.prompt")
    }

    private func factRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.themeComment)
            Text(value)
                .font(.body)
                .foregroundStyle(.themeFg)
        }
    }
}

enum PairingApprovalPromptFormatting {
    static func method(_ raw: String) -> String {
        switch raw.lowercased() {
        case "invite": "Invite"
        case "tailscale": "Tailscale"
        case "custom": "Custom"
        default: raw
        }
    }

    static func source(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    static func timestamp(_ ms: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(ms) / 1_000)
            .formatted(date: .abbreviated, time: .shortened)
    }

    static func expiry(_ ms: Int64, now: Date) -> String {
        let remaining = max(0, TimeInterval(ms) / 1_000 - now.timeIntervalSince1970)
        let seconds = Int(remaining.rounded(.down))
        let minutes = seconds / 60
        let remainder = seconds % 60
        if minutes > 0 {
            return "In \(minutes):\(String(format: "%02d", remainder))"
        }
        return "In \(remainder)s"
    }
}

struct PairingApprovalPromptHost: ViewModifier {
    /// The host sits outside the root view that applies the app root, so it
    /// takes the root itself for the router.
    let root: AppRootEnvironment
    @Environment(\.scenePhase) private var scenePhase
    var controller: PairingApprovalController = .shared

    private var coordinator: ConnectionCoordinator { root.coordinator }

    func body(content: Content) -> some View {
        content
            .routerModal(
                isPresented: Binding(
                    get: { controller.presented != nil },
                    set: { isPresented in
                        if !isPresented {
                            controller.dismiss(snooze: true)
                        }
                    }
                ),
                presentation: .sheet.detents([.medium(), .large()]).inNavigation()
            ) {
                if let presented = controller.presented {
                    PairingApprovalPrompt(
                        presented: presented,
                        onApprove: {
                            Task {
                                await controller.approve(
                                    coordinator: coordinator,
                                    authenticate: { reason in
                                        await DeviceOwnerAuthentication.authenticate(reason: reason) == .success
                                    }
                                )
                            }
                        },
                        onDeny: {
                            Task { await controller.deny(coordinator: coordinator) }
                        }
                    )
                    .interactiveDismissDisabled(presented.isBusy)
                }
            }
            .environment(\.appRootEnvironment, root)
            .onAppear {
                controller.sync(coordinator: coordinator)
            }
            .onReceive(NotificationCenter.default.publisher(for: .pairingApprovalsDidChange)) { _ in
                controller.sync(coordinator: coordinator)
            }
            .onChange(of: pendingFingerprint) { _, _ in
                controller.sync(coordinator: coordinator)
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await controller.refreshAndSync(coordinator: coordinator) }
            }
    }

    private var pendingFingerprint: String {
        coordinator.connections
            .map { serverId, connection in
                let ids = connection.pendingPairingApprovals.map(\.id).joined(separator: ",")
                return "\(serverId):\(ids)"
            }
            .sorted()
            .joined(separator: "|")
    }

}
