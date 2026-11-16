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
    /// A pane an `oppi://terminal` link asked for, opened once Rex has been read.
    /// Dropped when Rex answers (the pane opens, or is said to be gone) or cannot be reached.
    private var linkedPane: TerminalDeepLink?

    init(profile: SSHTerminalProfile, suppliedPassword: String? = nil, opening linkedPane: TerminalDeepLink? = nil) {
        self.linkedPane = linkedPane
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
            activate: { [weak self] focus in
                guard let self else { return false }
                if focus == SSHTerminalRexSessionsContent.startRexFocus {
                    monitor.startRex()
                    return true
                }
                return monitor.open(focus)
            }
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
        openLinkedPaneIfRead()
        let covered = session.showsTerminal || editAfterTerminal != nil || presentedViewController != nil
        // The pass itself may start the sign-in (or raise its password prompt), which the
        // chrome above has already looked past: look again, or the prompt never shows.
        let signInBefore = (session.connecting, session.passwordPrompt, session.hostFailure == nil)
        follower.sync(active: isOnScreen && !isBackground && !covered)
        if signInBefore != (session.connecting, session.passwordPrompt, session.hostFailure == nil) {
            setNeedsUpdateProperties()
        }
    }

    /// A link for this host arrived while this list is on top: open the pane here,
    /// over the connection the list already has.
    func openLinkedPane(_ link: TerminalDeepLink) {
        linkedPane = link
        setNeedsUpdateProperties()
    }

    /// Rex has been read (or cannot be): open the linked pane, or say plainly why not.
    /// The list stays under the message, showing what Rex does have.
    private func openLinkedPaneIfRead() {
        guard let link = linkedPane else { return }
        let message: String
        if monitor.snapshot != nil {
            linkedPane = nil
            guard !monitor.open(session: link.sessionID, block: link.blockID) else { return }
            message = String(localized: "That pane isn\u{2019}t open in Rex on \(profile.endpointLabel). The panes that are running are listed here.")
        } else if let absence = monitor.absence {
            linkedPane = nil
            message = absence.advice
        } else if session.failure != nil || monitor.failure != nil, !session.connecting {
            // The sign-in or the read failed; its own row says why.
            linkedPane = nil
            message = monitor.failure ?? String(localized: "Oppi could not reach Rex on this host.")
        } else {
            return
        }
        Task { @MainActor [weak self] in
            self?.errorAlerts.show(title: String(localized: "Cannot Open Pane"), message: message)
        }
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

    let title = "Rex"
    let identifierPrefix = "sshTerminal.rex"
    /// The Start Rex row under "not running": the one way this screen starts Rex.
    static let startRexFocus = SSHTerminalOverviewFocus(scope: nil, id: "start-rex", isGroup: false)
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
        return connection + Self.rexSections(monitor) + footer
    }

    /// What Rex reports: one section per session, the session, then its panes
    /// in window order, each with its program's status. The pane Rex types
    /// into is bold. A session with several windows names each pane's window.
    /// A pane row opens that pane on this device; a session row offers nothing.
    static func rexSections(_ monitor: RexMonitor) -> [SSHTerminalOverviewSection] {
        var sections: [SSHTerminalOverviewSection] = []
        // Why Rex cannot be read, with what to do about it; any other failure
        // shows as it came.
        if let reason = monitor.absence?.advice ?? monitor.failure {
            var rows = [SSHTerminalOverviewRow(id: "failure", title: reason, kind: .failure, focus: nil)]
            // Reading never starts Rex; the person asks for it here.
            if monitor.absence == .notRunning {
                rows.append(.init(
                    id: "startRex", title: String(localized: "Start Rex"), kind: .action(symbol: "play.fill"),
                    focus: startRexFocus, accessibilityID: "sshTerminal.rex.startRex"
                ))
            }
            sections.append(.init(id: "failure", rows: rows))
            if monitor.gaveUp { return sections }
        }
        guard let snapshot = monitor.snapshot else {
            if monitor.failure == nil {
                sections.append(.init(id: "loading", rows: [.init(id: "loading", title: "Loading\u{2026}", kind: .placeholder, focus: nil)]))
            }
            return sections
        }
        if snapshot.sessions.isEmpty {
            sections.append(.init(id: "empty", rows: [.init(id: "empty", title: "No Rex sessions.", kind: .placeholder, focus: nil)]))
        }
        for session in snapshot.sessions {
            let key = "session|\(session.sessionID)"
            let namesWindows = session.windows.count > 1
            var rows: [SSHTerminalOverviewRow] = [.init(
                id: key, title: session.label ?? "Session", kind: .group(focused: false), focus: nil
            )]
            for window in session.windows {
                for pane in window.panes {
                    let name = pane.displayName
                    let title = pane.title.flatMap { $0.isEmpty || $0 == name ? nil : $0 }
                    rows.append(.init(
                        id: key + "|" + pane.blockID,
                        title: name,
                        kind: .item(
                            subtitle: [title, namesWindows ? window.label : nil].compactMap { $0 }.joined(separator: " \u{00B7} "),
                            focused: session.isFocused(pane, in: window),
                            status: pane.status.map { .known($0) } ?? .none
                        ),
                        focus: .init(scope: session.sessionID, id: pane.blockID, isGroup: false)
                    ))
                }
            }
            sections.append(.init(id: key, rows: rows))
        }
        return sections
    }
}
