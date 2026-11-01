import UIKit

/// A Rex host's own screen (Multiplexer: Rex): every Rex session on the host
/// with its panes and their programs' status, read over a connection of its
/// own that runs no shell. A tapped pane opens on this device in a terminal of
/// its own; Shell opens the host's login shell. Sign-in, trust, and password
/// prompts show over this screen, as over the host list.
final class SSHTerminalRexSessionsViewController: UIViewController {
    /// The connection and the Rex stream, shared with the Terminal tab's Rex
    /// section: this screen owns what is drawn and the connect chrome.
    private let follower: SSHTerminalRexFollower
    private var profile: SSHTerminalProfile {
        get { follower.profile }
        set { follower.profile = newValue }
    }
    var profileID: UUID { profile.id }
    private var session: SSHTerminalConnectSession { follower.session }
    private var monitor: RexMonitor { follower.monitor }
    private lazy var content = SSHTerminalRexSessionsContent(monitor: monitor, session: session)
    private var chrome: SSHTerminalConnectChrome?
    private var isOnScreen = false
    /// Edit Host from a pane or the shell: that host's form opens once the
    /// terminal has closed over this screen.
    private var editAfterTerminal: UUID?

    init(profile: SSHTerminalProfile, suppliedPassword: String? = nil) {
        follower = SSHTerminalRexFollower(profile: profile, suppliedPassword: suppliedPassword, promptsAutomatically: true)
        super.init(nibName: nil, bundle: nil)
        title = follower.profile.endpointLabel
        navigationItem.largeTitleDisplayMode = .inline
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        let shell = UIBarButtonItem(
            title: "Shell",
            image: UIImage(systemName: "apple.terminal"),
            primaryAction: UIAction { [weak self] _ in self?.openShell() }
        )
        shell.accessibilityIdentifier = "sshTerminal.rex.shell"
        shell.accessibilityLabel = "Login Shell"
        navigationItem.rightBarButtonItem = shell

        let list = SSHTerminalOverviewViewController(
            content: content,
            isSheet: false,
            refresh: { [weak self] in await self?.follower.refresh() },
            activate: { [weak self] focus in self?.monitor.open(focus) ?? false }
        )
        addChild(list)
        list.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(list.view)
        NSLayoutConstraint.activate([
            list.view.topAnchor.constraint(equalTo: view.topAnchor),
            list.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            list.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            list.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        list.didMove(toParent: self)

        chrome = SSHTerminalConnectChrome(
            host: self,
            session: session,
            profile: { [weak self] in self?.profile ?? SSHTerminalProfile() },
            setProfile: { [weak self] in self?.profile = $0 },
            editHost: { [weak self] in self?.editConnectedHost() },
            submitPassword: { [weak self] in self?.follower.submitPassword($0) },
            onSaved: { [weak self] in self?.profile = $0 }
        )
        setNeedsUpdateProperties()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isOnScreen = true
        // Back from Edit Host: a deleted host, or one no longer on Rex, has
        // no sessions here; one signed in differently needs a new connection.
        if !isMovingToParent, editAfterTerminal == nil {
            // The Rex experiment off leaves this screen nothing to read: it closes on
            // the host's plain terminal, which Back returns to.
            guard let stored = SSHTerminalProfileStore().profile(id: profile.id), stored.listsRexSessions() else {
                Router.finish(self)
                return
            }
            follower.update(profile: stored)
            title = stored.endpointLabel
        }
        follower.appeared()
        setNeedsUpdateProperties()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isOnScreen = false
        follower.stopReading()
        chrome?.hostDidDisappear()
        if isMovingFromParent { follower.close() }
    }

    override func updateProperties() {
        super.updateProperties()
        _ = session.hostFailure
        _ = session.showsTerminal
        _ = session.forgetConfirmation
        _ = session.channel
        let isBackground = AppScenePhase.shared.isBackground
        if !session.showsTerminal, let id = editAfterTerminal {
            editAfterTerminal = nil
            Router.push(SSHTerminalSetupViewController(profileID: id), from: self)
        }
        // The chrome first: the edge of a terminal closing over this screen
        // cancels the attempt in flight, which must not be the list's own.
        chrome?.sync()
        let covered = session.showsTerminal || editAfterTerminal != nil || presentedViewController != nil
        follower.sync(active: isOnScreen && !isBackground && !covered)
    }

    /// The host's own terminal: the login shell, the one open if it still is.
    private func openShell() {
        SSHTerminalFolderEntry.prepare(session: session, profile: profile, target: nil)
        session.connect(profile: profile)
    }

    private func editConnectedHost() {
        if let id = session.connectedProfile?.id { editAfterTerminal = id }
        session.showsTerminal = false
    }
}

/// The sessions screen's rows: how its own connection is doing, then what
/// Rex reports. A pane being opened reads as Opening until its terminal shows.
@MainActor
final class SSHTerminalRexSessionsContent: SSHTerminalOverviewContent {
    private let monitor: RexMonitor
    private let session: SSHTerminalConnectSession

    init(monitor: RexMonitor, session: SSHTerminalConnectSession) {
        self.monitor = monitor
        self.session = session
    }

    var title: String { monitor.title }
    var identifierPrefix: String { monitor.identifierPrefix }
    var focusFailure: String? { monitor.focusFailure }
    var watching: Bool {
        get { monitor.watching }
        set { monitor.watching = newValue }
    }

    var sections: [SSHTerminalOverviewSection] {
        var rows: [SSHTerminalOverviewRow] = []
        if session.connecting {
            let text = session.listsRexSessions ? "Connecting\u{2026}" : "Opening\u{2026}"
            rows.append(.init(id: "connecting", title: text, kind: .placeholder, focus: nil))
        }
        if let failure = session.failure {
            rows.append(.init(id: "connect-failure", title: failure, kind: .failure, focus: nil))
        }
        let connection = rows.isEmpty ? [] : [SSHTerminalOverviewSection(id: "connection", rows: rows)]
        // Rex's rows once it has been read; before the first sign-in (or after
        // one that failed) there is nothing of Rex's to show.
        guard session.rexSessions != nil || monitor.snapshot != nil || monitor.absence != nil else {
            guard connection.isEmpty else { return connection }
            let idle = SSHTerminalOverviewRow(id: "idle", title: "Not connected. Pull down to connect.", kind: .placeholder, focus: nil)
            return [.init(id: "idle", rows: [idle])]
        }
        // Which way Rex was reached, under its sessions.
        var footer: [SSHTerminalOverviewSection] = []
        if monitor.snapshot != nil, monitor.failure == nil, let route = monitor.route {
            footer = [.init(id: "route", rows: [.init(id: "route", title: route.label, kind: .placeholder, focus: nil)])]
        }
        return connection + monitor.sections + footer
    }
}
