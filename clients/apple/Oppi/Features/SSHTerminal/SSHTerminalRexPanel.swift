import Foundation

/// The one Rex panel of a Rex pane: what the pane switcher's pill opens. It
/// replaces three controls the bar used to draw for a Rex terminal (the
/// program-status symbol and its popover, the Rex Sessions button, and the pane
/// menu as the only way to see the panes) with one list in the multiplexer
/// overview's shape (`SSHTerminalOverviewViewController`):
///
/// 1. **This pane**: the program status records of the pane on screen.
/// 2. **Panes in this session**: each with its status, one tap shows it (the
///    owner a swipe and the menu use), and New Pane (the owner of a swipe past
///    the last pane).
/// 3. **Other sessions**: each with its pane count and the panes that need
///    you, one tap opens it.
///
/// `SSHTerminalRexPanelSettings` says which sections show. Nothing here knows a
/// program or a multiplexer's names: status and needs-you come from the OSC
/// 7501 records Rex passes on.
@MainActor
final class SSHTerminalRexPanelContent: SSHTerminalOverviewContent {
    static let identifierPrefix = "sshTerminal.rexPanel"
    static let newPaneID = "sshTerminal.rexPanel.newPane"
    /// The focus a New Pane row carries.
    static let newPaneFocus = SSHTerminalOverviewFocus(scope: nil, id: "new-pane", isGroup: false)

    let title = "Rex"
    var identifierPrefix: String { Self.identifierPrefix }

    private let monitor: RexMonitor
    private let settings: SSHTerminalRexPanelSettings
    private let sessionState: () -> RexSessionState?
    private let sessionID: String?
    private let statusRows: () -> [SSHTerminalStatusRow]

    init(
        monitor: RexMonitor,
        settings: SSHTerminalRexPanelSettings,
        sessionID: String?,
        sessionState: @escaping () -> RexSessionState?,
        statusRows: @escaping () -> [SSHTerminalStatusRow]
    ) {
        self.monitor = monitor
        self.settings = settings
        self.sessionID = sessionID
        self.sessionState = sessionState
        self.statusRows = statusRows
    }

    var focusFailure: String? { monitor.focusFailure }

    var watching: Bool {
        get { monitor.watching }
        set { monitor.watching = newValue }
    }

    var sections: [SSHTerminalOverviewSection] {
        Self.sections(
            settings: settings, sessionID: sessionID, state: sessionState(),
            snapshot: monitor.snapshot, statusRows: statusRows()
        )
    }

    /// The rows for these inputs. Pure, so what the panel shows is checked
    /// without a terminal.
    static func sections(
        settings: SSHTerminalRexPanelSettings,
        sessionID: String?,
        state: RexSessionState?,
        snapshot: RexSnapshot?,
        statusRows: [SSHTerminalStatusRow]
    ) -> [SSHTerminalOverviewSection] {
        var sections: [SSHTerminalOverviewSection] = []
        func heading(_ id: String, _ title: String, symbol: String) -> SSHTerminalOverviewRow {
            .init(id: "\(id).heading", title: title, kind: .section(symbol: symbol), focus: nil, accessibilityID: "\(identifierPrefix).\(id)")
        }

        if settings.showsThisPane {
            var rows = [heading("thisPane", String(localized: "This pane"), symbol: "terminal")]
            if statusRows.isEmpty {
                rows.append(.init(
                    id: "thisPane.none", title: String(localized: "No program status reported."), kind: .placeholder, focus: nil
                ))
            }
            for row in statusRows {
                rows.append(.init(
                    id: "thisPane|\(row.id)", title: row.title,
                    kind: .item(subtitle: row.message.isEmpty ? nil : row.message, focused: false, status: .known(row.status)),
                    focus: nil
                ))
            }
            sections.append(.init(id: "thisPane", rows: rows))
        }

        if settings.showsPanes, let state {
            var rows = [heading("panes", String(localized: "Panes in this session"), symbol: "rectangle.split.2x1")]
            let current = sessionID.flatMap { id in snapshot?.sessions.first { $0.sessionID == id } }
            for pane in state.panes {
                // Rex's own report for the pane first (it is live), else the host snapshot.
                let status = pane.status
                    ?? current?.windows.lazy.flatMap(\.panes).first { $0.blockID == pane.blockID }?.status
                rows.append(.init(
                    id: "pane|\(pane.blockID)", title: pane.name,
                    kind: .item(
                        subtitle: state.namesWindows ? pane.windowName : nil,
                        focused: pane.blockID == state.shown,
                        status: status.map { .known($0) } ?? .none
                    ),
                    focus: .init(scope: sessionID, id: pane.blockID, isGroup: false),
                    accessibilityID: "\(identifierPrefix).pane.\(pane.blockID)"
                ))
            }
            rows.append(.init(
                id: "newPane", title: String(localized: "New Pane"), kind: .action(symbol: "plus"),
                focus: newPaneFocus, accessibilityID: newPaneID
            ))
            sections.append(.init(id: "panes", rows: rows))
        }

        if settings.showsOtherSessions {
            var rows = [heading("otherSessions", String(localized: "Other sessions"), symbol: "square.stack")]
            if let snapshot {
                let others = snapshot.sessions.filter { $0.sessionID != sessionID }
                if others.isEmpty {
                    rows.append(.init(
                        id: "otherSessions.none", title: String(localized: "No other sessions."), kind: .placeholder, focus: nil
                    ))
                }
                for session in others {
                    rows.append(sessionRow(session))
                }
            } else {
                rows.append(.init(id: "otherSessions.loading", title: String(localized: "Loading\u{2026}"), kind: .placeholder, focus: nil))
            }
            sections.append(.init(id: "otherSessions", rows: rows))
        }
        return sections
    }

