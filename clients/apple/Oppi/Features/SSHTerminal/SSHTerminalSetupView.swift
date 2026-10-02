import Darwin
import SwiftUI
import UIKit

struct SSHTerminalSetupView: View {
    @AppStorage(AppPreferences.Experiments.sshTerminalKey) private var experimentEnabled = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var profile = SSHTerminalProfileStore().load() ?? SSHTerminalProfile()
    @State private var portText = String(SSHTerminalProfileStore().load()?.port ?? 22)
    @State private var identity: SSHIdentity?
    @State private var identityFailure: String?
    @State private var identityNeedsReplacement = false
    @State private var copied = false
    @State private var connecting = false
    @State private var failure: String?
    @State private var hostFailure: SSHPTYSessionError?
    @State private var attemptedHost = ""
    @State private var attemptedPort: UInt16 = 22
    @State private var forgetConfirmation = false
    @State private var deleteConfirmation = false
    @State private var passwordPrompt = false
    @State private var savingHostOnly = false
    @State private var password = ""
    @State private var channel: SSHTerminalChannel?
    @State private var showsTerminal = false
    @State private var task: Task<Void, Never>?
    @State private var runID = UUID()

    private var target: String { profile.host.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var port: UInt16? { UInt16(portText) }
    private var canConnect: Bool { !target.isEmpty && !profile.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && port != nil && port != 0 }

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
                Text("One host. Remote Login (sshd) must be enabled. When Oppi’s Tailscale node is running, *.ts.net hosts use it; other hosts use your current network.")
            }.disabled(connecting)

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
                            }.disabled(connecting)
                            Text("Replace the old entry in ~/.ssh/authorized_keys with the new public key before connecting.")
                                .font(.footnote).foregroundStyle(.themeComment)
                        }
                    }
                } header: { Text("This Device’s SSH Identity") } footer: {
                    Text("Append this public key to ~/.ssh/authorized_keys. Signing requires Face ID or your device passcode. The simulator uses a software key. Oppi never installs the key for you.")
                }
            }

            Section {
                if connecting {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(savingHostOnly ? "Saving Host…" : "Connecting…")
                        Spacer()
                        Button("Cancel") { cancel() }
                    }.accessibilityIdentifier("sshTerminal.connecting")
                } else {
                    Button("Connect") { connect() }.disabled(!canConnect)
                        .accessibilityIdentifier("sshTerminal.connect")
                    Button("Save Host") { saveHost() }.disabled(!canConnect)
                        .accessibilityIdentifier("sshTerminal.saveHost")
                }
                if let failure {
                    Text("Disconnected — \(failure)").foregroundStyle(.themeRed)
                        .accessibilityIdentifier("sshTerminal.failure")
                }
                trustRows
            } footer: {
                Text("Saved passwords stay only in this device’s private Keychain and require Face ID or passcode at connect. Unsaved passwords are used for one attempt only. Keyboard-interactive and private-key import are not supported. Reconnect opens a fresh shell; use tmux to preserve work. Input is never replayed.")
            }
            if SSHTerminalProfileStore().hasStoredProfile {
                Section {
                    Button("Delete Host", role: .destructive) { deleteConfirmation = true }
                        .accessibilityIdentifier("sshTerminal.deleteHost")
                }
            }
        }
        .navigationTitle("SSH Terminal").navigationBarTitleDisplayMode(.inline)
        .task {
            guard experimentEnabled else { return }
            if SSHTerminalProfileStore().hasStoredProfile && SSHTerminalProfileStore().load() == nil {
                failure = "The saved host profile cannot be read. Delete Host to clear its saved password, then configure it again."
            }
            // Opening never dials: Connect is always an explicit tap, so
            // visiting the page never triggers a Face ID or password prompt.
            loadIdentityIfSelected()
        }
        .onChange(of: profile.authentication) { loadIdentityIfSelected() }
        .onChange(of: profile.host) { hostFailure = nil; failure = nil }
        .onChange(of: portText) { hostFailure = nil; failure = nil }
        .onChange(of: experimentEnabled) { _, enabled in if !enabled { cancel(); showsTerminal = false } }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            password = ""
            passwordPrompt = false
            if connecting {
                cancel()
                failure = "Connection cancelled when Oppi entered the background. Connect again to open a fresh shell."
            }
        }
        .confirmationDialog("Forget the trusted host key?", isPresented: $forgetConfirmation, titleVisibility: .visible) {
            Button("Forget Trusted Key", role: .destructive) {
                do {
                    try SSHKnownHosts().forget(host: attemptedHost, port: attemptedPort)
                    hostFailure = nil
                    failure = "Trusted key forgotten. Verify the new fingerprint before trusting it."
                } catch { failure = error.localizedDescription }
            }
        } message: { Text("Only do this after independently verifying why the host key changed.") }
        .confirmationDialog("Delete this host and its saved password?", isPresented: $deleteConfirmation, titleVisibility: .visible) {
            Button("Delete Host", role: .destructive) {
                do {
                    cancel()
                    try SSHTerminalProfileStore().delete()
                    profile = SSHTerminalProfile()
                    portText = "22"
                    identity = nil
                    failure = nil
                    hostFailure = nil
                } catch { failure = error.localizedDescription }
            }
        }
        .sheet(isPresented: $passwordPrompt, onDismiss: { password = "" }) {
            NavigationStack {
                Form {
                    Section {
                        SecureField("Password", text: $password).textContentType(nil)
                            .accessibilityIdentifier("sshTerminal.password")
                    } header: { Text("\(profile.username)@\(target)") }
                    Section {
                        Toggle("Save Password", isOn: $profile.savesPassword)
                        Text("Saving requires a device passcode. Face ID or passcode approval is required whenever Oppi reads it.")
                            .font(.footnote).foregroundStyle(.themeComment)
                    }
                }
                .navigationTitle("SSH Sign In")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { password = ""; passwordPrompt = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(savingHostOnly ? "Save" : "Connect") {
                            let attempt = password
                            password = ""
                            passwordPrompt = false
                            if savingHostOnly { saveHost(password: attempt) }
                            else { connect(password: attempt) }
                        }.disabled(password.isEmpty).accessibilityIdentifier("sshTerminal.passwordConnect")
                    }
                }
            }.presentationDetents([.medium])
        }
        .navigationDestination(isPresented: $showsTerminal) {
            if let channel {
                SSHTerminalView(channel: channel) { connect() }
                    .id(ObjectIdentifier(channel))
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Edit Host") { showsTerminal = false }
                        }
                    }
            }
        }
        .onDisappear { if !showsTerminal { cancel() } }
        .onChange(of: showsTerminal) { _, visible in if !visible { cancel() } }
    }

    private func loadIdentityIfSelected(createReplacement: Bool = false) {
        guard experimentEnabled, profile.authentication == .deviceKey else { identity = nil; return }
        do {
            identity = try SSHIdentityKeyStore.loadOrCreate(createReplacement: createReplacement)
            identityFailure = nil
            identityNeedsReplacement = false
            if createReplacement { failure = "New SSH key created. Replace the old entry in ~/.ssh/authorized_keys before connecting." }
        } catch {
            identity = nil
            identityNeedsReplacement = (error as? SSHIdentityKeyStoreError) == .devicePasscodeChanged
            identityFailure = error.localizedDescription
        }
    }

    private func normalizedProfile() -> SSHTerminalProfile {
        var result = profile
        result.host = target
        result.username = profile.username.trimmingCharacters(in: .whitespacesAndNewlines)
        result.port = port ?? 22
        if result.authentication == .deviceKey { result.savesPassword = false }
        return result
    }

    private func saveHost(password: String? = nil) {
        guard experimentEnabled, canConnect else { return }
        let value = normalizedProfile()
        let old = SSHTerminalProfileStore().load()
        if value.authentication == .password && value.savesPassword && password == nil
            && !(old.map { value.sameCredentials(as: $0) && $0.savesPassword } ?? false) {
            savingHostOnly = true
            passwordPrompt = true
            return
        }
        cancel()
        let id = UUID()
        runID = id
        connecting = true
        savingHostOnly = true
        failure = nil
        task = Task {
            do {
                // Updating a presence-protected item can wait for approval.
                // Never block SwiftUI's main actor on a Security call.
                try await Task.detached { try SSHTerminalProfileStore().save(value, password: password) }.value
                guard !Task.isCancelled, runID == id else { return }
                profile = value
            } catch {
                guard !Task.isCancelled, runID == id else { return }
                failure = error.localizedDescription
            }
            connecting = false
            savingHostOnly = false
        }
    }

    @ViewBuilder private var trustRows: some View {
        if case .unknownHostKey(let key) = hostFailure {
            Text("New host — trust decision").font(.headline).accessibilityIdentifier("sshTerminal.trustPrompt")
            fingerprint("Presented Host Key", key)
            Text("Verify this fingerprint on the host before trusting it. No credentials were sent.")
                .font(.footnote).foregroundStyle(.themeComment)
            Button("Trust & Connect") {
                guard target == attemptedHost, port == attemptedPort else { return }
                do { try SSHKnownHosts().trust(key, host: attemptedHost, port: attemptedPort); connect() }
                catch { failure = error.localizedDescription }
            }.disabled(connecting).accessibilityIdentifier("sshTerminal.trustKey")
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

    private func connect(password suppliedPassword: String? = nil) {
        guard experimentEnabled, canConnect else { return }
        let value = normalizedProfile()
        let old = SSHTerminalProfileStore().load()
        let hasSavedPassword = old.map { value.sameCredentials(as: $0) && $0.savesPassword } ?? false
        if value.authentication == .password && suppliedPassword == nil && !(hasSavedPassword && value.savesPassword) {
            savingHostOnly = false
            passwordPrompt = true
            return
        }
        cancel()
        let id = UUID()
        runID = id
        attemptedHost = value.host
        attemptedPort = value.port
        connecting = true
        savingHostOnly = false
        failure = nil
        hostFailure = nil
        task = Task {
            do {
                try await Task.detached { try SSHTerminalProfileStore().save(value, password: suppliedPassword) }.value
                guard !Task.isCancelled, runID == id else { return }
                profile = value
                let savedKey = try SSHKnownHosts().savedKey(host: value.host, port: value.port)
                let owner = try SSHTerminalChannel()
                channel = owner
                let tailnet = TailnetNodeController.shared
                let useTailnet = value.host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")).hasSuffix(".ts.net") && tailnet.state == .running
                let queue = SSHTerminalEventQueue()
                let session: SSHPTYSession
                do {
                    session = try await SSHPTYSession.connect(
                        username: value.username, savedHostKey: savedKey, inboundFlow: queue.flow,
                        prepareAuthentication: {
                            switch value.authentication {
                            case .password:
                                if let suppliedPassword { return .password(suppliedPassword) }
                                let stored = try await Task.detached { try SSHTerminalProfileStore().password(for: value) }.value
                                guard let stored else { throw SSHKeychainError.passwordRequired }
                                return .password(stored)
                            case .deviceKey:
                                return .deviceKey(try await SSHIdentityKeyStore.authenticatedIdentity())
                            }
                        }, dial: {
                            try await (useTailnet
                                ? tailnet.dialTCP(host: value.host, port: value.port, timeout: .seconds(15))
                                : SSHDirectTCP.dial(host: value.host, port: value.port))
                        }, sink: { queue.push($0) }
                    )
                } catch { queue.finish(); throw error }
                guard !Task.isCancelled, runID == id else { queue.finish(); await session.cancel(); return }
                owner.opened(session)
                connecting = false
                showsTerminal = true
                // Sign-in's task (and its password capture) ends here. The
                // long-lived byte consumer owns no authentication material.
                task = Task { await owner.consume(queue) }
            } catch {
                guard runID == id, !Task.isCancelled else { return }
                if (error as? SSHIdentityKeyStoreError) == .devicePasscodeChanged {
                    identity = nil
                    identityNeedsReplacement = true
                    identityFailure = error.localizedDescription
                }
                hostFailure = error as? SSHPTYSessionError
                switch hostFailure {
                case .unknownHostKey, .hostKeyMismatch:
                    failure = nil
                    channel?.close(reason: "Host trust needs review. Use Edit Host to compare the fingerprints.")
                default:
                    failure = SSHTerminalChannel.message(error)
                    channel?.close(reason: failure ?? "Connection failed.")
                }
                connecting = false
                if let keychainError = error as? SSHKeychainError, keychainError == .passwordRequired {
                    savingHostOnly = false
                    passwordPrompt = true
                }
            }
        }
    }

    private func cancel() {
        runID = UUID()
        task?.cancel()
        task = nil
        password = ""
        channel?.close(reason: "Closed by you.")
        connecting = false
    }
}
