import SwiftUI

/// Checks whether a Mac or Linux machine on the tailnet is ready for Oppi:
/// signs in to its sshd (macOS Remote Login, or Linux sshd) through the
/// embedded Tailscale node with a password, runs one read-only probe, and
/// lists what is installed. Nothing is installed and only the SSH host key
/// is saved.
struct SSHPreflightView: View {
    private enum Phase {
        case idle
        case checking(host: String)
        case failed(SSHPreflightFailure, host: String)
        case finished(SSHPreflightReport, host: String)
    }

    private static let manualSelection = "\u{0}manual"
    private static let sshPort: UInt16 = 22

    var onPaired: (() -> Void)?

    private var tailnet: TailnetNodeController { .shared }

    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(ServerStore.self) private var serverStore

    @State private var selection: String
    @State private var manualHost = ""
    @State private var username = ""
    @State private var password = ""
    @State private var phase = Phase.idle
    @State private var runID = UUID()
    @State private var task: Task<Void, Never>?
    @State private var forgetHost: String?
    @State private var pairing = false
    @State private var pairMessage: String?

    /// `initialPeer` preselects a machine from the tailnet list; the picker
    /// still allows changing it.
    init(initialPeer: TailnetPeer? = nil, onPaired: (() -> Void)? = nil) {
        self.onPaired = onPaired
        _selection = State(initialValue: initialPeer?.dialHost ?? "")
    }

    #if DEBUG
    /// Screenshot harness: renders a settled result without dialing SSH.
    init(previewReport: SSHPreflightReport, host: String) {
        self.init()
        _selection = State(initialValue: host)
        _phase = State(initialValue: .finished(previewReport, host: host))
    }

    /// Screenshot harness: renders a settled failure without dialing SSH.
    init(previewFailure: SSHPreflightFailure, host: String) {
        self.init()
        _selection = State(initialValue: host)
        _phase = State(initialValue: .failed(previewFailure, host: host))
    }
    #endif

    var body: some View {
        List {
            machineSection
            signInSection
            actionSection
            resultSections
        }
        .settingsPage("Check a Machine")
        .onAppear {
            tailnet.startIfEnabled()
            selectDefaultMachine()
        }
        .onDisappear { cancel() }
        .onChange(of: targetHost) { phase = .idle }
        .confirmationDialog("Forget the trusted host key?", isPresented: Binding(
            get: { forgetHost != nil }, set: { if !$0 { forgetHost = nil } }
        ), titleVisibility: .visible) {
            Button("Forget Trusted Key", role: .destructive) {
                guard let host = forgetHost else { return }
                do { try SSHKnownHosts().forget(host: host, port: Self.sshPort); phase = .idle } catch { phase = .failed(.handshakeFailed(error.localizedDescription), host: host) }
                forgetHost = nil
            }
        } message: { Text("Independently verify why the host key changed before forgetting it.") }
    }

    // MARK: - Sections

    private var machineSection: some View {
        Section {
            Picker("Machine", selection: $selection) {
                ForEach(tailnet.onlinePeers.filter(\.canHostOppi)) { peer in
                    Text(peer.displayName).tag(peer.dialHost)
                }
                Text("Other…").tag(Self.manualSelection)
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("sshPreflight.machine")

            if selection == Self.manualSelection {
                TextField("Hostname or Tailscale IP", text: $manualHost)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .accessibilityIdentifier("sshPreflight.host")
            }
        } header: {
            Text("Machine")
        } footer: {
            Text("Turn on SSH. On a Mac, that is Remote Login in System Settings → General → Sharing. On Linux, start sshd.")
        }
        .disabled(isChecking)
    }

    private var signInSection: some View {
        Section {
            TextField("Username", text: $username)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .textContentType(.username)
                .accessibilityIdentifier("sshPreflight.username")
            SecureField("Password", text: $password)
                .textContentType(.password)
                .accessibilityIdentifier("sshPreflight.password")
        } header: {
            Text("Sign In")
        } footer: {
            Text("Oppi sends your password only to a machine whose SSH key you trusted, and does not save it.")
        }
        .disabled(isChecking)
    }

    @ViewBuilder
    private var actionSection: some View {
        Section {
            if case .checking = phase {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking…")
                        .foregroundStyle(.themeComment)
                    Spacer()
                    Button("Cancel", role: .cancel) { cancel() }
                        .accessibilityIdentifier("sshPreflight.cancel")
                }
            } else {
                Button("Check") { check() }
                    .disabled(!canCheck)
                    .accessibilityIdentifier("sshPreflight.check")
            }
        } footer: {
            if ServerTLSTrustPolicy.isTailscaleHostname(targetHost), tailnet.state != .running {
                Text("A Tailscale name needs Oppi's Tailscale connection.")
            }
        }
    }

