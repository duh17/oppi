import UIKit

/// One Rex session on the Rex screen, drawn as the small heading over its
/// panes' card: its name, where it is working (the focused pane's folder), how
/// many windows and panes it has, how many of them wait on you, and the status
/// that leads them (the same rollup a thread uses, so a blocked pane wins over
/// a working one). A tap opens it; its chevron folds its panes away.
struct SSHTerminalRexListSession: Hashable, Sendable {
    let sessionID: String
    let title: String
    let windowCount: Int
    let paneCount: Int
    let needsYou: Int
    /// The last component of the focused pane's folder.
    let folder: String?
    let status: SSHTerminalOverviewRow.Status
    /// The pane rows are showing under it: every session's do until it is folded.
    let isExpanded: Bool

    /// Rex can be asked to rename or close it (the row offers those).
    let manages: Bool

    init(_ session: RexSnapshot.Session, collapsed: Bool = false, manages: Bool = false) {
        self.manages = manages
        let panes = session.windows.flatMap(\.panes)
        sessionID = session.sessionID
        title = session.displayName
        windowCount = session.windows.count
        paneCount = panes.count
        let statuses = panes.compactMap(\.status)
        needsYou = session.needsYou
        status = SessionStatusRollup(root: nil, others: statuses).headline.map { .known($0) } ?? .none
        folder = session.openingPane?.folderName
        isExpanded = !collapsed
    }

    /// "3 panes", "1 pane", "2 windows · 3 panes" with more than one window,
    /// and "· 2 need you" after it while panes wait.
    var summary: String {
        let panes = RexSnapshot.paneSummary(panes: paneCount, needsYou: needsYou)
        return windowCount > 1 ? "\(windowCount) windows \u{00B7} " + panes : panes
    }

    /// What the row says to VoiceOver: the session, its folder, its panes, and who waits.
    var accessibilityLabel: String {
        [title, folder.map { "in \($0)" }, summary].compactMap { $0 }.joined(separator: ", ")
    }
}

/// One pane under an expanded session: what the bar's pane switcher would
/// call it, the icon it would draw for it (`SSHTerminalPaneIcon`, by the same
/// rule), the folder it is in, and its status. A tap opens the session on it.
struct SSHTerminalRexListPane: Hashable, Sendable {
    let sessionID: String
    let blockID: String
    let name: String
    /// The folder the pane works in, with the home folder as `~`.
    let folder: String?
    /// The terminal's title when it says more than the name.
    let detail: String?
    let icon: SSHTerminalPaneIcon
    let status: SSHTerminalOverviewRow.Status
    let needsYou: Bool
    /// The pane Rex types into.
    let isFocused: Bool
    /// The window it is in, for a session that groups its panes by window.
    let windowName: String?
    /// How long ago the pane's program last moved, from its newest record's own time;
    /// nil for a pane that reports nothing, which draws no time at all.
    let activity: String?

    init(_ pane: RexSnapshot.Pane, session: RexSnapshot.Session, window: RexSnapshot.Window, windowName: String? = nil, now: Date = Date()) {
        self.windowName = windowName
        sessionID = session.sessionID
        blockID = pane.blockID
        name = pane.displayName
        folder = pane.folderPath
        detail = pane.title.flatMap { $0.isEmpty || $0 == pane.displayName ? nil : $0 }
        icon = SSHTerminalPaneIcon(program: pane.program)
        status = pane.status.map { .known($0) } ?? .none
        needsYou = pane.status?.isBlocked == true
        isFocused = session.isFocused(pane, in: window)
        activity = pane.lastActivity.map { $0.relativeString(relativeTo: now) }
    }

    var accessibilityLabel: String {
        [name, windowName.map { "in window \($0)" }, detail, folder, activity, needsYou ? "needs you" : nil]
            .compactMap { $0 }.joined(separator: ", ")
    }
}

extension RexSnapshot.Pane {
    /// The last component of the folder the terminal reported (`file://host/path`,
    /// or a plain path as Rex keeps one an older program reported).
    var folderName: String? {
        guard let pwd,
              let path = SSHTerminalWorkingDirectory.path(from: pwd) ?? SSHTerminalWorkingDirectory.normalize(pwd)
        else { return nil }
        return path == "/" ? "/" : (path as NSString).lastPathComponent
    }

