import Foundation

/// Which of a saved host's Rex sessions are folded on the Rex screen, kept on
/// this device.
///
/// A session shows its panes until it is folded; the screen remembers what was
/// folded, so coming back does not open a session someone put away.
/// Device-local and per saved host, like the rest of the terminal's own memory
/// (`SSHTerminalRexHostStore`), and it holds only Rex's session ids.
struct SSHTerminalRexCollapsedStore {
    static let prefix = "\(AppIdentifiers.subsystem).ssh.terminal.rex.collapsed"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func key(_ id: UUID) -> String { "\(prefix).\(id.uuidString)" }

    /// The sessions this host had folded. An id whose session Rex no longer
    /// lists costs nothing: the row it would fold is not there.
    func collapsed(for profileID: UUID) -> Set<String> {
        Set(defaults.stringArray(forKey: Self.key(profileID)) ?? [])
    }

    /// Keeps only sessions `live` still lists: a session Rex closed leaves nothing to
    /// fold, and its id would sit in the store forever.
    func prune(to live: Set<String>, for profileID: UUID) {
        let kept = collapsed(for: profileID).intersection(live)
        if kept != collapsed(for: profileID) { setCollapsed(kept, for: profileID) }
    }

    func forget(_ profileID: UUID) {
        defaults.removeObject(forKey: Self.key(profileID))
    }

    func setCollapsed(_ sessions: Set<String>, for profileID: UUID) {
        if sessions.isEmpty {
            defaults.removeObject(forKey: Self.key(profileID))
        } else {
            defaults.set(sessions.sorted(), forKey: Self.key(profileID))
        }
    }
}
