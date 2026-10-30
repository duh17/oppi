import UIKit

/// A Rex host's own screen (Multiplexer: Rex): every Rex session on the host
/// with its panes and their programs' status, read over a connection of its
/// own that runs no shell. A tapped pane opens on this device in a terminal of
/// its own; Shell opens the host's login shell. Sign-in, trust, and password
/// prompts show over this screen, as over the host list.
final class SSHTerminalRexSessionsViewController: UIViewController {
    private var profile: SSHTerminalProfile
    var profileID: UUID { profile.id }
    /// A password typed for this visit (not saved): signs in the list.
    private let suppliedPassword: String?
    private let session = SSHTerminalConnectSession()
    private let monitor = RexMonitor()
    private lazy var content = SSHTerminalRexSessionsContent(monitor: monitor, session: session)
    private var chrome: SSHTerminalConnectChrome?
    private var reader: Task<Void, Never>?
    private var isOnScreen = false
    /// The list should sign in once this screen shows with nothing over it:
    /// set on appearing, on coming back to the foreground, and when its
    /// connection drops; cleared as the attempt starts, so a failed one is not
    /// retried until one of those happens again (or a pull to refresh).
    private var needsListConnection = true
    /// Edit Host from a pane or the shell: that host's form opens once the
    /// terminal has closed over this screen.
    private var editAfterTerminal: UUID?
    private var observers: [NSObjectProtocol] = []

    init(profile: SSHTerminalProfile, suppliedPassword: String? = nil) {
        self.profile = profile.normalized()
        self.suppliedPassword = suppliedPassword
        super.init(nibName: nil, bundle: nil)
        title = self.profile.endpointLabel
        navigationItem.largeTitleDisplayMode = .inline
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Removed from its stack in any way, even while a terminal covered it
    /// (a stack replaced under it): nothing of the list's stays open.
    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        reader?.cancel()
        session.cancel()
        session.closeRexSessions()
    }

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

        monitor.openPane = { [weak self] pane in self?.session.openRexPane(pane) }
        let list = SSHTerminalOverviewViewController(
            content: content,
            isSheet: false,
            refresh: { [weak self] in await self?.refresh() },
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
            submitPassword: { [weak self] in self?.submitPassword($0) },
            onSaved: { [weak self] in self?.profile = $0 }
        )
        // Even while a terminal covers this screen, whose updates then stop.
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.enterBackground() }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.needsListConnection = true
                    self?.setNeedsUpdateProperties()
                }
            },
        ]
        setNeedsUpdateProperties()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isOnScreen = true
        // Back from Edit Host: a deleted host, or one no longer on Rex, has
        // no sessions here; one signed in differently needs a new connection.
        if !isMovingToParent, editAfterTerminal == nil {
            guard let stored = SSHTerminalProfileStore().profile(id: profile.id), stored.opensRexSessions else {
                Router.finish(self)
                return
            }
            if !stored.sameCredentials(as: profile) { session.closeRexSessions() }
            profile = stored
            title = stored.endpointLabel
        }
        if session.rexSessions == nil { needsListConnection = true }
        setNeedsUpdateProperties()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isOnScreen = false
        stopReading()
        chrome?.hostDidDisappear()
        if isMovingFromParent { session.closeRexSessions() }
    }

    override func updateProperties() {
        super.updateProperties()
        _ = session.connecting
        _ = session.failure
        _ = session.hostFailure
        _ = session.passwordPrompt
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
        guard isOnScreen, !isBackground, !covered else { return }
        if session.rexSessions != nil {
            startReading()
        } else if needsListConnection, !session.connecting, !session.passwordPrompt {
            connectList()
        }
    }

    /// Signs in the list's own connection, unless one is open or on its way.
    private func connectList(password: String? = nil) {
        guard session.rexSessions == nil, !session.connecting, !AppScenePhase.shared.isBackground else { return }
        needsListConnection = false
        SSHTerminalFolderEntry.prepare(session: session, profile: profile, target: nil)
        session.listsRexSessions = true
        session.connect(profile: profile, suppliedPassword: password ?? suppliedPassword)
    }

    /// A password typed in the sheet goes to the connect that asked for it:
    /// the list's, or a pane's or the shell's.
    private func submitPassword(_ password: String) {
        if session.listsRexSessions {
            connectList(password: password)
        } else {
            session.submitPrompt(password: password)
        }
    }

    /// The host's own terminal: the login shell, the one open if it still is.
    private func openShell() {
        SSHTerminalFolderEntry.prepare(session: session, profile: profile, target: nil)
        session.connect(profile: profile)
    }

    /// A pull to refresh: signs the list in again if its connection is gone,
    /// tries again on a host that had no `nc` or no Rex, and otherwise reads
    /// Rex once more over the stream that is open.
    private func refresh() async {
        guard let connection = session.rexSessions, connection.channel.isActive else {
            session.closeRexSessions()
            return connectList()
        }
        monitor.retry()
        startReading()
        await monitor.resync()
    }

    /// Follows Rex while this screen shows and its connection is up: one
    /// stream, whose events update the list as Rex changes. A connection that
    /// drops signs in again; a host without `nc` or without Rex is tried
    /// again only by a pull to refresh.
    private func startReading() {
        guard reader == nil, !monitor.gaveUp, let connection = session.rexSessions else { return }
        reader = Task { [weak self, monitor] in
            await monitor.run(over: connection)
            guard !Task.isCancelled, let self else { return }
            self.reader = nil
            guard !connection.channel.isActive, self.session.rexSessions?.channel === connection.channel else { return }
            self.session.closeRexSessions()
            self.needsListConnection = true
            self.setNeedsUpdateProperties()
        }
    }

    private func stopReading() {
        reader?.cancel()
        reader = nil
    }

    /// The list's connection does not outlive the foreground; it signs in
    /// again when Oppi comes back with this screen showing.
    private func enterBackground() {
        stopReading()
        session.closeRexSessions()
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
        return connection + monitor.sections
    }
}