    /// The whole folder, with a home folder (`/Users/<name>` or
    /// `/home/<name>`) written as `~`, as a shell prompt writes it.
    var folderPath: String? {
        guard let pwd,
              let path = SSHTerminalWorkingDirectory.path(from: pwd) ?? SSHTerminalWorkingDirectory.normalize(pwd)
        else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0].isEmpty, parts[1] == "Users" || parts[1] == "home", !parts[2].isEmpty else { return path }
        return (["~"] + parts.dropFirst(3)).joined(separator: "/")
    }

    /// What the pane's icon starts from (`RexSessionState.program`): the
    /// bar's pane switcher draws the same icon for the same pane.
    var program: String? {
        RexSessionState.program(title: title, records: records, label: label)
    }
}

/// One row of the Rex section: a host's heading, a session, or why there is no
/// session to show (still loading, Rex cannot be read, the host needs a tap).
struct SSHTerminalRexListRow: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// The host's name, with how many panes wait on you across its sessions.
        case header(name: String, needsYou: Int)
        case session(SSHTerminalRexListSession)
        /// A window's name over its panes, for a session with more than one window.
        case window(id: String, name: String)
        case pane(SSHTerminalRexListPane)
        case placeholder(String)
        case failure(String)
        /// The host would ask for a password, a trust decision, or Face ID: the
        /// tab never does that on its own, so the row is the person's go-ahead.
        case tapToConnect
        /// Makes a session with a shell and opens it; `busy` while a change to Rex runs.
        case newSession(busy: Bool)
        /// Rex could not be read here: the row that asks again, the same owner as a
        /// pull to refresh.
        case retry(String)
        /// Rex is installed and not running: the person's go-ahead to start it
        /// on this host. Reading the list never starts it.
        case startRex

        /// A session, a pane, and the connect and new rows take a tap; the rest only read.
        var isAction: Bool {
            switch self {
            case .session, .pane, .tapToConnect, .newSession, .retry, .startRex: true
            case .header, .window, .placeholder, .failure: false
            }
        }
    }

    /// Unique within a host: the diffable snapshot's identity, with the host's.
    let id: String
    let kind: Kind
}

/// What the tab knows of one Rex host: how its own connection is doing and what
/// Rex last reported. A plain value, so what the section draws for it can be
/// checked without a screen.
struct SSHTerminalRexListState: Equatable {
    /// The list's own sign-in is under way (`opening`: a pane's, instead).
    var connecting = false
    var opening = false
    var connectFailure: String?
    var needsTap = false
    var snapshot: RexSnapshot?
    var absence: RexAbsence?
    /// A stream failure from the monitor, under which the last snapshot stays.
    var failure: String?
    var needsYou = 0
    /// The sessions folded away, their panes hidden.
    var collapsed: Set<String> = []
    /// Rex can be changed from here: sessions can be made, renamed, and closed.
    var canManage = false
    /// A change is in flight, and why the last one failed.
    var managing = false
    var manageFailure: String?
}

/// A run of a Rex's rows drawn together: its heading, the card of what it
/// says about its connection, and for each session a small heading over a card
/// of its panes. The Rex screen makes one list section of each.
struct SSHTerminalRexListGroup: Hashable, Sendable {
    enum Style: Hashable, Sendable {
        /// Rows on the page's background: the Rex's heading, a session's heading.
        case heading
        /// Rows in a card.
        case card
    }

    let id: String
    let style: Style
    let rows: [SSHTerminalRexListRow]
}

extension SSHTerminalRexListRow {
    /// Every row, in order: what `groups` lays out.
    static func rows(hostName: String, state: SSHTerminalRexListState) -> [Self] {
        groups(hostName: hostName, state: state).flatMap(\.rows)
    }

