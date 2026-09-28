import SwiftUI

/// Connect Oppi's embedded Tailscale node and list online tailnet machines.
struct TailnetSettingsView: View {
    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(ServerStore.self) private var serverStore

    private var tailnet: TailnetNodeController { .shared }

    @State private var pairingPeerID: String?
    @State private var pairingMessage: String?

    var body: some View {
        List {
            Section {
                LabeledContent("Status") {
                    Text(Self.statusLabel(tailnet.state))
                        .foregroundStyle(.themeComment)
                }
                .accessibilityIdentifier("tailnet.status")

                if let name = tailnet.snapshot?.selfDNSName, tailnet.state == .running {
                    LabeledContent("This Device") {
                        Text(name)
                            .foregroundStyle(.themeComment)
                            .textSelection(.enabled)
                    }
                }

                actionRows
            } header: {
                Label("Tailscale", image: "tailscale")
            } footer: {
                Text(
                    "Oppi joins your tailnet as its own device without the Tailscale VPN. "
                        + "While it is connected, paired *.ts.net servers connect through it."
                )
            }

            if tailnet.state == .running {
                peersSection
                setupCheckSection
            }
        }
        .navigationTitle("Tailscale")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { tailnet.startIfEnabled() }
        .refreshable { await tailnet.refresh() }
    }

    @ViewBuilder
    private var actionRows: some View {
        switch tailnet.state {
        case .off:
            Button("Connect to Tailscale") { tailnet.connect() }
                .accessibilityIdentifier("tailnet.connect")
        case .starting:
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Starting…")
                    .foregroundStyle(.themeComment)
            }
            disconnectButton
        case .needsLogin(let url):
            if let url {
                Button {
                    InAppBrowserPresenter.present(url: url)
                } label: {
                    Label("Sign In to Tailscale", systemImage: "person.badge.key")
                }
                .accessibilityIdentifier("tailnet.signIn")
            } else {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for sign-in link…")
                        .foregroundStyle(.themeComment)
                }
            }
            disconnectButton
        case .needsMachineAuth:
            Text("A tailnet admin must approve \(TailnetNodeController.hostName) in the Tailscale admin console.")
                .font(.footnote)
                .foregroundStyle(.themeComment)
            disconnectButton
        case .running:
            disconnectButton
        case .failed(let message):
            Text(message)
                .font(.footnote)
                .foregroundStyle(.themeRed)
            Button("Try Again") {
                Task { await tailnet.restart() }
            }
            disconnectButton
        }
    }

    private var disconnectButton: some View {
        Button("Disconnect", role: .destructive) {
            Task { await tailnet.disconnect() }
        }
        .accessibilityIdentifier("tailnet.disconnect")
    }

    private var peersSection: some View {
        Section {
            if tailnet.onlinePeers.isEmpty {
                Text("No other machines are online.")
                    .foregroundStyle(.themeComment)
            } else {
                ForEach(tailnet.onlinePeers) { peer in
                    VStack(alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(peer.displayName)
                            Text(peer.dnsName.isEmpty ? peer.tailscaleIPs.first ?? "" : peer.dnsName)
                                .font(.footnote)
                                .foregroundStyle(.themeComment)
                                .textSelection(.enabled)
                        }
                        if pairingPeerID == peer.id {
                            HStack {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Pairing…")
                                    .foregroundStyle(.themeComment)
                            }
                        } else {
                            Button("Pair with Oppi") {
                                Task { await pair(with: peer) }
                            }
                            .disabled(pairingPeerID != nil || tailnet.state != .running)
                            .accessibilityIdentifier("tailnet.pair.\(peer.id)")
                        }
                    }
                    .accessibilityElement(children: .contain)
                }
            }
        } header: {
            Text("Online Machines")
        } footer: {
            if let pairingMessage {
                Text(pairingMessage)
            } else {
                Text("Pair with a Mac that runs Oppi and is signed into the same Tailscale account.")
            }
        }
    }

    private var setupCheckSection: some View {
        Section {
            NavigationLink("Check a Mac for Oppi") {
                SSHPreflightView()
            }
            .accessibilityIdentifier("tailnet.checkMac")
        } footer: {
            Text("Signs in to the Mac's Remote Login over SSH to see what Oppi needs. Nothing is installed.")
        }
    }

    @MainActor
    private func pair(with peer: TailnetPeer) async {
        pairingMessage = nil
        pairingPeerID = peer.id
        defer { pairingPeerID = nil }
        do {
            tailnet.startIfEnabled()
            try await tailnet.waitUntilCurrentGenerationProxyReady()
            let baseURL = try await TailnetSameUserPairing.firstHealthyProbeURL(dnsName: peer.dnsName) { url in
                let client = try TailnetSameUserPairing.makeBootstrapClient(
                    nodeState: tailnet.state,
                    proxy: TailnetTransportRoute.proxy,
                    baseURL: url,
                    makeClient: { APIClient(baseURL: $0, token: "") }
                )
                return try await client.health(timeoutInterval: 5)
            }
            let inviteClient = try TailnetSameUserPairing.makeBootstrapClient(
                nodeState: tailnet.state,
                proxy: TailnetTransportRoute.proxy,
                baseURL: baseURL,
                makeClient: { APIClient(baseURL: $0, token: "") }
            )
            let invite = try await inviteClient.issueTailscalePairingInvite()
            guard let credentials = ServerCredentials.decodeInviteURLString(invite.inviteURL) else {
                throw TailnetSameUserPairing.Failure.invalidInvite
            }
            let existing = credentials.normalizedServerFingerprint.flatMap {
                serverStore.server(for: $0)?.credentials
            } ?? serverStore.server(forHost: credentials.host, port: credentials.port)?.credentials
            let bootstrap = try await InviteBootstrapService.validateAndBootstrap(
                credentials: credentials,
                existingCredentials: existing
            ) { reason in
                await BiometricService.shared.authenticate(reason: reason)
            }
            guard let pairedServer = PairedServer(
                from: bootstrap.effectiveCredentials,
                sortOrder: serverStore.servers.count
            ) else {
                throw TailnetSameUserPairing.Failure.invalidInvite
            }
            let outcome = await coordinator.addServerReady(pairedServer, switchTo: true)
            guard outcome != .failed else {
                throw TailnetSameUserPairing.Failure.pairingFailed(
                    "Connection blocked by server transport policy"
                )
            }
            pairingMessage = "Paired with \(pairedServer.name)."
        } catch let failure as TailnetSameUserPairing.Failure {
            pairingMessage = failure.errorDescription
        } catch let error as InviteBootstrapError {
            pairingMessage = error.errorDescription
        } catch {
            pairingMessage = InviteBootstrapService.pairingFailureMessage(
                for: error,
                host: peer.displayName
            )
        }
    }

    static func statusLabel(_ state: TailnetNodeState) -> String {
        switch state {
        case .off: "Off"
        case .starting: "Starting"
        case .needsLogin: "Sign-in required"
        case .needsMachineAuth: "Awaiting approval"
        case .running: "Connected"
        case .failed: "Error"
        }
    }
}
