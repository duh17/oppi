import Foundation

/// What Oppi knows about Rex on each saved host: whether it was seen there (a
/// terminal's `RexMonitor` read it, or a Rex pane terminal opened on it), and whether
/// a read found none. The Terminal tab lists every saved host in Rex mode and
/// remembers the second answer, so a host with no Rex on it is not dialled again
/// until a pull to refresh asks.
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
        defaults.removeObject(forKey: Self.noRexKey(profile.id))
    }

    func forget(_ id: UUID) {
        defaults.removeObject(forKey: Self.key(id))
        defaults.removeObject(forKey: Self.noRexKey(id))
    }

    // MARK: - Where Rex is not

    /// The host's last read found no Rex on it (`rex` is not installed). The tab
    /// lists every saved host, so a host in this set keeps its heading and one muted
    /// line without being dialled again: only a pull to refresh asks once more.
    func hasNoRex(on profile: SSHTerminalProfile) -> Bool {
        defaults.string(forKey: Self.noRexKey(profile.id)) == Self.account(profile)
    }

    func markNoRex(_ profile: SSHTerminalProfile) {
        defaults.set(Self.account(profile), forKey: Self.noRexKey(profile.id))
        defaults.removeObject(forKey: Self.key(profile.id))
    }

    /// The person asked again: every host may be dialled once more.
    func forgetNoRex() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.noRexPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    private static let noRexPrefix = "\(prefix).none"
    private static func noRexKey(_ id: UUID) -> String { "\(noRexPrefix).\(id.uuidString)" }
}
