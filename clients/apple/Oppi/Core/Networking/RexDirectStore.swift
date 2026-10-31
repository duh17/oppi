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
        /// owner's tailnet identity.
        case available(url: URL, dnsName: String?)
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

                let dnsName: String?
                let https: HTTPS?
                enum CodingKeys: String, CodingKey { case dnsName = "dns_name", https }
            }

            let pid: Int?
            let tailscale: Tailscale?
        }
        guard let status = try? JSONDecoder().decode(Status.self, from: statusJSON),
              status.pid != nil || status.tailscale != nil else { return nil }
        guard let tailscale = status.tailscale, tailscale.https?.state == "available",
              let text = tailscale.https?.url, let url = URL(string: text), url.scheme == "https",
              let host = url.host, ServerTLSTrustPolicy.isTailscaleHostname(host),
              url.user == nil, url.query == nil, url.path.isEmpty || url.path == "/" else {
            return .unavailable
        }
        return .available(url: url, dnsName: tailscale.dnsName)
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
        let dnsName: String?
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
        guard let data = defaults.data(forKey: Self.key(host.id)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.target == host.target, entry.username == host.username else { return nil }
        return entry.url
    }

    /// Remembers what Rex said; an unreadable answer (`nil`) changes nothing.
    func apply(_ outcome: RexDirectDiscovery.Outcome?, for host: RexDirectHost) {
        switch outcome {
        case .available(let url, let dnsName):
            let entry = Entry(url: url, dnsName: dnsName, target: host.target, username: host.username)
            guard url != self.url(for: host), let data = try? JSONEncoder().encode(entry) else { return }
            defaults.set(data, forKey: Self.key(host.id))
        case .unavailable:
            forget(host.id)
        case nil:
            break
        }
    }

    func forget(_ id: UUID) {
        defaults.removeObject(forKey: Self.key(id))
    }
}

