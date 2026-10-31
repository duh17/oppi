import Foundation

/// The saved SSH host a Rex route belongs to: its id, and the sign-in target
/// the route was learned through.
struct RexDirectHost: Equatable, Sendable {
    let id: UUID
    /// `SSHKnownHosts.entryKey`: lowercased host and port.
    let target: String
    let username: String

    init(profile: SSHTerminalProfile) {
        let value = profile.normalized()
        id = value.id
        target = SSHKnownHosts.entryKey(host: value.host, port: value.port)
        username = value.username
    }
}

/// What a Rex server's `server.status` says about its Tailscale serving.
enum RexDirectDiscovery {
    enum Outcome: Equatable, Sendable {
        /// Rex serves its API at `url` (`https://<name>.ts.net`) to its
        /// owner's tailnet identity. `hostID` is that Rex's own host id, which
        /// tells it apart from another Rex later answering at the same name.
        case available(url: URL, hostID: String?)
        /// Tailscale serving is off, not running, or not HTTPS.
        case unavailable
    }

    /// Nil for an answer that is not a status: what was remembered stays.
    /// Only an `https` URL on a tailnet name (`*.ts.net`) is taken, so the
    /// host cannot point this device anywhere else.
    static func outcome(statusJSON: Data) -> Outcome? {
        struct Status: Decodable {
            struct Tailscale: Decodable {
                struct HTTPS: Decodable {
                    let state: String?
                    let url: String?
                }

                let https: HTTPS?
            }

            let pid: Int?
            let hostID: String?
            let tailscale: Tailscale?
            enum CodingKeys: String, CodingKey { case pid, hostID = "host_id", tailscale }
        }
        guard let status = try? JSONDecoder().decode(Status.self, from: statusJSON),
              status.pid != nil || status.tailscale != nil else { return nil }
        guard let tailscale = status.tailscale, tailscale.https?.state == "available",
              let text = tailscale.https?.url, let url = URL(string: text), url.scheme == "https",
              let host = url.host, ServerTLSTrustPolicy.isTailscaleHostname(host),
              url.user == nil, url.query == nil, url.path.isEmpty || url.path == "/" else {
            return .unavailable
        }
        return .available(url: url, hostID: status.hostID)
    }
}

/// Where each saved SSH host's Rex answers over Tailscale, as its own
/// `server.status` last said over the SSH bridge. Kept per host in app
/// preferences with the sign-in target it was read through, so a host edited
/// to point elsewhere does not reuse it. Nothing secret: the tailnet identity
/// is the credential.
struct RexDirectStore: @unchecked Sendable {
    struct Entry: Codable, Equatable {
        let url: URL
        /// The Rex the URL was learned from (`server.status`'s `host_id`).
        let hostID: String?
        let target: String
        let username: String
    }

    static let prefix = "\(AppIdentifiers.subsystem).ssh.terminal.rexDirect"
    static func key(_ id: UUID) -> String { "\(prefix).\(id.uuidString)" }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func url(for host: RexDirectHost) -> URL? {
        entry(for: host)?.url
    }

    private func entry(for host: RexDirectHost) -> Entry? {
        guard let data = defaults.data(forKey: Self.key(host.id)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.target == host.target, entry.username == host.username else { return nil }
        return entry
    }

    /// Remembers what the host's Rex said over the SSH bridge, which is the
    /// host's own Rex; an unreadable answer (`nil`) changes nothing.
    func apply(_ outcome: RexDirectDiscovery.Outcome?, for host: RexDirectHost) {
        switch outcome {
        case .available(let url, let hostID):
            let entry = Entry(url: url, hostID: hostID, target: host.target, username: host.username)
            guard entry != self.entry(for: host), let data = try? JSONEncoder().encode(entry) else { return }
            defaults.set(data, forKey: Self.key(host.id))
        case .unavailable:
            forget(host.id)
        case nil:
            break
        }
    }

    /// Checks the address against what the Rex reached over Tailscale says
    /// of itself: another Rex there (a different `host_id`), or serving that
    /// moved or stopped, drops the address, so the next open goes over SSH
    /// and learns it again. The connection that read it is the caller's.
    func confirm(_ outcome: RexDirectDiscovery.Outcome?, for host: RexDirectHost) {
        guard let outcome, let entry = entry(for: host) else { return }
        switch outcome {
        case .available(let url, let hostID):
            if url != entry.url || (entry.hostID != nil && hostID != entry.hostID) { forget(host.id) }
        case .unavailable:
            forget(host.id)
        }
    }

    func forget(_ id: UUID) {
        defaults.removeObject(forKey: Self.key(id))
    }
}
