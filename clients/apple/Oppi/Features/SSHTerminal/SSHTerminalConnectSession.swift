import Foundation
import Observation

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
    /// The folder this session's shell starts in, or nil for the host's own
    /// terminal. Set before `connect`; it is part of the terminal's identity.
    var folder: String?
    /// What a folder terminal runs instead of the plain login shell, when the
    /// host's multiplexer needs a terminal of its own (tmux). Nil keeps the
    /// plain folder shell.
    var folderTerminalCommand: String?
    /// A folder to open inside the multiplexer running in the host's own
    /// terminal (Herdr), once that terminal is up. The terminal screen runs it,
    /// so a refusal shows over the terminal it leaves the person in.
    var multiplexerFolder: SSHTerminalFolderTarget?
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
        // Same host, same folder, same settings, shell still open: show it. No dial, no sign-in.
        if let live = registry.terminal(for: value.id, folder: folder), live.profile == value {
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
        let attempt = runID
        task = Task {
            defer { registry.untrack(attempt: attempt) }
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
                // A folder terminal runs the login shell in that folder, or the
                // multiplexer's own attach command there: the host's Run on
                // Connect command belongs to its own terminal.
                let folder = self.folder
                let folderCommand = self.folderTerminalCommand
                let command: String?
                if let folder {
                    command = folderCommand ?? SSHTerminalFolderCommand.command(folder: folder)
                } else {
                    command = value.startupCommand
                }
                do {
                    session = try await SSHPTYSession.connect(
                        username: value.username, savedHostKey: savedKey, inboundFlow: queue.flow,
                        command: command,
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
                owner.opened(session, command: command)
                // Sign-in's task (and its password capture) ends here. The
                // registry's byte consumer owns no authentication material.
                // It refuses (and closes `owner`) when Oppi is in the background
                // with no grace left to close the session.
                let adopted = registry.adopt(owner, profile: value, folder: folder, queue: queue)
                task = nil
                connecting = false
                if adopted {
                    showsTerminal = true
                } else {
                    failure = Self.backgroundFailure
                }
            } catch {
                guard runID == self.runID, !Task.isCancelled else { return }
                noteFailure(error, profile: value)
            }
        }
        if let task {
            // Backgrounding or turning the experiment off ends this attempt even
            // when no view of this session is mounted (a reconnect from the
            // terminal screen, for one).
            registry.track(attempt: attempt, task: task) { [weak self] end in
                switch end {
                case .background: self?.handleBackground()
                case .experimentDisabled: self?.handleExperimentDisabled()
                }
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
        let attempt = runID
        task = Task {
            do {
                // Updating a presence-protected item can wait for approval.
                // Never block the main actor on a Security call.
                try await Task.detached { try SSHTerminalProfileStore().save(value, password: suppliedPassword) }.value
                guard !Task.isCancelled, runID == self.runID else { return }
                registry.reconcile(saved: value)
                onSaved?(value)
            } catch {
                guard !Task.isCancelled, runID == self.runID else { return }
                failure = error.localizedDescription
            }
            // Saving may continue into a connect (Add Host for a folder
            // terminal). That attempt owns the flags now, so the save's tail
            // must not clear them.
            guard runID == attempt else { return }
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
        stopAttempt()
        closeUnregisteredChannel(reason: "Closed by you.")
    }

    static let backgroundFailure = "Connection cancelled when Oppi entered the background. Connect again to open a fresh shell."

    /// An attempt cancelled by the background closes its channel as a
    /// background close, so a terminal screen that is up reconnects on return.
    func handleBackground() {
        password = ""
        passwordPrompt = false
        guard connecting else { return }
        stopAttempt()
        if let channel, !registry.holds(channel) { channel.closeForBackground() }
        failure = Self.backgroundFailure
    }

    /// The registry ends the terminals itself when the flag turns off. This
    /// ends what belongs to this session: its attempt and its screen.
    func handleExperimentDisabled() {
        cancel()
        showsTerminal = false
    }

    private func stopAttempt() {
        registry.untrack(attempt: runID)
        runID = UUID()
        task?.cancel()
        task = nil
        password = ""
        connecting = false
        savingHostOnly = false
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
