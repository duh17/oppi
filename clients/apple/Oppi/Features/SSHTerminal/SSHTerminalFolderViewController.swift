import UIKit

/// Opens the folder terminal for one saved host: the connecting, password, and
/// host-trust states, then the live terminal. The terminal belongs to
/// `SSHTerminalRegistry` from the moment it opens, so leaving this screen keeps
/// it and pressing Terminal again for the same folder returns to it.
///
/// Which terminal that is depends on the host's Run on Connect command
/// (`SSHTerminalFolderEntry.prepare`): a multiplexer that opens folders inside
/// its own terminal (Herdr) shows the host's terminal and hands it the folder, a
/// multiplexer that wants a terminal of its own (tmux) gets one running its
/// attach command, and a plain host gets the login shell in the folder.
final class SSHTerminalFolderViewController: UIViewController {
    /// Follows the password sheet's Save Password toggle, like the host list's
    /// connecting profile, so the saved choice is the one used and stored.
    private var profile: SSHTerminalProfile
    private let target: SSHTerminalFolderTarget
    private let session = SSHTerminalConnectSession()
    private var chrome: SSHTerminalConnectChrome?

    private let statusLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private var lastThemeID: ThemeID?
    /// The terminal has been reached. From then on this connecting screen's job
    /// is done, so it leaves with the terminal instead of waiting to be popped.
    private var hasShownTerminal = false

    init(profile: SSHTerminalProfile, target: SSHTerminalFolderTarget) {
        self.profile = profile.normalized()
        self.target = target
        super.init(nibName: nil, bundle: nil)
        title = (target.folder as NSString).lastPathComponent
        navigationItem.largeTitleDisplayMode = .inline
        // The folder is what makes this terminal different from the host's own.
        navigationItem.backBarButtonItem = UIBarButtonItem(title: String(localized: "Terminal"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "sshTerminal.folder"
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.adjustsFontForContentSizeCategory = true
        var retry = UIButton.Configuration.tinted()
        retry.title = String(localized: "Retry")
        retryButton.configuration = retry
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.accessibilityIdentifier = "sshTerminal.folder.retry"
        retryButton.addAction(UIAction { [weak self] _ in self?.connect() }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [statusLabel, retryButton])
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.readableContentGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.readableContentGuide.trailingAnchor),
        ])

        chrome = SSHTerminalConnectChrome(
            host: self,
            session: session,
            profile: { [weak self] in self?.profile ?? SSHTerminalProfile() },
            setProfile: { [weak self] in self?.profile = $0 },
            editHost: { [weak self] in self?.editHost() },
            submitPassword: { [weak self] password in self?.connect(password: password) },
            onSaved: { [weak self] _ in self?.setNeedsUpdateProperties() }
        )
        chrome?.start()
        connect()
        setNeedsUpdateProperties()
    }

    /// Back from the terminal returns here; this screen then leaves too, so Back
    /// keeps going to the chat or workspace that opened it. Popping from
    /// `viewDidAppear` keeps the two transitions in order.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if hasShownTerminal, !session.showsTerminal {
            Router.finish(self)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        chrome?.hostDidDisappear()
        if isMovingFromParent || isBeingDismissed {
            chrome?.stopObserving()
        }
    }

    override func updateProperties() {
        super.updateProperties()
        _ = session.connecting
        _ = session.failure
        _ = session.passwordPrompt
        _ = session.showsTerminal
        let themeID = sshTerminalThemeID
        if lastThemeID != themeID {
            lastThemeID = themeID
            view.backgroundColor = UIColor(themeID.palette.bg)
            statusLabel.textColor = UIColor(themeID.palette.comment)
            retryButton.tintColor = UIColor(themeID.palette.blue)
        }
        let folder = target.folderLabel
        if let failure = session.failure {
            statusLabel.text = String(localized: "Could not open \(folder) on \(profile.endpointLabel).\n\n\(failure)")
            statusLabel.accessibilityIdentifier = "sshTerminal.folder.failure"
        } else {
            statusLabel.text = multiplexerLabel(folder)
            statusLabel.accessibilityIdentifier = "sshTerminal.folder.connecting"
        }
        statusLabel.accessibilityValue = folder
        // Retry is for a failure the person can act on; a live shell is the
        // terminal screen, and a password or trust sheet is over this one.
        retryButton.isHidden = session.failure == nil || session.connecting
            || session.showsTerminal || session.passwordPrompt
        if session.showsTerminal { hasShownTerminal = true }
        chrome?.sync()
    }

    /// Edit Host in the terminal's … menu opens the saved host's form over
    /// whichever screen is on top (the terminal, once this screen has gone).
    private func editHost() {
        let presenter = navigationController?.topViewController ?? self
        Router.push(SSHTerminalSetupViewController(profileID: profile.id), from: presenter)
    }

    private func connect(password: String? = nil) {
        guard AppPreferences.Experiments.sshTerminalEnabled else { return }
        // What this folder opens in, decided again on every attempt: the host's
        // own multiplexer terminal, a folder terminal running its command, or
        // the plain login shell.
        SSHTerminalFolderEntry.prepare(session: session, profile: profile, target: target)
        session.connect(
            profile: profile,
            suppliedPassword: password,
            experimentEnabled: true
        )
    }

    /// The connecting line, naming the multiplexer when the folder opens inside
    /// one, so the wait says where the folder will land.
    private func multiplexerLabel(_ folder: String) -> String {
        guard let kind = SSHTerminalMultiplexerKind.detected(in: profile.startupCommand) else {
            return String(localized: "Connecting to \(profile.endpointLabel)…")
        }
        return String(localized: "Opening \(folder) in \(kind.multiplexer.name) on \(profile.endpointLabel)…")
    }
}