    /// The Rex's heading; then a card with the connection (connecting, failed,
    /// or waiting for a tap), why Rex cannot be read, and anything Rex refused;
    /// then each session's heading over the card of its panes, unless the
    /// session is folded. A Rex not answered yet shows Loading.
    static func groups(hostName: String, state: SSHTerminalRexListState) -> [SSHTerminalRexListGroup] {
        var groups = [SSHTerminalRexListGroup(
            id: "heading", style: .heading,
            rows: [.init(id: "header", kind: .header(name: hostName, needsYou: state.needsYou))]
        )]
        var status: [Self] = []
        if state.connecting {
            status.append(.init(id: "connecting", kind: .placeholder(state.opening ? "Opening\u{2026}" : "Connecting\u{2026}")))
        }
        if let failure = state.connectFailure {
            status.append(.init(id: "failure", kind: .failure(failure)))
        }
        if state.needsTap { status.append(.init(id: "tap", kind: .tapToConnect)) }
        let connection = status
        // Why Rex cannot be read, with what to do about it; any other failure
        // shows as it came. A host with no Rex on it is not a failure: the screen
        // lists every saved host, so it keeps one muted line and nothing to open.
        var reasons: [Self] = []
        if state.absence == .notInstalled {
            reasons.append(.init(id: "reason", kind: .placeholder(String(localized: "No Rex on this host."))))
            // Asking again is how it comes back: the same owner as a pull to refresh.
            reasons.append(.init(id: "retry", kind: .retry(String(localized: "Retry"))))
        } else if let reason = state.absence?.advice ?? state.failure {
            reasons.append(.init(id: "reason", kind: .failure(reason)))
            if !state.connecting {
                // A Rex that is not running starts only when the person asks here;
                // anything else asks again, the same owner as a pull to refresh.
                reasons.append(state.absence == .notRunning
                    ? .init(id: "start", kind: .startRex)
                    : .init(id: "retry", kind: .retry(String(localized: "Retry"))))
            }
        }
        if let failure = state.manageFailure {
            reasons.append(.init(id: "action", kind: .failure(failure)))
        }
        status += reasons
        func finish() -> [SSHTerminalRexListGroup] {
            status.isEmpty ? groups : [groups[0], .init(id: "status", style: .card, rows: status)] + groups.dropFirst()
        }
        if state.absence?.givesUp == true { return finish() }
        guard let snapshot = state.snapshot else {
            if connection.isEmpty, reasons.isEmpty { status.append(.init(id: "loading", kind: .placeholder("Loading\u{2026}"))) }
            return finish()
        }
        // No sessions is the one place a Rex offers to make one: everywhere else
        // New Session is the heading's ⋯ and the page's ＋. A change in flight is a
        // progress line beside the sessions it is changing.
        if snapshot.sessions.isEmpty {
            if state.canManage || state.managing {
                status.append(.init(id: "new", kind: .newSession(busy: state.managing)))
            } else {
                status.append(.init(id: "empty", kind: .placeholder("No Rex sessions.")))
            }
        } else if state.managing {
            status.append(.init(id: "new", kind: .newSession(busy: true)))
        }
        for session in snapshot.sessions {
            let row = SSHTerminalRexListSession(session, collapsed: state.collapsed.contains(session.sessionID), manages: state.canManage)
            groups.append(.init(id: "session|" + session.sessionID, style: .heading, rows: [.init(id: "session|" + session.sessionID, kind: .session(row))]))
            guard row.isExpanded else { continue }
            var panes: [Self] = []
            // A session with several windows names each window over its panes.
            let namesWindows = session.windows.count > 1
            for (index, window) in session.windows.enumerated() {
                let windowName = window.label.flatMap { $0.isEmpty ? nil : $0 } ?? "Window \(index + 1)"
                if namesWindows {
                    panes.append(.init(id: "window|\(session.sessionID)|\(window.windowID)", kind: .window(id: window.windowID, name: windowName)))
                }
                for pane in window.panes {
                    panes.append(.init(
                        id: "pane|\(session.sessionID)|\(pane.blockID)",
                        kind: .pane(.init(pane, session: session, window: window, windowName: namesWindows ? windowName : nil))
                    ))
                }
            }
            if panes.isEmpty {
                panes.append(.init(id: "nopanes|" + session.sessionID, kind: .placeholder(String(localized: "No panes"))))
            }
            groups.append(.init(id: "panes|" + session.sessionID, style: .card, rows: panes))
        }
        return finish()
    }
}

extension SSHTerminalRexFollower {
    /// What the tab's section draws for this host, read from the connection's
    /// state and the monitor's snapshot (both observable).
    var listState: SSHTerminalRexListState {
        SSHTerminalRexListState(
            connecting: session.connecting,
            opening: session.connecting && !session.listsRexSessions,
            connectFailure: session.failure ?? promptNote,
            needsTap: needsTap,
            snapshot: monitor.snapshot,
            absence: monitor.absence,
            failure: monitor.failure,
            needsYou: monitor.needsAttention,
            collapsed: collapsedSessions,
            canManage: monitor.canManage,
            managing: managing,
            manageFailure: manageFailure
        )
    }
}

