import SwiftUI

/// Native prompt for a pending pairing approval on an already-paired device.
/// Presented by the router in a navigation controller.
struct PairingApprovalPrompt: View {
    let presented: PairingApprovalController.Presented
    let onApprove: () -> Void
    let onDeny: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                factsCard
            }
            .padding(.horizontal)
            .padding(.top, 4)
        }
        .scrollBounceBehavior(.basedOnSize)
        // The theme surface, so every theme color is drawn on the background
        // it was designed for, not the system sheet material.
        .themedScrollSurface()
        // Actions stay pinned under the scrolling body, so they are reachable
        // whatever the detent or text size.
        .safeAreaInset(edge: .bottom, spacing: 0) { actions }
        .navigationTitle("Approve New Device?")
        .navigationBarTitleDisplayMode(.inline)
        // A container element, so the identifier does not replace the rows'.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pairing.approval.prompt")
    }

    private var header: some View {
        VStack(spacing: 2) {
            Image(systemName: PairingApprovalPromptFormatting.deviceSymbol(presented.approval.deviceName))
                .font(.system(size: 32))
                .foregroundStyle(.themeBlue)
                .padding(.bottom, 2)
                .accessibilityHidden(true)
            Text(presented.approval.deviceName)
                .font(.title2.bold())
                .foregroundStyle(.themeFg)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("pairing.approval.deviceName")
            Text("wants to pair with \(presented.serverName)")
                .font(.subheadline)
                .foregroundStyle(.themeFgDim)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("pairing.approval.server")
        }
        .frame(maxWidth: .infinity)
    }

    private var factsCard: some View {
        VStack(spacing: 0) {
            factRow("Method", PairingApprovalPromptFormatting.method(presented.approval.method))
                .accessibilityIdentifier("pairing.approval.method")
            if let source = PairingApprovalPromptFormatting.source(presented.approval.source) {
                Divider()
                factRow("Source", source)
                    .accessibilityIdentifier("pairing.approval.source")
            }
            Divider()
            factRow("Requested", PairingApprovalPromptFormatting.timestamp(presented.approval.requestedAt))
                .accessibilityIdentifier("pairing.approval.requested")
            Divider()
            TimelineView(.periodic(from: .now, by: 1)) { context in
                factRow(
                    "Expires",
                    PairingApprovalPromptFormatting.expiry(
                        presented.approval.expiresAt,
                        now: context.date
                    )
                )
                .monospacedDigit()
                .accessibilityIdentifier("pairing.approval.expiry")
            }
        }
        .padding(.horizontal)
        .themedSurface(.opaqueCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var actions: some View {
        VStack(spacing: 10) {
            // Pinned with the buttons: in the medium detent the body can
            // scroll, and a failure must not sit below the fold.
            if let errorMessage = presented.errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.themeRed)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .accessibilityIdentifier("pairing.approval.error")
            }
            Button {
                onApprove()
            } label: {
                HStack(spacing: 8) {
                    if presented.isBusy {
                        ProgressView()
                    }
                    Text("Approve")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.themeBlue)
            .controlSize(.large)
            .disabled(presented.isBusy)
            .accessibilityIdentifier("pairing.approval.approve")

            Button(role: .destructive) {
                onDeny()
            } label: {
                Text("Deny")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.themeRed)
            .controlSize(.large)
            .disabled(presented.isBusy)
            .accessibilityIdentifier("pairing.approval.deny")
        }
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 4)
        // Opaque, so the body scrolls under the pinned actions instead of
        // showing through the error text.
        .background(.themeBg)
    }

    private func factRow(_ label: String, _ value: String) -> some View {
        LabeledContent {
            Text(value)
                .foregroundStyle(.themeFg)
        } label: {
            Text(label)
                .foregroundStyle(.themeComment)
        }
        .padding(.vertical, 10)
    }
}

enum PairingApprovalPromptFormatting {
    static func deviceSymbol(_ deviceName: String) -> String {
        // Whole words only: "Camacho" and "Machine" are not Macs.
        let words = deviceName.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        if words.contains("ipad") { return "ipad" }
        if words.contains("iphone") { return "iphone" }
        if words.contains("macbook") { return "laptopcomputer" }
        if words.contains("imac") { return "desktopcomputer" }
        if let mac = words.firstIndex(of: "mac"), mac + 1 < words.count {
            switch words[mac + 1] {
            case "mini": return "macmini"
            case "studio": return "macstudio"
            case "pro": return "macpro.gen3"
            default: break
            }
        }
        return "ipad.and.iphone"
    }

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
