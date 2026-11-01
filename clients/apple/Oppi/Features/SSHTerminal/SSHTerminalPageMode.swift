import Foundation

/// What the Terminal page lists: every saved host's Rex panes, or the saved hosts
/// themselves. The mode is the page's, not a host's: a saved host is a plain SSH
/// login, and what a tap opens comes from this.
///
/// Herdr joins the set when its screen lands; until then a device with only
/// Herdr's experiment on has Shell, because Rex's switch is what fills this page.
enum SSHTerminalPageMode: String, Sendable {
    /// Every saved host's Rex sessions and their panes, plus the Rexes reached over
    /// Tailscale by name. A tap opens that pane's terminal.
    case rex
    /// The saved hosts, each opening its own login shell.
    case shell

    /// What the switch and the rows say.
    var label: String {
        switch self {
        case .rex: String(localized: "Rex")
        case .shell: String(localized: "Shell")
        }
    }

    /// The modes this device can show: the ones whose experiment is on, and Shell,
    /// which adds nothing to read.
    static func available(in access: SSHTerminalExperimentAccess) -> [Self] {
        access.rex ? [.rex, .shell] : [.shell]
    }

    /// What the page shows for the stored choice: the choice itself while its
    /// experiment is on, else Rex when that is on, else Shell. A mode that is not
    /// available is never shown, and the stored choice is kept for when it is.
    static func resolved(_ stored: SSHTerminalPageMode?, in access: SSHTerminalExperimentAccess) -> Self {
        if let stored, available(in: access).contains(stored) { return stored }
        return access.rex ? .rex : .shell
    }
}

/// What the page's ＋ does in a given mode: saves a host, or starts a Rex session on
/// one of the saved hosts.
enum SSHTerminalPlusAction: Equatable, Sendable {
    case newHost
    /// New Session, on these hosts (one is used straight away, several are offered).
    case newSession([SSHTerminalProfile])
}
