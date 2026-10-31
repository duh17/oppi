import Foundation

/// Which saved hosts Oppi has seen Rex on: a connected terminal's `RexMonitor`
/// read Rex there, or a Rex pane terminal opened on it. The Terminal tab leads
/// with a live Rex section for such a host as well as for one saved with
/// Multiplexer: Rex, and never dials a host that is in neither group.
///
/// Kept apart from the saved host (like `SSHTerminalColorStore`), so a finding
/// neither ends an open terminal nor asks for a new sign-in, and removed with
/// the host (`SSHTerminalProfileStore.delete`). A mark names the account it was
/// seen for: Rex's socket is in that account's home, so a host edited to another
/// address, port, or user is not a host Rex was seen on. It holds the endpoint
/// and nothing secret.
struct SSHTerminalRexHostStore {
    static let prefix = "\(AppIdentifiers.subsystem).ssh.terminal.rex.seen"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func key(_ id: UUID) -> String { "\(prefix).\(id.uuidString)" }

    private static func account(_ profile: SSHTerminalProfile) -> String {
        let value = profile.normalized()
        return "\(value.username)@\(SSHKnownHosts.entryKey(host: value.host, port: value.port))"
    }

    /// Rex was seen on this host, as this account.
    func hasSeenRex(on profile: SSHTerminalProfile) -> Bool {
        defaults.string(forKey: Self.key(profile.id)) == Self.account(profile)
    }

    func markSeen(_ profile: SSHTerminalProfile) {
        let account = Self.account(profile)
        if defaults.string(forKey: Self.key(profile.id)) != account {
            defaults.set(account, forKey: Self.key(profile.id))
        }
    }

    func forget(_ id: UUID) {
        defaults.removeObject(forKey: Self.key(id))
    }
}
