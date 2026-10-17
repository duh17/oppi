import SwiftUI

/// Trust, password, and dial path shared by the host list and the setup form.
/// The view that starts Connect presents the password sheet and trust UI.
/// Opening either surface must not call `connect` or `password(for:)`.
///
/// It is one presentation's connect attempt. An opened shell belongs to
/// `SSHTerminalRegistry`, which keeps it when this session goes away; a later
/// Connect for the same saved host attaches to it instead of dialing again.
@MainActor @Observable
final class SSHTerminalConnectSession {
    var connecting = false
    var savingHostOnly = false
    var failure: String?
    var hostFailure: SSHConnectionError?
    var attemptedHost = ""
    var attemptedPort: UInt16 = 22
    var forgetConfirmation = false
    var passwordPrompt = false
    var password = ""
    var channel: SSHTerminalChannel?
    var showsTerminal = false
    var connectedProfile: SSHTerminalProfile?
    var devicePasscodeChanged = false
    private var task: Task<Void, Never>?
    private var runID = UUID()
    @ObservationIgnored private let registry: SSHTerminalRegistry

    init(registry: SSHTerminalRegistry = .shared) {
        self.registry = registry
    }

    func connect(
        profile: SSHTerminalProfile,
        suppliedPassword: String? = nil,
        experimentEnabled: Bool,
        onSaved: ((SSHTerminalProfile) -> Void)? = nil
    ) {
        guard experimentEnabled else { return }
        let value = profile.normalized()
        guard value.isConfigured else { return }
        // Same host, same settings, shell still open: show it. No dial, no sign-in.
        if let live = registry.terminal(for: value.id), live.profile == value {
            cancel()
            failure = nil
            hostFailure = nil
            connectedProfile = value
            channel = live.channel
            showsTerminal = true
            return
        }
        // A lock that is due but not applied yet covers Oppi as well.
        if AppLockService.shared.requiresUnlock() { SSHApprovalCache.shared.invalidateAll() }
        let old = SSHTerminalProfileStore().profile(id: value.id)
        if value.authentication == .password && suppliedPassword == nil
            && !(value.reusesSavedPassword(of: old) && value.savesPassword) {
            savingHostOnly = false
            passwordPrompt = true
            return
        }
        begin(value, savingHostOnly: false)
        task = Task {
            do {
                try await Task.detached { try SSHTerminalProfileStore().save(value, password: suppliedPassword) }.value
                guard !Task.isCancelled, runID == self.runID else { return }
                registry.reconcile(saved: value)
                onSaved?(value)
                connectedProfile = value
                let savedKey = try SSHKnownHosts().savedKey(host: value.host, port: value.port)
                let owner = try SSHTerminalChannel()
                channel = owner
                let queue = SSHTerminalEventQueue()
                let session: SSHPTYSession
                do {
                    session = try await SSHPTYSession.connect(
                        username: value.username, savedHostKey: savedKey, inboundFlow: queue.flow,
                        command: value.startupCommand,
                        prepareAuthentication: {
                            switch value.authentication {
                            case .password:
                                if let suppliedPassword { return .password(suppliedPassword) }
                                let stored = try await SSHTerminalProfileStore().approvedPassword(for: value)
                                guard let stored else { throw SSHKeychainError.passwordRequired }
                                return .password(stored)
                            case .deviceKey:
                                return .deviceKey(try await SSHIdentityKeyStore.authenticatedIdentity())
                            }
                        }, dial: {
                            try await SSHDial.socket(host: value.host, port: value.port, whenNodeStopped: .direct)
                        }, sink: { queue.push($0) }
                    )
                } catch { queue.finish(); throw error }
                guard !Task.isCancelled, runID == self.runID else { queue.finish(); await session.cancel(); return }
                owner.opened(session, command: value.startupCommand)
                // Sign-in's task (and its password capture) ends here. The
                // registry's byte consumer owns no authentication material.
                registry.adopt(owner, profile: value, queue: queue)
                task = nil
                connecting = false
                showsTerminal = true
            } catch {
                guard runID == self.runID, !Task.isCancelled else { return }
                noteFailure(error, profile: value)
            }
        }
    }

    func saveHost(
        profile: SSHTerminalProfile,
        suppliedPassword: String? = nil,
        experimentEnabled: Bool,
        onSaved: ((SSHTerminalProfile) -> Void)? = nil
    ) {
        guard experimentEnabled else { return }
        let value = profile.normalized()
        guard value.isConfigured else { return }
        let old = SSHTerminalProfileStore().profile(id: value.id)
        if value.authentication == .password && value.savesPassword && suppliedPassword == nil
            && !value.reusesSavedPassword(of: old) {
            savingHostOnly = true
            passwordPrompt = true
            return
        }
        begin(value, savingHostOnly: true)
        task = Task {
            do {
                // Updating a presence-protected item can wait for approval.
                // Never block SwiftUI's main actor on a Security call.
                try await Task.detached { try SSHTerminalProfileStore().save(value, password: suppliedPassword) }.value
                guard !Task.isCancelled, runID == self.runID else { return }
                registry.reconcile(saved: value)
                onSaved?(value)
            } catch {
                guard !Task.isCancelled, runID == self.runID else { return }
                failure = error.localizedDescription
            }
            connecting = false
            savingHostOnly = false
        }
    }

