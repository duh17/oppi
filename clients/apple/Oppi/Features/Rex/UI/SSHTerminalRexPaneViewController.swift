import UIKit

/// Opens one Rex pane in its own terminal, for a saved SSH host or a Rex
/// reached over Tailscale alone: the connecting, password, host-trust, and
/// failure states, then the live terminal (`SSHTerminalViewController`).
///
/// Mirrors `SSHTerminalFolderViewController` for a Rex pane opened in a new
/// pane beside the Rex list: it calls `SSHTerminalConnectSession.openRexPane(_:on:)`
/// or `openTailnetRexPane(_:on:)` directly, without creating a follower or
/// re-reading Rex's session list, so a host reached over Tailscale never dials
/// SSH or prompts for a password or Face ID.
final class SSHTerminalRexPaneViewController: UIViewController, SSHTerminalOpener {
    /// Which Rex the pane belongs to.
    enum Source {
        case saved(SSHTerminalProfile)
        case tailnet(RexTailnetHost)
    }

    /// What `stateView` is showing, for the accessibility value and for tests.
    enum ShownState: String {
        case connecting
        case failure
    }

    private var source: Source
    private let target: RexPaneTarget
    private let session: SSHTerminalConnectSession
    private var chrome: SSHTerminalConnectChrome?
    private let stateView = UIContentUnavailableView(loadState: .loading(nil))

    /// The terminal has been reached. From then on this connecting screen's job
    /// is done, so it leaves with the terminal instead of waiting to be popped.
    private var hasShownTerminal = false
    /// True once `SSHTerminalViewController` was pushed onto this stack, as
    /// opposed to `focusPane` focusing another pane that already showed the channel.
    private var terminalPushed = false

    init(
        source: Source,
        target: RexPaneTarget,
        session: SSHTerminalConnectSession = SSHTerminalConnectSession()
    ) {
        switch source {
        case .saved(let profile): self.source = .saved(profile.normalized())
        case .tailnet(let host): self.source = .tailnet(host)
        }
        self.target = target
        self.session = session
        super.init(nibName: nil, bundle: nil)
        title = target.label
        navigationItem.largeTitleDisplayMode = .inline
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var profile: SSHTerminalProfile {
        switch source {
        case .saved(let profile): profile
        case .tailnet(let host): host.profile
        }
    }

    private var hostLabel: String {
        switch source {
        case .saved(let profile): profile.endpointLabel
        case .tailnet(let host): host.name
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "sshTerminal.rexPane"
        stateView.accessibilityIdentifier = "sshTerminal.rexPane.state"
        stateView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stateView)
        NSLayoutConstraint.activate([
            stateView.topAnchor.constraint(equalTo: view.topAnchor),
            stateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        chrome = SSHTerminalConnectChrome(
            host: self,
            session: session,
            profile: { [weak self] in self?.profile ?? SSHTerminalProfile() },
            setProfile: { [weak self] updated in
                guard let self, case .saved = self.source else { return }
                self.source = .saved(updated)
            },
            editHost: { [weak self] in self?.editHost() },
            submitPassword: { [weak self] password in self?.openPane(password: password) },
            onSaved: { [weak self] saved in
                guard let self, case .saved = self.source else { return }
                self.source = .saved(saved)
                self.setNeedsUpdateProperties()
            }
        )
        openPane()
        setNeedsUpdateProperties()
    }

    /// A swipe back from the terminal returns here; this screen then leaves
    /// too, so Back closes the pane instead of landing on the connecting page.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if hasShownTerminal, !session.showsTerminal {
            leave()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if session.showsTerminal,
           navigationController?.viewControllers.contains(where: { $0 is SSHTerminalViewController }) == true {
            terminalPushed = true
        }
        chrome?.hostDidDisappear()
    }

    /// Leaves with the terminal this screen opened; the terminal's Back comes
    /// here directly, so this connecting page is never shown on the way out.
    func leave() {
        let closesPane = navigationController?.viewControllers.first === self
            && navigationController?.presentingViewController == nil
        let showedHere = terminalPushed
            || navigationController?.viewControllers.contains(where: { $0 is SSHTerminalViewController }) == true
        if closesPane, showedHere, let channel = session.channel {
            session.registry.close(channel, reason: "Closed by you.")
        }
        Router.finish(self)
    }

    override func updateProperties() {
        super.updateProperties()
        _ = session.connecting
        _ = session.failure
        _ = session.hostFailure
        _ = session.forgetConfirmation
        _ = session.passwordPrompt
        _ = session.showsTerminal
        let palette = sshTerminalThemeID.palette
        view.backgroundColor = palette.ui.bg
        let paneName = target.label
        let state: LoadState
        if let failure = session.failure {
            stateView.accessibilityValue = ShownState.failure.rawValue
            let canRetry = !(session.connecting || session.showsTerminal || session.passwordPrompt)
            state = .failed(
                title: String(localized: "Could not open \(paneName) on \(hostLabel)"),
                message: failure,
                retry: canRetry ? RetryAction { [weak self] in self?.openPane() } : nil
            )
        } else {
            stateView.accessibilityValue = ShownState.connecting.rawValue
            state = .loading(String(localized: "Opening \(paneName) on \(hostLabel)\u{2026}"))
        }
        stateView.configuration = UIContentUnavailableConfiguration.loadState(
            state,
            palette: palette,
            background: palette.ui.bg
        )
        if session.showsTerminal {
            hasShownTerminal = true
        } else if hasShownTerminal, !terminalPushed {
            // Another pane already showed this channel and took focus; close this
            // opener pane without closing the other pane's live terminal.
            Router.finish(self)
            return
        }
        chrome?.sync()
    }

    private func editHost() {
        guard case .saved(let profile) = source else { return }
        let presenter = navigationController?.topViewController ?? self
        Router.push(SSHTerminalSetupViewController(profileID: session.connectedProfile?.id ?? profile.id), from: presenter)
    }

    private func openPane(password: String? = nil) {
        switch source {
        case .saved(let profile):
            session.openRexPane(target, on: profile, suppliedPassword: password)
        case .tailnet(let host):
            session.openTailnetRexPane(target, on: host)
        }
    }
}
