import UIKit

/// Opens the folder terminal for one saved host: the connecting, password, and
/// host-trust states, then the live terminal. The shell belongs to
/// `SSHTerminalRegistry` from the moment it opens, so leaving this screen keeps
/// it and pressing Terminal again for the same folder returns to it.
final class SSHTerminalFolderViewController: UIViewController {
    private let profile: SSHTerminalProfile
    private let target: SSHTerminalFolderTarget
    private let session = SSHTerminalConnectSession()
    private var chrome: SSHTerminalConnectChrome?

    private let statusLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private var lastThemeID: ThemeID?

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
            setProfile: { _ in },
            editHost: { [weak self] in self?.session.showsTerminal = false },
            submitPassword: { [weak self] password in self?.connect(password: password) },
            onSaved: { [weak self] _ in self?.setNeedsUpdateProperties() }
        )
        chrome?.start()
        session.folder = target.folder
        connect()
        setNeedsUpdateProperties()
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
            statusLabel.text = String(localized: "Connecting to \(profile.endpointLabel)…")
            statusLabel.accessibilityIdentifier = "sshTerminal.folder.connecting"
        }
        statusLabel.accessibilityValue = folder
        // Retry is for a failure the person can act on; a live shell is the
        // terminal screen, and a password or trust sheet is over this one.
        retryButton.isHidden = session.failure == nil || session.connecting
            || session.showsTerminal || session.passwordPrompt
        chrome?.sync()
    }

    private func connect(password: String? = nil) {
        guard AppPreferences.Experiments.sshTerminalEnabled else { return }
        session.folder = target.folder
        session.connect(
            profile: profile,
            suppliedPassword: password,
            experimentEnabled: true
        )
    }
}
