import CryptoKit
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

    // MARK: - Rex reached over Tailscale alone

    /// The Rex nodes added by Tailscale name, in the order they were added.
    /// Kept beside the per-host URLs: the same kind of record (a Rex and the
    /// `https` URL it serves at), only without an SSH host.
    static let tailnetHostsKey = "\(prefix).tailnetHosts"

    func tailnetHosts() -> [RexTailnetHost] {
        guard let data = defaults.data(forKey: Self.tailnetHostsKey),
              let hosts = try? JSONDecoder().decode([RexTailnetHost].self, from: data) else { return [] }
        return hosts
    }

    /// Adds `host`, or renames the one already saved under its name.
    func saveTailnetHost(_ host: RexTailnetHost) {
        var hosts = tailnetHosts()
        if let index = hosts.firstIndex(where: { $0.dnsName == host.dnsName }) {
            hosts[index] = host
        } else {
            hosts.append(host)
        }
        writeTailnetHosts(hosts)
    }

    func forgetTailnetHost(dnsName: String) {
        writeTailnetHosts(tailnetHosts().filter { $0.dnsName != dnsName })
    }

    /// The Tailscale names the Rex of `profiles` said they serve at, so the
    /// Terminal tab lists such a Rex once, under its SSH host. Names are
    /// MagicDNS names (lowercased, no root dot), not URL strings.
    func tailnetNames(among profiles: [SSHTerminalProfile]) -> Set<String> {
        Set(profiles.compactMap { url(for: RexDirectHost(profile: $0))?.host.flatMap { RexTailnetHost(dnsName: $0)?.dnsName } })
    }

    /// Posted for this store's own defaults when anything in them changes.
    var changes: (name: Notification.Name, object: UserDefaults) {
        (UserDefaults.didChangeNotification, defaults)
    }

    private func writeTailnetHosts(_ hosts: [RexTailnetHost]) {
        guard let data = try? JSONEncoder().encode(hosts) else { return }
        defaults.set(data, forKey: Self.tailnetHostsKey)
    }
}

/// A Rex reached over Tailscale alone, the way Rex's own iPhone app reaches
/// it: no saved SSH host and no sign-in. Rex's built-in Tailscale node serves
/// its API at `https://<name>.<tailnet>.ts.net` and admits a caller by its
/// Tailscale identity (WhoIs): only the account that signed the Rex node in,
/// unless Rex allows its tailnet's members. This device's Tailscale (Oppi's
/// own node or the Tailscale app's VPN) is the credential, so there is nothing
/// secret to keep.
struct RexTailnetHost: Codable, Hashable, Sendable, Identifiable {
    /// Lowercased MagicDNS name without the root dot: `rex.tail1234.ts.net`.
    let dnsName: String
    /// What the Terminal tab calls it: the node's Tailscale device name.
    var name: String
    /// Where Rex serves its API: Tailscale HTTPS on the default port.
    let url: URL

    private enum CodingKeys: String, CodingKey { case dnsName, name }

    /// A Rex is waited on this long for its welcome: there is no other way in
    /// to fall back to, so it gets longer than a direct attempt beside SSH.
    static let connectTimeout: Duration = .seconds(10)

    init?(dnsName: String, name: String? = nil) {
        guard let normalized = Self.normalizedName(dnsName), let url = URL(string: "https://" + normalized) else { return nil }
        self.dnsName = normalized
        self.url = url
        let label = String(normalized.prefix { $0 != "." })
        let given = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.name = given.isEmpty ? label : given
    }

    /// A saved entry is checked again as it is read.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let host = Self(
            dnsName: try values.decode(String.self, forKey: .dnsName),
            name: try values.decodeIfPresent(String.self, forKey: .name)
        ) else {
            throw DecodingError.dataCorruptedError(forKey: .dnsName, in: values, debugDescription: "not a tailnet name")
        }
        self = host
    }

    /// What a person typed for Add Rex by Tailscale Name: a MagicDNS name
    /// (`rex.tail1234.ts.net`), with or without `https://`, a trailing slash,
    /// or the root dot. Anything else is nil: another scheme, a port, a path,
    /// an address, or a name outside `ts.net`.
    static func parse(_ text: String) -> Self? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("https://") { value.removeFirst("https://".count) }
        if value.hasSuffix("/") { value.removeLast() }
        return Self(dnsName: value)
    }

    /// `<device>.<tailnet>.ts.net`, each label a DNS label.
    static func normalizedName(_ text: String) -> String? {
        var name = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard name.hasSuffix(".ts.net"), labels.count >= 4, labels.allSatisfy(isLabel) else { return nil }
        return name
    }

    private static func isLabel(_ label: Substring) -> Bool {
        guard (1...63).contains(label.count), label.first != "-", label.last != "-" else { return false }
        return label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// Stable for the name, so the terminal a session opened in is found again
    /// whether the node was discovered or added.
    var id: UUID {
        var bytes = Array(SHA256.hash(data: Data("rex-tailnet:\(dnsName)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