    /// A session as one row: its name, how many panes it has and how many of
    /// them need you, and its headline status. A tap opens the pane Rex types
    /// into there (the focused pane of its active window), else its first.
    private static func sessionRow(_ session: RexSnapshot.Session) -> SSHTerminalOverviewRow {
        let panes = session.windows.flatMap(\.panes)
        let waiting = panes.filter { $0.status?.isBlocked == true }.count
        let count = panes.count == 1 ? String(localized: "1 pane") : String(localized: "\(panes.count) panes")
        let needs = waiting == 1 ? String(localized: "1 needs you") : String(localized: "\(waiting) need you")
        let subtitle = waiting > 0 ? count + " \u{00B7} " + needs : count
        let active = session.windows.first { $0.windowID == session.activeWindowID } ?? session.windows.first
        let target = active?.focusedBlockID.flatMap { id in panes.first { $0.blockID == id } } ?? panes.first
        return .init(
            id: "session|\(session.sessionID)", title: session.label ?? String(localized: "Session"),
            kind: .item(
                subtitle: subtitle, focused: false,
                status: SessionStatusRollup(root: nil, others: panes.compactMap(\.status)).headline.map { .known($0) } ?? .none
            ),
            focus: target.map { .init(scope: session.sessionID, id: $0.blockID, isGroup: false) },
            accessibilityID: "\(identifierPrefix).session.\(session.sessionID)"
        )
    }
}

extension SSHTerminalRexPanelContent {
    /// The status rows of a pane from the records Rex reports for it, root
    /// first, for when the terminal's own stream has carried none.
    static func statusRows(from records: [SSHTerminalPaneRecord]) -> [SSHTerminalStatusRow] {
        records.sorted { $0.id.isEmpty && !$1.id.isEmpty }.compactMap { record in
            guard let status = SSHTerminalPaneRecord.status(state: record.state, kind: record.kind) else { return nil }
            let app = SSHTerminalDisplayText.sanitized(record.app ?? "", limit: SSHTerminalDisplayText.titleLimit)
            return SSHTerminalStatusRow(
                id: record.id.isEmpty ? "root" : record.id,
                status: status,
                title: app.isEmpty ? String(localized: "Program") : app,
                message: SSHTerminalDisplayText.sanitized(record.message ?? "", limit: SSHTerminalDisplayText.titleLimit),
                depth: record.id.isEmpty ? 0 : record.id.split(separator: "/").count
            )
        }
    }

    /// Panes that need you besides the shown one: the session's other panes
    /// from Rex's own reports, and every pane of the host's other sessions
    /// from the snapshot.
    static func needsYou(state: RexSessionState?, snapshot: RexSnapshot?, sessionID: String?) -> Int {
        let own = state?.panes.filter { $0.blockID != state?.shown && $0.status?.isBlocked == true }.count ?? 0
        let others = snapshot?.sessions.filter { $0.sessionID != sessionID }.reduce(0) { total, session in
            total + session.windows.reduce(0) { $0 + $1.panes.filter { $0.status?.isBlocked == true }.count }
        } ?? 0
        return own + others
    }
}
