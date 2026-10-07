import SwiftUI
import UIKit

struct SSHTerminalSetupView: View {
    var profileID: UUID?
    @AppStorage(AppPreferences.Experiments.sshTerminalKey) private var experimentEnabled = false
    @Environment(\.dismiss) private var dismiss
    @State private var profile: SSHTerminalProfile
    @State private var portText: String
    @State private var identity: SSHIdentity?
    @State private var identityFailure: String?
    @State private var identityNeedsReplacement = false
    @State private var copied = false
    @State private var deleteConfirmation = false
    @State private var session = SSHTerminalConnectSession()

    init(profileID: UUID? = nil) {
        self.profileID = profileID
        let stored = profileID.flatMap { SSHTerminalProfileStore().profile(id: $0) } ?? SSHTerminalProfile(id: profileID ?? UUID())
        _profile = State(initialValue: stored)
        _portText = State(initialValue: String(stored.port))
    }

    private var target: String { profile.host.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var port: UInt16? { UInt16(portText) }
    private var canConnect: Bool {
        !target.isEmpty && !profile.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && port != nil && port != 0
    }

    var body: some View {
        List {
            Section {
                TextField("Hostname or IP", text: $profile.host)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .accessibilityIdentifier("sshTerminal.host")
                TextField("Port", text: $portText).keyboardType(.numberPad)
                    .accessibilityIdentifier("sshTerminal.port")
                TextField("Username", text: $profile.username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(nil)
                    .accessibilityIdentifier("sshTerminal.username")
                Picker("Sign In", selection: $profile.authentication) {
                    Text("Password").tag(SSHTerminalProfile.Authentication.password)
                    Text("This Device’s Key").tag(SSHTerminalProfile.Authentication.deviceKey)
                }.accessibilityIdentifier("sshTerminal.authentication")
                if profile.authentication == .password {
                    Toggle("Save Password", isOn: $profile.savesPassword)
                        .accessibilityIdentifier("sshTerminal.savePassword")
                }
            } header: { Text("Host") } footer: {
                Text("Remote Login (sshd) must be enabled. When Oppi’s Tailscale node is running, *.ts.net hosts use it; other hosts use your current network.")
            }.disabled(session.connecting)

            Section {
                TextField("Login shell", text: Binding(
                    get: { profile.startupCommand ?? "" },
                    set: { profile.startupCommand = $0 }
                ))
                .font(.system(.body, design: .monospaced))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("sshTerminal.startupCommand")
            } header: { Text("Run on Connect") } footer: {
                Text("Runs this command in the terminal instead of a login shell, like `ssh -t host 'command'` or OpenSSH RemoteCommand. Enter `herdr` to attach your Herdr session. The connection ends when the command exits (for Herdr, detach with Ctrl-B Q). The command must be on the PATH that SSH commands see.")
            }.disabled(session.connecting)

            if profile.authentication == .deviceKey {
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
                        if identityNeedsReplacement {
                            Button("Device passcode changed — create a new key") {
                                loadIdentityIfSelected(createReplacement: true)
                            }.disabled(session.connecting)
                        }
                    }
                } header: { Text("This Device’s SSH Identity") } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Append this public key to ~/.ssh/authorized_keys. Signing requires Face ID or your device passcode. The simulator uses a software key. Oppi never installs the key for you.")
                        if identityNeedsReplacement {
                            Text("Replace the old entry in ~/.ssh/authorized_keys with the new public key before connecting.")
                        }
                    }
                }
            }

            Section {
                if session.connecting {
                    SSHTerminalConnectProgress(savingHostOnly: session.savingHostOnly) { session.cancel() }
                } else {
                    Button("Connect") { connect() }.disabled(!canConnect)
                        .accessibilityIdentifier("sshTerminal.connect")
                    Button("Save Host") { saveHost() }.disabled(!canConnect)
                        .accessibilityIdentifier("sshTerminal.saveHost")
                }
                if let failure = session.failure {
                    Text("Disconnected — \(failure)").foregroundStyle(.themeRed)
                        .accessibilityIdentifier("sshTerminal.failure")
                }
                SSHTerminalTrustRows(
                    hostFailure: session.hostFailure, connecting: session.connecting,
                    trust: { session.trustAndConnect(profile: normalizedProfile(), experimentEnabled: experimentEnabled, onSaved: applySaved) },
                    requestForget: { session.forgetConfirmation = true }
                )
            } footer: {
                Text("Saved passwords stay only in this device’s private Keychain and require Face ID or passcode at connect. Unsaved passwords are used for one attempt only. Keyboard-interactive and private-key import are not supported. Reconnect opens a fresh shell; use tmux to preserve work. Input is never replayed.")
            }
            if SSHTerminalProfileStore().contains(profile.id) {
                Section {
                    Button("Delete Host", role: .destructive) { deleteConfirmation = true }
                        .accessibilityIdentifier("sshTerminal.deleteHost")
                }
            }
        }
        .settingsPage("SSH Terminal")
        .task {
            guard experimentEnabled else { return }
            // Opening the form never dials. Connect is an explicit tap.
            loadIdentityIfSelected()
        }
        .onChange(of: profile.authentication) { loadIdentityIfSelected() }
        .onChange(of: profile.host) { session.hostFailure = nil; session.failure = nil }
        .onChange(of: portText) { session.hostFailure = nil; session.failure = nil }
        .onChange(of: session.devicePasscodeChanged) { _, changed in
            guard changed else { return }
            identity = nil
            identityNeedsReplacement = true
            identityFailure = session.failure
        }
        .confirmationDialog("Delete this host and its saved password?", isPresented: $deleteConfirmation, titleVisibility: .visible) {
            Button("Delete Host", role: .destructive) { deleteHost() }
        }
        .sshTerminalConnection(
            session: session, profile: $profile, experimentEnabled: experimentEnabled,
            editHost: { session.showsTerminal = false },
            submitPassword: { password in
                if session.savingHostOnly { saveHost(password: password) }
                else { connect(password: password) }
            }
        )
    }

    private func loadIdentityIfSelected(createReplacement: Bool = false) {
        guard experimentEnabled, profile.authentication == .deviceKey else { identity = nil; return }
        do {
            identity = try SSHIdentityKeyStore.loadOrCreate(createReplacement: createReplacement)
            identityFailure = nil
            identityNeedsReplacement = false
            if createReplacement { session.failure = "New SSH key created. Replace the old entry in ~/.ssh/authorized_keys before connecting." }
        } catch {
            identity = nil
            identityNeedsReplacement = (error as? SSHIdentityKeyStoreError) == .devicePasscodeChanged
            identityFailure = error.localizedDescription
        }
    }

    private func normalizedProfile() -> SSHTerminalProfile {
        var result = profile
        result.port = port ?? 22
        return result.normalized()
    }

    private func applySaved(_ saved: SSHTerminalProfile) {
        profile = saved
        portText = String(saved.port)
    }

    private func saveHost(password: String? = nil) {
        guard canConnect else { return }
        session.saveHost(profile: normalizedProfile(), suppliedPassword: password, experimentEnabled: experimentEnabled, onSaved: applySaved)
    }

    private func connect(password: String? = nil) {
        guard canConnect else { return }
        session.connect(profile: normalizedProfile(), suppliedPassword: password, experimentEnabled: experimentEnabled, onSaved: applySaved)
    }

    private func deleteHost() {
        do {
            session.cancel()
            try SSHTerminalProfileStore().delete(id: profile.id)
            dismiss()
        } catch {
            session.failure = error.localizedDescription
        }
    }
}
