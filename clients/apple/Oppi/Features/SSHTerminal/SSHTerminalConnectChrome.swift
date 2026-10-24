import UIKit

/// Password, host-key trust, forget confirmation, and the terminal push shared
/// by the UIKit host list and Add/Edit Host form. Connect logic stays on
/// `SSHTerminalConnectSession`.
@MainActor
final class SSHTerminalConnectChrome {
    private weak var host: UIViewController?
    private let session: SSHTerminalConnectSession
    private let profile: () -> SSHTerminalProfile
    private let setProfile: (SSHTerminalProfile) -> Void
    private let editHost: () -> Void
    private let submitPassword: (String) -> Void
    private let onSaved: (SSHTerminalProfile) -> Void

    private weak var passwordScreen: UIViewController?
    private weak var trustScreen: UIViewController?
    private var presentedTrustFailure: SSHConnectionError?
    private var lastWasBackground = false
    private var pushingTerminal = false
    private var showsTerminalEdge = SSHTerminalShowsTerminalEdge()

    init(
        host: UIViewController,
        session: SSHTerminalConnectSession,
        profile: @escaping () -> SSHTerminalProfile,
        setProfile: @escaping (SSHTerminalProfile) -> Void,
        editHost: @escaping () -> Void,
        submitPassword: @escaping (String) -> Void,
        onSaved: @escaping (SSHTerminalProfile) -> Void
    ) {
        self.host = host
        self.session = session
        self.profile = profile
        self.setProfile = setProfile
        self.editHost = editHost
        self.submitPassword = submitPassword
        self.onSaved = onSaved
    }

    /// Covered or popped. In-flight connect ends unless the terminal is showing
    /// or a connect prompt (password, trust) is up over this screen.
    func hostDidDisappear() {
        if host?.presentedViewController != nil { return }
        if !session.showsTerminal { session.cancel() }
    }

    func sync() {
        guard let host else { return }
        let isBackground = AppScenePhase.shared.isBackground
        if !lastWasBackground, isBackground {
            session.handleBackground()
        }
        lastWasBackground = isBackground

        if session.passwordPrompt {
            presentPassword(from: host)
        } else {
            dismissPassword()
        }

        switch session.hostFailure {
        case .unknownHostKey, .hostKeyMismatch:
            presentTrust(from: host)
        default:
            presentedTrustFailure = nil
            dismissTrust()
        }

        if session.forgetConfirmation {
            session.forgetConfirmation = false
            presentForgetConfirmation(from: host)
        }

        if showsTerminalEdge.shouldCancelAttempt(showsTerminal: session.showsTerminal) {
            session.cancel()
        }
        if session.showsTerminal {
            pushTerminal(from: host)
        } else {
            pushingTerminal = false
        }
    }

    func requestForget() {
        session.forgetConfirmation = true
        if let host { presentForgetConfirmation(from: host) }
        session.forgetConfirmation = false
    }

    /// A reconnect of a terminal the switcher showed is for that terminal's
    /// host, not for this screen's: its prompts name that host and act on it.
    private var reconnectTarget: SSHTerminalConnectSession.PromptTarget? {
        session.promptTarget.flatMap { $0.isReconnect ? $0 : nil }
    }

    /// The profile a prompt is about: the reconnect's, else this screen's.
    private func promptProfile() -> SSHTerminalProfile {
        reconnectTarget?.profile ?? profile()
    }

    /// Tells this screen what a connect saved, only when the connect is for
    /// this screen's own host: a form for host A must not turn into host B's
    /// because a switched terminal reconnected.
    private func savedHandler(for target: SSHTerminalProfile) -> ((SSHTerminalProfile) -> Void)? {
        target.id == profile().id ? onSaved : nil
    }

    private func presentPassword(from host: UIViewController) {
        guard passwordScreen == nil else { return }
        let shown = promptProfile()
        let screen = SSHTerminalPasswordViewController(
            endpointLabel: shown.endpointLabel,
            savesPassword: shown.savesPassword,
            confirmTitle: session.savingHostOnly ? "Save" : "Connect",
            onSavesPasswordChange: { [weak self] saves in
                guard let self else { return }
                if self.reconnectTarget != nil {
                    self.session.setPromptSavesPassword(saves)
                    return
                }
                var next = self.profile()
                next.savesPassword = saves
                self.setProfile(next)
            },
            onCancel: { [weak self] in
                self?.session.password = ""
                self?.session.passwordPrompt = false
            },
            onConfirm: { [weak self] password in
                guard let self else { return }
                let isReconnect = self.reconnectTarget != nil
                self.session.password = ""
                self.session.passwordPrompt = false
                if isReconnect {
                    self.session.submitPrompt(
                        password: password, onSaved: self.savedHandler(for: self.promptProfile())
                    )
                } else {
                    self.submitPassword(password)
                }
            }
        )
        passwordScreen = screen
        Router.present(
            screen,
            presentation: .sheet.detents([.medium()]).inNavigation(),
            from: host,
            onDismiss: { [weak self] in
                self?.passwordScreen = nil
                self?.session.password = ""
                self?.session.passwordPrompt = false
            }
        )
    }

    private func dismissPassword() {
        guard let passwordScreen else { return }
        self.passwordScreen = nil
        Router.finish(passwordScreen)
    }

    private func presentTrust(from host: UIViewController) {
        guard let failure = session.hostFailure else { return }
        if presentedTrustFailure == failure {
            // Same failure: keep the open sheet, or leave a list row to reopen.
            return
        }
        if trustScreen != nil { dismissTrust() }
        presentedTrustFailure = failure
        let screen = SSHTerminalTrustViewController(
            failure: failure,
            connecting: session.connecting,
            onTrust: { [weak self] in
                guard let self else { return }
                self.session.trustAndConnect(
                    profile: self.promptProfile(),
                    onSaved: self.savedHandler(for: self.promptProfile())
                )
            },
            onForget: { [weak self] in self?.requestForget() }
        )
        trustScreen = screen
        Router.present(
            screen,
            presentation: .sheet.detents([.medium(), .large()]).inNavigation(),
            from: host,
            onDismiss: { [weak self] in
                self?.trustScreen = nil
            }
        )
    }

    private func dismissTrust() {
        guard let trustScreen else { return }
        self.trustScreen = nil
        Router.finish(trustScreen)
    }

    func reopenTrust() {
        presentedTrustFailure = nil
        if let host { presentTrust(from: host) }
    }

    private func presentForgetConfirmation(from host: UIViewController) {
        let alert = UIAlertController(
            title: "Forget the trusted host key?",
            message: "Only do this after independently verifying why the host key changed.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Forget Trusted Key", style: .destructive) { [weak self] _ in
            self?.session.forgetTrustedKey()
            self?.presentedTrustFailure = nil
            self?.dismissTrust()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        (host.presentedViewController ?? host).present(alert, animated: true)
    }

    private func pushTerminal(from host: UIViewController) {
        guard !pushingTerminal, session.channel != nil else { return }
        pushingTerminal = true
        let session = session
        let editHost = editHost
        let hostLabel = profile().terminalLabel(folder: session.folder)
        DispatchQueue.main.async {
            guard session.showsTerminal, let channel = session.channel else { return }
            Router.push(SSHTerminalViewController(
                channel: channel,
                reconnect: { session.reconnect() },
                editHost: editHost,
                hostLabel: hostLabel,
                session: session
            ), from: host)
        }
    }
}

extension UIViewController {
    var sshTerminalThemeID: ThemeID {
        HostFactory.root(near: self)?.themeStore.activeThemeID ?? ThemeRuntimeState.currentThemeID()
    }
}