    @ViewBuilder
    private var resultSections: some View {
        switch phase {
        case .idle, .checking:
            EmptyView()
        case .failed(let failure, let host):
            Section {
                Text(failure.message)
                    .foregroundStyle(.themeRed)
                    .accessibilityIdentifier("sshPreflight.failure")
                hostKeyRows(failure, host: host)
            } header: {
                Text(host)
            } footer: {
                if case .unknownHostKey(let key) = failure {
                    Text("On the machine, `ssh-keygen -lf /etc/ssh/ssh_host_\(Self.keyFileStem(key))_key.pub` prints the same value.")
                }
            }
            if case .hostKeyMismatch = failure {
                Section {
                    Button("Forget Trusted Key", role: .destructive) {
                        forgetHost = host
                    }
                    .accessibilityIdentifier("sshPreflight.forgetKey")
                }
            }
        case .finished(let report, let host):
            Section {
                LabeledContent("Signed In As") {
                    Text(report.user)
                        .foregroundStyle(.themeComment)
                }
                ForEach(report.checks) { check in
                    checkRow(check)
                }
            } header: {
                Text(host)
            } footer: {
                if !report.canPairOverSSH {
                    Text(Self.resultFooter(report))
                }
            }
            if report.canPairOverSSH {
                Section {
                    if pairing {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Pairing…").foregroundStyle(.themeComment)
                        }
                    } else {
                        Button("Pair") { pair(host: host) }
                            .accessibilityIdentifier("sshPreflight.pair")
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Self.resultFooter(report))
                        if let pairMessage {
                            Text(pairMessage)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func hostKeyRows(_ failure: SSHPreflightFailure, host: String) -> some View {
        switch failure {
        case .unknownHostKey(let key):
            fingerprintRow("Fingerprint", key)
            Button("Trust Key and Check") { check(trusting: key, host: host) }
                .accessibilityIdentifier("sshPreflight.trustKey")
        case .hostKeyMismatch(let saved, let presented):
            fingerprintRow("Trusted", saved)
            fingerprintRow("Presented", presented)
        default:
            EmptyView()
        }
    }

    private func fingerprintRow(_ label: String, _ key: SSHHostKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(label) (\(key.algorithm))")
                .font(.footnote)
                .foregroundStyle(.themeComment)
            Text(key.fingerprint)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    private func checkRow(_ check: SSHPreflightCheck) -> some View {
        HStack(alignment: .firstTextBaseline) {
            switch check.status {
            case .ok:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.themeGreen)
            case .missing:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.themeRed)
            case .info:
                Image(systemName: "info.circle").foregroundStyle(.themeComment)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title)
                Text(check.detail)
                    .font(.footnote)
                    .foregroundStyle(.themeComment)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Actions

    private var targetHost: String {
        let host = selection == Self.manualSelection ? manualHost : selection
        return host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isChecking: Bool {
        if case .checking = phase { return true }
        return false
    }

    private var canCheck: Bool {
        !pairing && !targetHost.isEmpty && !username.isEmpty && !password.isEmpty
    }

    /// `*.ts.net` uses the embedded node only while it is running. It is not
    /// dialed on the system network. Every other host uses the current network.
    private func dialSSH(host: String) async throws -> Int32 {
        switch SSHPairDial.route(host: host, tailnetRunning: tailnet.state == .running) {
        case .tailnet:
            return try await tailnet.dialTCP(host: host, port: Self.sshPort, timeout: .seconds(15))
        case .direct:
            return try await SSHDirectTCP.dial(host: host, port: Self.sshPort)
        case .tailnetRequired:
            throw SSHPreflightFailure.tailnetNotRunning
        }
    }

    private func selectDefaultMachine() {
        guard selection.isEmpty else { return }
        selection = TailnetPeer.preferredSetupPeer(among: tailnet.onlinePeers)?.dialHost ?? Self.manualSelection
    }

    private func check(trusting key: SSHHostKey? = nil, host: String? = nil) {
        guard canCheck else { return }
        let host = host ?? targetHost
        let knownHosts = SSHKnownHosts()
        let request: SSHPreflightClient.Request
        do {
            if let key { try knownHosts.trust(key, host: host, port: Self.sshPort) }
            request = SSHPreflightClient.Request(
                username: username, password: password,
                savedHostKey: try knownHosts.savedKey(host: host, port: Self.sshPort)
            )
        } catch {
            phase = .failed(.handshakeFailed(error.localizedDescription), host: host)
            return
        }
        task?.cancel()
        let runID = UUID()
        self.runID = runID
        phase = .checking(host: host)
        task = Task {
            let outcome: Phase?
            do {
                let socket = try await dialSSH(host: host)
                let report = try await SSHPreflightClient.run(request, socket: socket)
                outcome = .finished(report, host: host)
            } catch let failure as SSHPreflightFailure {
                outcome = .failed(failure, host: host)
            } catch {
                outcome = nil // Cancelled.
            }
            guard self.runID == runID else { return }
            phase = outcome ?? .idle
            task = nil
        }
    }

    /// Cancelling the task closes the SSH connection.
    private func cancel() {
        task?.cancel()
        task = nil
        runID = UUID()
        if isChecking { phase = .idle }
    }

    private static func resultFooter(_ report: SSHPreflightReport) -> String {
        if report.canPairOverSSH {
            return "Oppi is serving HTTPS. Pair signs this phone in with a one-time invite."
        }
        if report.checks.contains(where: { $0.status == .missing }) {
            return "Fix the missing items on this machine, then check again."
        }
        if report.isReadyToPair {
            return "Ready — go back and tap Pair."
        }
        return "This machine has what Oppi's installer needs."
    }

    private func pair(host: String) {
        guard !pairing, !password.isEmpty else { return }
        let knownHosts = SSHKnownHosts()
        let request: SSHPreflightClient.Request
        do {
            request = SSHPreflightClient.Request(
                username: username, password: password,
                savedHostKey: try knownHosts.savedKey(host: host, port: Self.sshPort)
            )
        } catch {
            pairMessage = SSHPreflightFailure.handshakeFailed(error.localizedDescription).message
            return
        }
        task?.cancel()
        let runID = UUID()
        self.runID = runID
        pairing = true
        pairMessage = nil
        task = Task {
            let message: String
            var paired = false
            do {
                let socket = try await dialSSH(host: host)
                let invite = try await SSHPreflightClient.mintInvite(request, socket: socket)
                let enrolled = try await InviteBootstrapService.enroll(
                    inviteURL: invite.inviteURL,
                    serverStore: serverStore,
                    coordinator: coordinator
                ) { reason in
                    await BiometricService.shared.authenticate(reason: reason)
                }
                message = "Paired with \(enrolled.name)."
                paired = enrolled.selected
            } catch let failure as SSHPreflightFailure {
                message = failure.message
            } catch let error as InviteBootstrapError {
                message = error.errorDescription ?? "Pairing failed. Request a fresh invite and try again."
            } catch is CancellationError {
                message = ""
            } catch {
                message = InviteBootstrapService.pairingFailureMessage(for: error, host: host)
            }
            guard self.runID == runID else { return }
            pairing = false
            task = nil
            if !message.isEmpty { pairMessage = message }
            if paired {
                password = ""
                onPaired?()
            }
        }
    }

    /// `ssh-ed25519` → `ed25519`, `ecdsa-sha2-nistp256` → `ecdsa`.
    private static func keyFileStem(_ key: SSHHostKey) -> String {
        let algorithm = key.algorithm.replacingOccurrences(of: "ssh-", with: "")
        return algorithm.hasPrefix("ecdsa") ? "ecdsa" : algorithm
    }
}
