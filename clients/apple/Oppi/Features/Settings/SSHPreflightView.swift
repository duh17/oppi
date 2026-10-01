import SwiftUI

/// Checks whether a Mac on the tailnet is ready for Oppi: signs in to its
/// Remote Login (sshd) through the embedded Tailscale node with a password,
/// runs one read-only probe, and lists what is installed. Nothing is installed
/// and only the Mac's SSH host key is saved.
struct SSHPreflightView: View {
    private enum Phase {
        case idle
        case checking(host: String)
        case failed(SSHPreflightFailure, host: String)
        case finished(SSHPreflightReport, host: String)
    }

    private static let manualSelection = "\u{0}manual"
    private static let sshPort: UInt16 = 22

    private var tailnet: TailnetNodeController { .shared }

    @State private var selection: String
    @State private var manualHost = ""
    @State private var username = ""
    @State private var password = ""
    @State private var phase = Phase.idle
    @State private var runID = UUID()
    @State private var task: Task<Void, Never>?

    /// `initialPeer` preselects a machine from the tailnet list; the picker
    /// still allows changing it.
    init(initialPeer: TailnetPeer? = nil) {
        _selection = State(initialValue: initialPeer?.dialHost ?? "")
    }

    var body: some View {
        List {
            machineSection
            signInSection
            actionSection
            resultSection
        }
        .navigationTitle("Check a Mac")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            tailnet.startIfEnabled()
            selectDefaultMachine()
        }
        .onDisappear { cancel() }
        .onChange(of: targetHost) { phase = .idle }
    }

    // MARK: - Sections

    private var machineSection: some View {
        Section {
            Picker("Machine", selection: $selection) {
                ForEach(tailnet.onlinePeers) { peer in
                    Text(peer.displayName).tag(peer.dialHost)
                }
                Text("Other…").tag(Self.manualSelection)
            }
            .accessibilityIdentifier("sshPreflight.machine")

            if selection == Self.manualSelection {
                TextField("Hostname or Tailscale IP", text: $manualHost)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .accessibilityIdentifier("sshPreflight.host")
            }
        } header: {
            Text("Mac")
        } footer: {
            Text("Turn on Remote Login on the Mac in System Settings → General → Sharing.")
        }
        .disabled(isChecking)
    }

    private var signInSection: some View {
        Section {
            TextField("Mac Username", text: $username)
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
            Text("Oppi sends your password only to a Mac whose SSH key you trusted, and does not save it.")
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
                Button("Check Mac") { check() }
                    .disabled(!canCheck)
                    .accessibilityIdentifier("sshPreflight.check")
            }
        } footer: {
            if tailnet.state != .running {
                Text("Connect Tailscale first.")
            }
        }
    }

    @ViewBuilder
    private var resultSection: some View {
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
                Text(Self.resultFooter(report))
            }
        }
    }

    @ViewBuilder
    private func hostKeyRows(_ failure: SSHPreflightFailure, host: String) -> some View {
        switch failure {
        case .unknownHostKey(let key):
            fingerprintRow("Fingerprint", key)
            Text("On the Mac, `ssh-keygen -lf /etc/ssh/ssh_host_\(Self.keyFileStem(key))_key.pub` prints the same value.")
                .font(.footnote)
                .foregroundStyle(.themeComment)
            Button("Trust Key and Check") { check(trusting: key, host: host) }
                .accessibilityIdentifier("sshPreflight.trustKey")
        case .hostKeyMismatch(let saved, let presented):
            fingerprintRow("Trusted", saved)
            fingerprintRow("Presented", presented)
            Button("Forget Trusted Key", role: .destructive) {
                SSHKnownHosts().forget(host: host, port: Self.sshPort)
                phase = .idle
            }
            .accessibilityIdentifier("sshPreflight.forgetKey")
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
        tailnet.state == .running && !targetHost.isEmpty && !username.isEmpty && !password.isEmpty
    }

    private func selectDefaultMachine() {
        guard selection.isEmpty else { return }
        let peers = tailnet.onlinePeers
        let mac = peers.first { $0.os?.lowercased() == "macos" } ?? peers.first
        selection = mac?.dialHost ?? Self.manualSelection
    }

    private func check(trusting key: SSHHostKey? = nil, host: String? = nil) {
        guard canCheck else { return }
        let host = host ?? targetHost
        let knownHosts = SSHKnownHosts()
        if let key {
            knownHosts.trust(key, host: host, port: Self.sshPort)
        }
        let request = SSHPreflightClient.Request(
            username: username,
            password: password,
            savedHostKey: knownHosts.savedKey(host: host, port: Self.sshPort)
        )
        task?.cancel()
        let runID = UUID()
        self.runID = runID
        phase = .checking(host: host)
        task = Task {
            let outcome: Phase?
            do {
                let socket = try await tailnet.dialTCP(host: host, port: Self.sshPort, timeout: .seconds(15))
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
        if report.checks.contains(where: { $0.status == .missing }) {
            return "Fix the missing items on the Mac, then check again."
        }
        if report.isReadyToPair {
            return "Ready — go back and tap Pair."
        }
        return "This Mac has what Oppi's installer needs."
    }

    /// `ssh-ed25519` → `ed25519`, `ecdsa-sha2-nistp256` → `ecdsa`.
    private static func keyFileStem(_ key: SSHHostKey) -> String {
        let algorithm = key.algorithm.replacingOccurrences(of: "ssh-", with: "")
        return algorithm.hasPrefix("ecdsa") ? "ecdsa" : algorithm
    }
}
