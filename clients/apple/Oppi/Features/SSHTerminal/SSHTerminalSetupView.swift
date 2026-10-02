import Darwin
import SwiftUI
import UIKit

struct SSHTerminalSetupView: View {
    @AppStorage("\(AppIdentifiers.subsystem).ssh.terminal.host") private var host = "mac-studio"
    @AppStorage("\(AppIdentifiers.subsystem).ssh.terminal.port") private var portText = "22"
    @AppStorage("\(AppIdentifiers.subsystem).ssh.terminal.username") private var username = ""
    @AppStorage("\(AppIdentifiers.subsystem).ssh.terminal.transport") private var transport = "direct"
    @State private var identity: SSHIdentity?
    @State private var identityFailure: String?
    @State private var copied = false
    @State private var connecting = false
    @State private var failure: String?
    @State private var hostFailure: SSHPTYSessionError?
    @State private var attemptedHost = ""
    @State private var attemptedPort: UInt16 = 22
    @State private var forgetConfirmation = false
    @State private var channel: SSHTerminalChannel?
    @State private var showsTerminal = false
    @State private var task: Task<Void, Never>?
    @State private var runID = UUID()

    private var tailnet: TailnetNodeController { .shared }
    private var target: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var port: UInt16? { UInt16(portText) }

    var body: some View {
        List {
            Section {
                TextField("Hostname or IP", text: $host)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .accessibilityIdentifier("sshTerminal.host")
                TextField("Port", text: $portText).keyboardType(.numberPad)
                    .accessibilityIdentifier("sshTerminal.port")
                TextField("Username", text: $username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(.username)
                    .accessibilityIdentifier("sshTerminal.username")
                Picker("Transport", selection: $transport) {
                    Text("Direct TCP").tag("direct")
                    Text("Tailscale Node").tag("tailnet")
                }.accessibilityIdentifier("sshTerminal.transport")
                if transport == "tailnet" {
                    ForEach(tailnet.onlinePeers) { peer in
                        Button(peer.displayName) { host = peer.dialHost }
                    }
                }
            } header: { Text("Owner Host") } footer: {
                Text("Direct TCP uses your current network, including the system Tailscale VPN. Tailscale Node uses Oppi’s in-app node. Remote Login must be enabled on the host.")
            }.disabled(connecting)

            Section {
                if let identity {
                    Text(identity.publicKeyOpenSSH)
                        .font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                        .accessibilityIdentifier("sshTerminal.publicKey")
                    Button(copied ? "Copied Public Key" : "Copy Public Key", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        UIPasteboard.general.string = identity.publicKeyOpenSSH
                        copied = true
                    }.accessibilityIdentifier("sshTerminal.copyKey")
                    Text(identity.backingDescription).font(.footnote).foregroundStyle(.themeComment)
                } else {
                    Text(identityFailure ?? "Loading identity…").foregroundStyle(.themeComment)
                }
            } header: { Text("This Device’s SSH Identity") } footer: {
                Text("Append this public key as one line to ~/.ssh/authorized_keys on the owner host. Oppi never installs it for you.")
            }

            Section {
                if connecting {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Connecting…")
                        Spacer()
                        Button("Cancel") { cancel() }
                    }.accessibilityIdentifier("sshTerminal.connecting")
                } else {
                    Button("Connect") { connect() }
                        .disabled(identity == nil || target.isEmpty || username.isEmpty || port == nil || port == 0 || (transport == "tailnet" && tailnet.state != .running))
                        .accessibilityIdentifier("sshTerminal.connect")
                }
                if let failure {
                    Text("Disconnected — \(failure)").foregroundStyle(.themeRed)
                        .accessibilityIdentifier("sshTerminal.failure")
                }
                trustRows
            } footer: {
                Text("A new connection opens a fresh shell. Run tmux attach or herdr session attach <name> yourself. No input is replayed after disconnect.")
            }
        }
        .navigationTitle("SSH Terminal").navigationBarTitleDisplayMode(.inline)
        .task {
            do { identity = try SSHIdentityKeyStore.loadOrCreate() }
            catch { identityFailure = "SSH identity unavailable: \(error.localizedDescription)" }
            tailnet.startIfEnabled()
        }
        .onChange(of: host) { hostFailure = nil; failure = nil }
        .onChange(of: portText) { hostFailure = nil; failure = nil }
        .confirmationDialog("Forget the trusted host key?", isPresented: $forgetConfirmation, titleVisibility: .visible) {
            Button("Forget Trusted Key", role: .destructive) {
                SSHKnownHosts().forget(host: attemptedHost, port: attemptedPort)
                hostFailure = nil
                failure = "Trusted key forgotten. Verify the new fingerprint before trusting it."
            }
        } message: { Text("Only do this after independently verifying why the host key changed.") }
        .navigationDestination(isPresented: $showsTerminal) {
            if let channel {
                SSHTerminalView(channel: channel) { connect() }
                    .id(ObjectIdentifier(channel))
            }
        }
        .onDisappear {
            // Pushing the terminal retains ownership. Leaving setup cancels it.
            if !showsTerminal { cancel() }
        }
        .onChange(of: showsTerminal) { _, visible in
            if !visible { cancel() }
        }
    }

