import SwiftUI

/// Connect Oppi's embedded Tailscale node and list online tailnet machines.
struct TailnetSettingsView: View {
    /// Called after a machine is paired and selected. Onboarding uses this to
    /// leave setup; Settings leaves the list in place.
    var onPaired: (() -> Void)? = nil
    #if DEBUG
    /// Skips live health probes so a screenshot can show a settled row.
    var previewProbes: [String: TailnetPeerProbe]? = nil
    #endif

    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(ServerStore.self) private var serverStore

    private var tailnet: TailnetNodeController { .shared }

    @State private var pairingPeerID: String?
    @State private var pairingMessage: String?
    /// Latest Oppi probe per peer id; a missing entry means none has started.
    @State private var probes: [String: TailnetPeerProbe] = [:]
    @State private var probeRefresh = 0

    /// Re-runs the probes when the node starts or stops, the probed machines
    /// change, or a refresh was requested. There is no polling timer.
    private struct ProbeTrigger: Equatable {
        let isRunning: Bool
        let peers: [String]
        let refresh: Int
    }

    private var probeTrigger: ProbeTrigger {
        ProbeTrigger(
            isRunning: tailnet.state == .running,
            peers: probeTargets.map { "\($0.id)|\($0.dnsName)" },
            refresh: probeRefresh
        )
    }

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
        .task(id: probeTrigger) {
            #if DEBUG
            if let previewProbes {
                probes = previewProbes
                return
            }
            #endif
            await probePeers()
        }
        .refreshable {
            await tailnet.refresh()
            reprobe()
        }
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
            if visiblePeers.isEmpty {
                Text("No other machines are online.")
                    .foregroundStyle(.themeComment)
            } else {
                ForEach(visiblePeers) { peer in
                    peerRow(peer)
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

    /// Phones and tablets cannot run an Oppi server, so they are not listed.
    private var visiblePeers: [TailnetPeer] {
        tailnet.onlinePeers.filter(\.canHostOppi)
    }

    private var pairedHosts: [String] {
        serverStore.servers.map(\.host)
    }

    private func status(of peer: TailnetPeer) -> TailnetPeerStatus {
        TailnetPeerStatus.derive(peer: peer, pairedHosts: pairedHosts, probe: probes[peer.id])
    }

    /// Peers whose Oppi readiness is unknown. Paired machines need no probe.
    private var probeTargets: [TailnetPeer] {
        visiblePeers.filter { status(of: $0) != .paired }
    }

    @ViewBuilder
    private func peerRow(_ peer: TailnetPeer) -> some View {
        switch status(of: peer) {
        case .paired:
            if let server = serverStore.servers.first(where: { peer.hasHost($0.host) }) {
                NavigationLink {
                    ServerDetailView(server: server)
                } label: {
                    HStack {
                        peerTitle(peer)
                        Spacer()
                        Label("Paired", systemImage: "checkmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.themeGreen)
                    }
                }
                .accessibilityIdentifier("tailnet.paired.\(peer.id)")
            }
        case .checking:
            HStack {
                peerTitle(peer)
                Spacer()
                ProgressView()
                    .controlSize(.small)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(peer.displayName), checking for Oppi")
        case .ready:
            VStack(alignment: .leading, spacing: 8) {
                peerTitle(peer)
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
        case .needsCertificate:
            setupRow(peer) {
                Label("Oppi needs Tailscale HTTPS", systemImage: "lock.trianglebadge.exclamationmark")
                    .foregroundStyle(.themeOrange)
            }
        case .notReachable:
            setupRow(peer) {
                Label("Oppi not reachable", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.themeComment)
            }
        case .unchecked:
            VStack(alignment: .leading, spacing: 4) {
                peerTitle(peer)
                Text("Not checked yet. Pull to refresh.")
                    .font(.footnote)
                    .foregroundStyle(.themeComment)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func peerTitle(_ peer: TailnetPeer) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(peer.displayName)
            Text(peer.dnsName.isEmpty ? peer.tailscaleIPs.first ?? "" : peer.dnsName)
                .font(.footnote)
                .foregroundStyle(.themeComment)
                .textSelection(.enabled)
        }
    }

    /// The Mac does not answer as an Oppi server; the SSH check says why.
    private func setupRow(
        _ peer: TailnetPeer,
        @ViewBuilder status: () -> some View
    ) -> some View {
        NavigationLink {
            SSHPreflightView(initialPeer: peer, onPaired: onPaired)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                peerTitle(peer)
                status()
                    .font(.footnote)
                Text("Check this Mac")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.tint)
            }
        }
        .accessibilityIdentifier("tailnet.check.\(peer.id)")
    }

    /// Probes every unpaired machine for Oppi, concurrently, once the node's
    /// SOCKS route is current. Each start re-probes them all, so a result never
    /// outlives the screen visit that produced it. Runs under `.task(id:)`:
    /// leaving the screen or a new trigger cancels it, and cancelled probes
    /// never store a result.
    @MainActor
    private func probePeers() async {
        guard tailnet.state == .running else {
            probes = [:]
            return
        }
        let targets = probeTargets
        guard !targets.isEmpty else { return }
        for peer in targets { probes[peer.id] = .inFlight }
        do {
            try await tailnet.waitUntilCurrentGenerationProxyReady()
        } catch {
            // A cancelled run leaves `.inFlight` for the next run to replace;
            // a proxy that never came up leaves the rows unchecked.
            if !Task.isCancelled {
                for peer in targets { probes[peer.id] = nil }
            }
            return
        }
        await TailnetSameUserPairing.probeOutcomes(dnsNames: targets.map(\.dnsName)) { dnsName, outcome in
            for peer in targets where peer.dnsName == dnsName {
                probes[peer.id] = outcome
            }
        }
    }

    private func reprobe() {
        probes = [:]
        probeRefresh += 1
    }

    private var setupCheckSection: some View {
        Section {
            NavigationLink("Check a Mac for Oppi") {
                SSHPreflightView(onPaired: onPaired)
            }
            .accessibilityIdentifier("tailnet.checkMac")
        } footer: {
            Text("Signs in over SSH to see what Oppi needs. If Oppi is already serving HTTPS, you can pair from that screen. Nothing is installed.")
        }
    }

    @MainActor
    private func pair(with peer: TailnetPeer) async {
        pairingMessage = nil
        pairingPeerID = peer.id
        defer {
            pairingPeerID = nil
            // A paired peer is recognised from the store; a failed attempt
            // may have changed what the machine answers.
            probes[peer.id] = nil
            probeRefresh += 1
        }
        do {
            tailnet.startIfEnabled()
            try await tailnet.waitUntilCurrentGenerationProxyReady()
            let baseURL = try await TailnetSameUserPairing.firstHealthyProbeURL(dnsName: peer.dnsName) { url in
                try await TailnetSameUserPairing.health(at: url)
            }
            let inviteClient = try TailnetSameUserPairing.makeBootstrapClient(
                nodeState: tailnet.state,
                proxy: TailnetTransportRoute.proxy,
                baseURL: baseURL,
                makeClient: { APIClient(baseURL: $0, token: "") }
            )
            let invite = try await inviteClient.issueTailscalePairingInvite()
            let enrolled = try await InviteBootstrapService.enroll(
                inviteURL: invite.inviteURL,
                serverStore: serverStore,
                coordinator: coordinator
            ) { reason in
                await BiometricService.shared.authenticate(reason: reason)
            }
            pairingMessage = "Paired with \(enrolled.name)."
            if enrolled.selected {
                onPaired?()
            }
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
