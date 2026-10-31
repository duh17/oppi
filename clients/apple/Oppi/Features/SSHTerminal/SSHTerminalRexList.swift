import UIKit

/// One Rex session on the Terminal tab: its name, where it is working (the
/// focused pane's folder), how many windows and panes it has, how many of them
/// wait on you, and the status that leads them (the same rollup a thread uses,
/// so a blocked pane wins over a working one). A tap opens it; its disclosure
/// lists its panes.
struct SSHTerminalRexListSession: Hashable, Sendable {
    let sessionID: String
    let title: String
    let windowCount: Int
    let paneCount: Int
    let needsYou: Int
    /// The last component of the focused pane's folder.
    let folder: String?
    let status: SSHTerminalOverviewRow.Status
    /// The pane rows are showing under it.
    let isExpanded: Bool

    /// Rex can be asked to rename or close it (the row offers those).
    let manages: Bool

    init(_ session: RexSnapshot.Session, expanded: Bool = false, manages: Bool = false) {
        self.manages = manages
        let panes = session.windows.flatMap(\.panes)
        sessionID = session.sessionID
        title = session.label.flatMap { $0.isEmpty ? nil : $0 } ?? "Session"
        windowCount = session.windows.count
        paneCount = panes.count
        let statuses = panes.compactMap(\.status)
        needsYou = statuses.filter(\.isBlocked).count
        status = SessionStatusRollup(root: nil, others: statuses).headline.map { .known($0) } ?? .none
        folder = session.openingPane?.folderName
        isExpanded = expanded && !panes.isEmpty
    }

    /// There are panes to show under it.
    var hasPanes: Bool { paneCount > 0 }