    @ViewBuilder private var trustRows: some View {
        if case .unknownHostKey(let key) = hostFailure {
            Text("New host \u{2014} trust decision").font(.headline).accessibilityIdentifier("sshTerminal.trustPrompt")
            fingerprint("Presented Host Key", key)
            Text("Verify this fingerprint on the host before trusting it. No user key has been offered.")
                .font(.footnote).foregroundStyle(.themeComment)
            Button("Trust & Connect") {
                guard target == attemptedHost, port == attemptedPort else { return }
                SSHKnownHosts().trust(key, host: attemptedHost, port: attemptedPort)
                connect()
            }.accessibilityIdentifier("sshTerminal.trustKey")
        } else if case .hostKeyMismatch(let saved, let presented) = hostFailure {
            Text("Host key changed — connection blocked.").foregroundStyle(.themeRed)
            fingerprint("Trusted", saved)
            fingerprint("Presented", presented)
            Button("Forget Trusted Key", role: .destructive) { forgetConfirmation = true }
                .accessibilityIdentifier("sshTerminal.forgetKey")
        }
    }

    private func fingerprint(_ label: String, _ key: SSHHostKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(label) (\(key.algorithm))").font(.footnote).foregroundStyle(.themeComment)
            Text(key.fingerprint).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
        }.accessibilityElement(children: .combine)
    }

    private func connect() {
        guard let identity, let port, port > 0 else { return }
        cancel()
        let host = target
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let useTailnet = transport == "tailnet"
        let id = UUID()
        runID = id
        attemptedHost = host
        attemptedPort = port
        connecting = true
        failure = nil
        hostFailure = nil
        task = Task {
            do {
                let owner = try SSHTerminalChannel()
                channel = owner
                let socket = try await (useTailnet
                    ? tailnet.dialTCP(host: host, port: port, timeout: .seconds(15))
                    : SSHDirectTCP.dial(host: host, port: port))
                guard !Task.isCancelled, runID == id else { Darwin.close(socket); return }
                // The queue preserves NIO callback order; one consumer feeds
                // every byte and bounds what is waiting for the main actor.
                let queue = SSHTerminalEventQueue()
                let session: SSHPTYSession
                do {
                    session = try await SSHPTYSession.connect(configuration: .init(
                        username: username, identity: identity,
                        savedHostKey: SSHKnownHosts().savedKey(host: host, port: port),
                        inboundFlow: queue.flow
                    ), socket: socket) { queue.push($0) }
                } catch { queue.finish(); throw error }
                guard !Task.isCancelled, runID == id else { queue.finish(); await session.cancel(); return }
                owner.opened(session)
                connecting = false
                showsTerminal = true
                await owner.consume(queue)
            } catch {
                guard runID == id, !Task.isCancelled else { return }
                let message = SSHTerminalChannel.message(error)
                let trust = error as? SSHPTYSessionError
                hostFailure = trust
                // A trust decision is not a connection error. Both trust cases
                // are resolved on this screen, so the terminal screen points here.
                switch trust {
                case .unknownHostKey:
                    failure = nil
                    channel?.close(reason: "This host's key is not trusted yet. Go back to SSH Terminal setup to review its fingerprint.")
                case .hostKeyMismatch:
                    failure = nil
                    channel?.close(reason: "The SSH host key changed. Go back to SSH Terminal setup to compare the fingerprints or forget the trusted key.")
                default:
                    failure = message
                    channel?.close(reason: message)
                }
                connecting = false
            }
        }
    }

    private func cancel() {
        runID = UUID()
        task?.cancel()
        task = nil
        channel?.close(reason: "Disconnected by you.")
        connecting = false
    }
}