    func reconnect(experimentEnabled: Bool, onSaved: ((SSHTerminalProfile) -> Void)? = nil) {
        guard let connectedProfile else { return }
        connect(profile: connectedProfile, experimentEnabled: experimentEnabled, onSaved: onSaved)
    }

    func trustAndConnect(
        profile: SSHTerminalProfile,
        experimentEnabled: Bool,
        onSaved: ((SSHTerminalProfile) -> Void)? = nil
    ) {
        let value = profile.normalized()
        guard value.host == attemptedHost, value.port == attemptedPort,
              case .unknownHostKey(let key) = hostFailure else { return }
        do {
            try SSHKnownHosts().trust(key, host: attemptedHost, port: attemptedPort)
            connect(profile: value, experimentEnabled: experimentEnabled, onSaved: onSaved)
        } catch {
            failure = error.localizedDescription
        }
    }

    func forgetTrustedKey() {
        do {
            try SSHKnownHosts().forget(host: attemptedHost, port: attemptedPort)
            hostFailure = nil
            failure = "Trusted key forgotten. Verify the new fingerprint before trusting it."
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Stops a connect in flight. A shell the registry owns is not this
    /// session's to close: Disconnect and the host's lifecycle end it.
    func cancel() {
        runID = UUID()
        task?.cancel()
        task = nil
        password = ""
        closeUnregisteredChannel(reason: "Closed by you.")
        connecting = false
        savingHostOnly = false
    }

    func handleBackground() {
        password = ""
        passwordPrompt = false
        guard connecting else { return }
        cancel()
        failure = "Connection cancelled when Oppi entered the background. Connect again to open a fresh shell."
    }

    func handleExperimentDisabled() {
        cancel()
        registry.closeAll(reason: "SSH Terminal was turned off.")
        showsTerminal = false
    }

    private func closeUnregisteredChannel(reason: String) {
        guard let channel, !registry.holds(channel) else { return }
        channel.close(reason: reason)
    }

    private func begin(_ profile: SSHTerminalProfile, savingHostOnly: Bool) {
        cancel()
        let id = UUID()
        runID = id
        attemptedHost = profile.host
        attemptedPort = profile.port
        connecting = true
        self.savingHostOnly = savingHostOnly
        failure = nil
        hostFailure = nil
        devicePasscodeChanged = false
    }

    private func noteFailure(_ error: any Error, profile: SSHTerminalProfile) {
        if (error as? SSHIdentityKeyStoreError) == .devicePasscodeChanged {
            devicePasscodeChanged = true
        }
        // A credential failure ends any kept approval: the next attempt asks again.
        if SSHApprovalCache.isAuthenticationFailure(error) { SSHApprovalCache.shared.invalidateAll() }
        hostFailure = error as? SSHConnectionError
        switch hostFailure {
        case .unknownHostKey, .hostKeyMismatch:
            failure = nil
            closeUnregisteredChannel(reason: "Host trust needs review. Use Edit Host to compare the fingerprints.")
        default:
            failure = SSHTerminalChannel.message(error)
            closeUnregisteredChannel(reason: failure ?? "Connection failed.")
        }
        connecting = false
        if let keychainError = error as? SSHKeychainError, keychainError == .passwordRequired {
            savingHostOnly = false
            passwordPrompt = true
            connectedProfile = profile
        }
    }
}

struct SSHTerminalTrustRows: View {
    let hostFailure: SSHConnectionError?
    let connecting: Bool
    let trust: () -> Void
    let requestForget: () -> Void

    var body: some View {
        if case .unknownHostKey(let key) = hostFailure {
            Text("New host — trust decision").font(.headline).accessibilityIdentifier("sshTerminal.trustPrompt")
            fingerprint("Presented Host Key", key)
            Text("Verify this fingerprint on the host before trusting it. No credentials were sent.")
                .font(.footnote).foregroundStyle(.themeComment)
            Button("Trust & Connect", action: trust)
                .disabled(connecting).accessibilityIdentifier("sshTerminal.trustKey")
        } else if case .hostKeyMismatch(let saved, let presented) = hostFailure {
            Text("Host key changed — connection blocked.").foregroundStyle(.themeRed)
            fingerprint("Trusted", saved)
            fingerprint("Presented", presented)
            Button("Forget Trusted Key", role: .destructive, action: requestForget)
                .accessibilityIdentifier("sshTerminal.forgetKey")
        }
    }

    private func fingerprint(_ label: String, _ key: SSHHostKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(label) (\(key.algorithm))").font(.footnote).foregroundStyle(.themeComment)
            Text(key.fingerprint).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
        }.accessibilityElement(children: .combine)
    }
}

struct SSHTerminalConnectProgress: View {
    let savingHostOnly: Bool
    let cancel: () -> Void