/// A row of the Rex section that opens something: a session, or the host's
/// connect. The row is one accessibility element with the identifier, label,
/// value, and button trait (as the overview's rows are: a list cell draws its
/// content in its own views, so a button laid over it is not reachable), and
/// VoiceOver's activation runs the same action as a tap on the row, which the
/// screen routes through its selection.
final class SSHTerminalRexListActionCell: SSHTerminalOverviewCell {
    private var perform: (() -> Void)?
    /// Read when VoiceOver asks, so the pane items follow the window's width.
    private var customActions: (() -> [UIAccessibilityCustomAction])?

    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get {
            guard let actions = customActions?(), !actions.isEmpty else { return super.accessibilityCustomActions }
            return actions
        }
        set { super.accessibilityCustomActions = newValue }
    }

    /// Resets what a reused cell carried, then sets the row's.
    func configureAction(
        identifier: String,
        label: String,
        value: String?,
        hint: String?,
        actions: (() -> [UIAccessibilityCustomAction])? = nil,
        perform: @escaping () -> Void
    ) {
        self.perform = perform
        customActions = actions
        isAccessibilityElement = true
        accessibilityIdentifier = identifier
        accessibilityLabel = label
        accessibilityValue = value
        accessibilityHint = hint
        accessibilityTraits = .button
        super.accessibilityCustomActions = nil
    }

    override func accessibilityActivate() -> Bool {
        guard let perform else { return false }
        perform()
        return true
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        perform = nil
        customActions = nil
        accessories = []
        accessibilityIdentifier = nil
        accessibilityLabel = nil
        accessibilityValue = nil
        accessibilityHint = nil
        accessibilityTraits = []
        super.accessibilityCustomActions = nil
    }
}

/// A session's heading over its panes' card: the session's name on the
/// page's background, its status, its ⊕, and the chevron that folds the card.
/// Its parts are buttons, as the host row's are (its own text drawn in a
/// button, not in a list content configuration, which would make the cell one
/// element): the name (identifier, label, value; a touch and VoiceOver's
/// activation both open the session) and its disclosure, which shows or hides
/// the panes. A test finds `app.buttons[id]` and `app.buttons[id + ".disclosure"]`.
/// The row's custom actions carry what a swipe has, and the disclosure, so
/// VoiceOver reaches all of it.
final class SSHTerminalRexListSessionCell: SSHTerminalOverviewCell {
    private let rowButton = UIButton(type: .system)
    private let disclosure = UIButton(type: .system)
    private let newPaneButton = UIButton(type: .system)
    private var performAction: UIAction?
    private var toggleAction: UIAction?
    private var newPaneAction: UIAction?