    /// "3 panes", "1 pane", "2 windows · 3 panes" with more than one window,
    /// and "· 2 need you" after it while panes wait.
    var summary: String {
        var parts: [String] = []
        if windowCount > 1 { parts.append("\(windowCount) windows") }
        parts.append(paneCount == 1 ? "1 pane" : "\(paneCount) panes")
        if needsYou > 0 { parts.append(SSHTerminalRexListRow.needsYouText(needsYou)) }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// The line under the name: the folder it works in, then the counts.
    var detail: String {
        [folder, summary].compactMap { $0 }.joined(separator: " \u{00B7} ")
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
    /// The terminal's title when it says more than the name, then the folder.
    let detail: String?
    let icon: SSHTerminalPaneIcon
    let status: SSHTerminalOverviewRow.Status
    let needsYou: Bool
    /// The pane Rex types into.
    let isFocused: Bool
    /// The window it is in, for a session that groups its panes by window.
    let windowName: String?

    init(_ pane: RexSnapshot.Pane, session: RexSnapshot.Session, window: RexSnapshot.Window, windowName: String? = nil) {
        self.windowName = windowName
        sessionID = session.sessionID
        blockID = pane.blockID
        name = pane.displayName
        let title = pane.title.flatMap { $0.isEmpty || $0 == pane.displayName ? nil : $0 }
        detail = [title, pane.folderName].compactMap { $0 }.joined(separator: " \u{00B7} ").nilIfEmpty
        icon = SSHTerminalPaneIcon(program: pane.program)
        status = pane.status.map { .known($0) } ?? .none
        needsYou = pane.status?.isBlocked == true
        isFocused = session.isFocused(pane, in: window)
    }

    var accessibilityLabel: String {
        [name, windowName.map { "in window \($0)" }, detail, needsYou ? "needs you" : nil].compactMap { $0 }.joined(separator: ", ")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
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

        /// A session, a pane, and the connect and new rows take a tap; the rest only read.
        var isAction: Bool {
            switch self {
            case .session, .pane, .tapToConnect, .newSession: true
            case .header, .window, .placeholder, .failure: false
            }
        }
    }

    /// Unique within a host: the diffable snapshot's identity, with the host's.
    let id: String
    let kind: Kind

    static func needsYouText(_ count: Int) -> String {
        count == 1 ? "1 needs you" : "\(count) need you"
    }
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
    /// The sessions showing their panes.
    var expanded: Set<String> = []
    /// Rex can be changed from here: sessions can be made, renamed, and closed.
    var canManage = false
    /// A change is in flight, and why the last one failed.
    var managing = false
    var manageFailure: String?
}

extension SSHTerminalRexListRow {
    /// The host's heading, then its rows: the connection first (connecting,
    /// failed, or waiting for a tap), why Rex cannot be read, and then the
    /// sessions. A host Rex has not answered for yet shows Loading.
    static func rows(hostName: String, state: SSHTerminalRexListState) -> [Self] {
        var rows: [Self] = [.init(id: "header", kind: .header(name: hostName, needsYou: state.needsYou))]
        var connection: [Self] = []
        if state.connecting {
            connection.append(.init(id: "connecting", kind: .placeholder(state.opening ? "Opening\u{2026}" : "Connecting\u{2026}")))
        }
        if let failure = state.connectFailure {
            connection.append(.init(id: "failure", kind: .failure(failure)))
        }
        if state.needsTap { connection.append(.init(id: "tap", kind: .tapToConnect)) }
        // Why Rex cannot be read, with what to do about it; any other failure
        // shows as it came.
        var reasons: [Self] = []
        if let reason = state.absence?.advice ?? state.failure {
            reasons.append(.init(id: "reason", kind: .failure(reason)))
        }
        if let failure = state.manageFailure {
            reasons.append(.init(id: "action", kind: .failure(failure)))
        }
        rows += connection + reasons
        if state.absence?.givesUp == true { return rows }
        guard let snapshot = state.snapshot else {
            if connection.isEmpty, reasons.isEmpty { rows.append(.init(id: "loading", kind: .placeholder("Loading\u{2026}"))) }
            return rows
        }
        if snapshot.sessions.isEmpty {
            rows.append(.init(id: "empty", kind: .placeholder("No Rex sessions.")))
        }
        for session in snapshot.sessions {
            let expanded = state.expanded.contains(session.sessionID)
            rows.append(.init(id: "session|" + session.sessionID, kind: .session(.init(session, expanded: expanded, manages: state.canManage))))
            guard expanded else { continue }
            // A session with several windows groups its panes under each window's name.
            let namesWindows = session.windows.count > 1
            for (index, window) in session.windows.enumerated() {
                let windowName = window.label.flatMap { $0.isEmpty ? nil : $0 } ?? "Window \(index + 1)"
                if namesWindows {
                    rows.append(.init(id: "window|\(session.sessionID)|\(window.windowID)", kind: .window(id: window.windowID, name: windowName)))
                }
                for pane in window.panes {
                    rows.append(.init(
                        id: "pane|\(session.sessionID)|\(pane.blockID)",
                        kind: .pane(.init(pane, session: session, window: window, windowName: namesWindows ? windowName : nil))
                    ))
                }
            }
        }
        if state.canManage || state.managing { rows.append(.init(id: "new", kind: .newSession(busy: state.managing))) }
        return rows
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
            expanded: expandedSessions,
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

    /// Resets what a reused cell carried, then sets the row's.
    func configureAction(identifier: String, label: String, value: String?, hint: String?, perform: @escaping () -> Void) {
        self.perform = perform
        isAccessibilityElement = true
        accessibilityIdentifier = identifier
        accessibilityLabel = label
        accessibilityValue = value
        accessibilityHint = hint
        accessibilityTraits = .button
    }

    override func accessibilityActivate() -> Bool {
        guard let perform else { return false }
        perform()
        return true
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        perform = nil
        accessories = []
        accessibilityIdentifier = nil
        accessibilityLabel = nil
        accessibilityValue = nil
        accessibilityHint = nil
        accessibilityTraits = []
    }
}

/// A session row: two buttons, as the host row is (its own text drawn in a
/// button, not in a list content configuration, which would make the cell one
/// element): the row (identifier, label, value; a touch and VoiceOver's
/// activation both open the session) and its disclosure, which shows or hides
/// the panes. A test finds `app.buttons[id]` and `app.buttons[id + ".disclosure"]`.
/// The row's custom actions carry what a swipe has, and the disclosure, so
/// VoiceOver reaches all of it.
final class SSHTerminalRexListSessionCell: SSHTerminalOverviewCell {
    private let rowButton = UIButton(type: .system)
    private let disclosure = UIButton(type: .system)
    private var performAction: UIAction?
    private var toggleAction: UIAction?

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

    /// The row's two buttons, in reading order: for a test, and VoiceOver.
    var rowElement: UIView { rowButton }
    var disclosureElement: UIView { disclosure }

    /// Resets what a reused cell carried, then sets the row's. `actions` are
    /// the row's custom actions (rename, close); the disclosure's is added here.
    func configureSession(
        _ session: SSHTerminalRexListSession, identifier: String, themeID: ThemeID,
        actions: [UIAccessibilityCustomAction], perform: @escaping () -> Void, toggle: @escaping () -> Void
    ) {
        let palette = themeID.palette
        var conf = UIButton.Configuration.plain()
        conf.title = session.title
        conf.subtitle = session.detail
        conf.titleAlignment = .leading
        conf.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var out = $0
            out.font = .preferredFont(forTextStyle: .body)
            out.foregroundColor = palette.ui.fg
            return out
        }
        conf.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var out = $0
            out.font = .preferredFont(forTextStyle: .footnote)
            out.foregroundColor = palette.ui.comment
            return out
        }
        conf.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0)
        rowButton.configuration = conf
        rowButton.accessibilityIdentifier = identifier
        rowButton.accessibilityLabel = session.accessibilityLabel
        rowButton.accessibilityValue = session.status.label
        rowButton.accessibilityHint = "Open this Rex session"
        if let performAction { rowButton.removeAction(performAction, for: .touchUpInside) }
        let open = UIAction { _ in perform() }
        performAction = open
        rowButton.addAction(open, for: .touchUpInside)

        var accessories = statusAccessories(for: session.status, themeID: themeID)
        var custom = actions
        if let toggleAction { disclosure.removeAction(toggleAction, for: .touchUpInside) }
        toggleAction = nil
        if session.hasPanes {
            var chevron = UIButton.Configuration.plain()
            chevron.image = UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(textStyle: .footnote, scale: .small))
            chevron.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 8)
            chevron.baseForegroundColor = palette.ui.comment
            disclosure.configuration = chevron
            disclosure.transform = session.isExpanded ? CGAffineTransform(rotationAngle: .pi / 2) : .identity
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
            accessibilityElements = [rowButton, disclosure]
        } else {
            accessibilityElements = [rowButton]
        }
        rowButton.accessibilityCustomActions = custom
        self.accessories = accessories
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        if let performAction { rowButton.removeAction(performAction, for: .touchUpInside) }
        if let toggleAction { disclosure.removeAction(toggleAction, for: .touchUpInside) }
        performAction = nil
        toggleAction = nil
        rowButton.accessibilityIdentifier = nil
        rowButton.accessibilityCustomActions = nil
        disclosure.accessibilityIdentifier = nil
        disclosure.transform = .identity
        accessories = []
        accessibilityElements = nil
    }
}
