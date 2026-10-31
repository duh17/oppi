import UIKit

/// One Rex session on the Terminal tab: its name, how many panes it has, how
/// many of them wait on you, and the status that leads them (the same rollup a
/// thread uses, so a blocked pane wins over a working one). A tap opens it.
struct SSHTerminalRexListSession: Hashable, Sendable {
    let sessionID: String
    let title: String
    let paneCount: Int
    let needsYou: Int
    let status: SSHTerminalOverviewRow.Status

    init(_ session: RexSnapshot.Session) {
        let panes = session.windows.flatMap(\.panes)
        sessionID = session.sessionID
        title = session.label.flatMap { $0.isEmpty ? nil : $0 } ?? "Session"
        paneCount = panes.count
        let statuses = panes.compactMap(\.status)
        needsYou = statuses.filter(\.isBlocked).count
        status = SessionStatusRollup(root: nil, others: statuses).headline.map { .known($0) } ?? .none
    }

    /// "3 panes", "1 pane", with "· 2 need you" after it while panes wait.
    var summary: String {
        let panes = paneCount == 1 ? "1 pane" : "\(paneCount) panes"
        guard needsYou > 0 else { return panes }
        return panes + " \u{00B7} " + SSHTerminalRexListRow.needsYouText(needsYou)
    }

    /// What the row says to VoiceOver: the session, its panes, and who waits.
    var accessibilityLabel: String {
        [title, summary].joined(separator: ", ")
    }
}

/// One row of the Rex section: a host's heading, a session, or why there is no
/// session to show (still loading, Rex cannot be read, the host needs a tap).
struct SSHTerminalRexListRow: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// The host's name, with how many panes wait on you across its sessions.
        case header(name: String, needsYou: Int)
        case session(SSHTerminalRexListSession)
        case placeholder(String)
        case failure(String)
        /// The host would ask for a password, a trust decision, or Face ID: the
        /// tab never does that on its own, so the row is the person's go-ahead.
        case tapToConnect

        /// A session and the connect row take a tap; the rest only read.
        var isAction: Bool {
            switch self {
            case .session, .tapToConnect: true
            case .header, .placeholder, .failure: false
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
        rows += connection + reasons
        if state.absence?.givesUp == true { return rows }
        guard let snapshot = state.snapshot else {
            if connection.isEmpty, reasons.isEmpty { rows.append(.init(id: "loading", kind: .placeholder("Loading\u{2026}"))) }
            return rows
        }
        if snapshot.sessions.isEmpty {
            rows.append(.init(id: "empty", kind: .placeholder("No Rex sessions.")))
        }
        rows += snapshot.sessions.map { .init(id: "session|" + $0.sessionID, kind: .session(.init($0))) }
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
            connectFailure: session.failure,
            needsTap: needsTap,
            snapshot: monitor.snapshot,
            absence: monitor.absence,
            failure: monitor.failure,
            needsYou: monitor.needsAttention
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