    override init(frame: CGRect) {
        super.init(frame: frame)
        rowButton.translatesAutoresizingMaskIntoConstraints = false
        rowButton.contentHorizontalAlignment = .leading
        contentView.addSubview(rowButton)
        NSLayoutConstraint.activate([
            rowButton.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            rowButton.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            rowButton.topAnchor.constraint(equalTo: contentView.topAnchor),
            rowButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            rowButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        disclosure.accessibilityLabel = "Panes"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The row's buttons, in reading order: for a test, and VoiceOver.
    var rowElement: UIView { rowButton }
    var disclosureElement: UIView { disclosure }
    /// The session's ⊕ New Pane, when the list offers one.
    var newPaneElement: UIView { newPaneButton }

    /// Resets what a reused cell carried, then sets the row's. `actions` are
    /// the row's custom actions (rename, close); the disclosure's is added here.
    func configureSession(
        _ session: SSHTerminalRexListSession, identifier: String, themeID: ThemeID,
        actions: [UIAccessibilityCustomAction], perform: @escaping () -> Void, toggle: @escaping () -> Void,
        newPane: (() -> Void)? = nil
    ) {
        let palette = themeID.palette
        var conf = UIButton.Configuration.plain()
        conf.title = session.title
        conf.titleAlignment = .leading
        conf.titleLineBreakMode = .byTruncatingTail
        conf.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var out = $0
            out.font = UIFont.scaled(.subheadline, .semibold)
            out.foregroundColor = palette.ui.comment
            return out
        }
        conf.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 2, trailing: 0)
        rowButton.configuration = conf
        rowButton.accessibilityIdentifier = identifier
        rowButton.accessibilityLabel = session.accessibilityLabel
        rowButton.accessibilityValue = session.status.label
        rowButton.accessibilityHint = "Open this Rex session"
        if let performAction { rowButton.removeAction(performAction, for: .touchUpInside) }
        let open = UIAction { _ in perform() }
        performAction = open
        rowButton.addAction(open, for: .touchUpInside)

        // The heading's name lines up with its card's rows, so its status is the
        // label alone, in its colour, with no status mark before the name.
        var accessories: [UICellAccessory] = []
        if case .known(let kind) = session.status, let label = session.status.label {
            accessories.append(.label(text: label, options: .init(
                tintColor: kind.tint(themeID.appTheme), font: .preferredFont(forTextStyle: .caption1)
            )))
        }
        var custom = actions
        // The session's own ⊕: a new pane in it, opened in a terminal of its own.
        if let newPane {
            var plus = UIButton.Configuration.plain()
            plus.image = UIImage(systemName: "plus.circle", withConfiguration: UIImage.SymbolConfiguration(textStyle: .body))
            plus.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 6)
            plus.baseForegroundColor = palette.ui.comment
            newPaneButton.configuration = plus
            newPaneButton.accessibilityIdentifier = identifier + ".newPane"
            newPaneButton.accessibilityLabel = String(localized: "New Pane")
            newPaneButton.accessibilityHint = String(localized: "Adds a pane to this session and opens it")
            if let newPaneAction { newPaneButton.removeAction(newPaneAction, for: .touchUpInside) }
            let add = UIAction { _ in newPane() }
            newPaneAction = add
            newPaneButton.addAction(add, for: .touchUpInside)
            accessories.append(.customView(configuration: .init(customView: newPaneButton, placement: .trailing())))
            custom.append(UIAccessibilityCustomAction(name: String(localized: "New Pane")) { _ in
                newPane()
                return true
            })
        } else {
            // A reused cell must not keep a ⊕ from its last row: no identifier, no
            // action, and out of the accessibility order.
            if let newPaneAction { newPaneButton.removeAction(newPaneAction, for: .touchUpInside) }
            newPaneAction = nil
            newPaneButton.accessibilityIdentifier = nil
        }
        if let toggleAction { disclosure.removeAction(toggleAction, for: .touchUpInside) }
        toggleAction = nil
        var chevron = UIButton.Configuration.plain()
        chevron.image = UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(textStyle: .footnote).applying(UIImage.SymbolConfiguration(weight: .semibold)))
        chevron.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 0)
        chevron.baseForegroundColor = palette.ui.comment
        disclosure.configuration = chevron
        disclosure.transform = session.isExpanded ? .identity : CGAffineTransform(rotationAngle: -.pi / 2)
        disclosure.accessibilityIdentifier = identifier + ".disclosure"
        disclosure.accessibilityValue = session.isExpanded ? "Expanded" : "Collapsed"
        let flip = UIAction { _ in toggle() }
        toggleAction = flip
        disclosure.addAction(flip, for: .touchUpInside)
        accessories.append(.customView(configuration: .init(customView: disclosure, placement: .trailing())))
        custom.append(UIAccessibilityCustomAction(name: session.isExpanded ? "Hide Panes" : "Show Panes") { _ in
            toggle()
            return true
        })
        // On screen the ⊕ sits before the chevron, and VoiceOver follows the screen.
        accessibilityElements = newPane == nil ? [rowButton, disclosure] : [rowButton, newPaneButton, disclosure]
        rowButton.accessibilityCustomActions = custom
        self.accessories = accessories
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        if let performAction { rowButton.removeAction(performAction, for: .touchUpInside) }
        if let toggleAction { disclosure.removeAction(toggleAction, for: .touchUpInside) }
        if let newPaneAction { newPaneButton.removeAction(newPaneAction, for: .touchUpInside) }
        performAction = nil
        toggleAction = nil
        newPaneAction = nil
        newPaneButton.accessibilityIdentifier = nil
        rowButton.accessibilityIdentifier = nil
        rowButton.accessibilityCustomActions = nil
        disclosure.accessibilityIdentifier = nil
        disclosure.transform = .identity
        accessories = []
        accessibilityElements = nil
    }
}
