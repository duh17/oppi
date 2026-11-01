import Foundation

/// Which of a saved host's Rex sessions are expanded on the Terminal page, kept on
/// this device.
///
/// A session's panes are a disclosure; the page remembers what was open, so coming
/// back to the tab does not fold a session someone was reading. Device-local and per
/// saved host, like the rest of the terminal's own memory (`SSHTerminalRexHostStore`),
/// and it holds only Rex's session ids.
struct SSHTerminalRexExpandedStore {
    static let prefix = "\(AppIdentifiers.subsystem).ssh.terminal.rex.expanded"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func key(_ id: UUID) -> String { "\(prefix).\(id.uuidString)" }

    /// The sessions this host had open. An id whose session Rex no longer lists
    /// costs nothing: the row it would expand is not there.
    func expanded(for profileID: UUID) -> Set<String> {
        Set(defaults.stringArray(forKey: Self.key(profileID)) ?? [])
    }

    /// Keeps only sessions `live` still lists: a session Rex closed leaves nothing to
    /// expand, and its id would sit in the store forever.
    func prune(to live: Set<String>, for profileID: UUID) {
        let kept = expanded(for: profileID).intersection(live)
        if kept != expanded(for: profileID) { setExpanded(kept, for: profileID) }
    }

    func forget(_ profileID: UUID) {
        defaults.removeObject(forKey: Self.key(profileID))
    }

    func setExpanded(_ sessions: Set<String>, for profileID: UUID) {
        if sessions.isEmpty {
            defaults.removeObject(forKey: Self.key(profileID))
        } else {
            defaults.set(sessions.sorted(), forKey: Self.key(profileID))
        }
    }
}