    var body: some View {
        HStack {
            ProgressView().controlSize(.small)
            Text(savingHostOnly ? "Saving Host…" : "Connecting…")
            Spacer()
            Button("Cancel", action: cancel)
        }.accessibilityIdentifier("sshTerminal.connecting")
    }
}

private struct SSHTerminalConnectionModifier: ViewModifier {
    @Bindable var session: SSHTerminalConnectSession
    @Binding var profile: SSHTerminalProfile
    let experimentEnabled: Bool
    let editHost: () -> Void
    let submitPassword: (String) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.screenNavigator) private var navigator

    func body(content: Content) -> some View {
        content
            .routerModal(
                isPresented: $session.passwordPrompt,
                presentation: .sheet.detents([.medium()]).inNavigation(),
                onDismiss: { session.password = "" },
                content: {
                    Form {
                        Section {
                            SecureField("Password", text: $session.password).textContentType(nil)
                                .accessibilityIdentifier("sshTerminal.password")
                        } header: { Text(profile.endpointLabel) }
                        Section {
                            Toggle("Save Password", isOn: $profile.savesPassword)
                            Text("Saving requires a device passcode. Face ID or passcode approval is required when Oppi reads it, except for 5 minutes after you approve.")
                                .font(.footnote).foregroundStyle(.themeComment)
                        }
                    }
                    .navigationTitle("SSH Sign In")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(role: .cancel) { session.password = ""; session.passwordPrompt = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button(role: .confirm) {
                                let attempt = session.password
                                session.password = ""
                                session.passwordPrompt = false
                                submitPassword(attempt)
                            }
                            .disabled(session.password.isEmpty)
                            .accessibilityLabel(session.savingHostOnly ? "Save" : "Connect")
                            .accessibilityIdentifier("sshTerminal.passwordConnect")
                        }
                    }
                }
            )
            .confirmationDialog("Forget the trusted host key?", isPresented: $session.forgetConfirmation, titleVisibility: .visible) {
                Button("Forget Trusted Key", role: .destructive) { session.forgetTrustedKey() }
            } message: { Text("Only do this after independently verifying why the host key changed.") }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .background else { return }
                session.handleBackground()
            }
            .onChange(of: experimentEnabled) { _, enabled in
                if !enabled { session.handleExperimentDisabled() }
            }
            .onDisappear { if !session.showsTerminal { session.cancel() } }
            .onChange(of: session.showsTerminal) { _, visible in
                if visible { pushTerminal() } else { session.cancel() }
            }
    }

    /// Pushes the terminal over this screen, after the SwiftUI update that
    /// reported the open session.
    private func pushTerminal() {
        let session = session
        let editHost = editHost
        let hostLabel = profile.endpointLabel
        DispatchQueue.main.async { [navigator] in
            guard session.showsTerminal else { return }
            navigator.push {
                SSHTerminalScreen(session: session, editHost: editHost, hostLabel: hostLabel)
            }
        }
    }
}

/// The terminal a connect pushed. It pops itself when the session stops
/// showing it (Edit Host, the experiment turned off). Leaving it (Back, swipe)
/// only leaves the screen: the registry keeps the shell.
private struct SSHTerminalScreen: View {
    let session: SSHTerminalConnectSession
    let editHost: () -> Void
    let hostLabel: String
    @AppStorage(AppPreferences.Experiments.sshTerminalKey) private var experimentEnabled = false
    @Environment(\.screenNavigator) private var navigator
    @State private var isOnScreen = false

    var body: some View {
        Group {
            // Reconnecting opens a new channel and a fresh terminal for it.
            if let channel = session.channel {
                SSHTerminalView(
                    channel: channel,
                    reconnect: { session.reconnect(experimentEnabled: experimentEnabled) },
                    editHost: editHost,
                    hostLabel: hostLabel
                )
                .id(ObjectIdentifier(channel))
            }
        }
        .onAppear { isOnScreen = true }
        .onDisappear {
            isOnScreen = false
            session.showsTerminal = false
        }
        .onChange(of: session.showsTerminal) { _, visible in
            if !visible, isOnScreen { navigator.finish() }
        }
        .onChange(of: experimentEnabled) { _, enabled in
            if !enabled { session.handleExperimentDisabled() }
        }
    }
}

extension View {
    func sshTerminalConnection(
        session: SSHTerminalConnectSession,
        profile: Binding<SSHTerminalProfile>,
        experimentEnabled: Bool,
        editHost: @escaping () -> Void,
        submitPassword: @escaping (String) -> Void
    ) -> some View {
        modifier(SSHTerminalConnectionModifier(
            session: session, profile: profile, experimentEnabled: experimentEnabled,
            editHost: editHost, submitPassword: submitPassword
        ))
    }
}
