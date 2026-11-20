import CryptoKit
import Darwin
import Foundation
import Network

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
        /// Rex serves its API at `url` (`https://<name>.ts.net`, or
        /// `http://<tailnet address>:<port>`) to its owner's tailnet identity.
        /// `hostID` is that Rex's own host id, which tells it apart from
        /// another Rex later answering at the same address.
        case available(url: URL, hostID: String?)
        /// Rex serves nothing on a tailnet.
        case unavailable
    }

    /// Nil for an answer that is not a status: what was remembered stays.
    /// Rex's own Tailscale node's HTTPS serving wins (any `https` name it
    /// gives, a Headscale tailnet's included, checked against the system's
    /// roots as it is dialed); else a listener on the host's own tailnet
    /// (`--extra-listen tailnet://:PORT`), which Rex identifies by Tailscale
    /// too, at its first tailnet address (`http://100.x.y.z:PORT`). Plain
    /// HTTP is taken only to a tailnet address (`RexTailnetHost`), never a
    /// listener that admits anyone.
    static func outcome(statusJSON: Data) -> Outcome? {
        struct Status: Decodable {
            struct Tailscale: Decodable {
                struct HTTPS: Decodable {
                    let state: String?
                    let url: String?
                }

                let https: HTTPS?
            }

            struct Listener: Decodable {
                let addresses: [String]?
                let transport: String?
            }

            let pid: Int?
            let hostID: String?
            let tailscale: Tailscale?
            let listeners: [Listener]?
            enum CodingKeys: String, CodingKey { case pid, hostID = "host_id", tailscale, listeners }
        }
        guard let status = try? JSONDecoder().decode(Status.self, from: statusJSON),
              status.pid != nil || status.tailscale != nil else { return nil }
        if let https = status.tailscale?.https, https.state == "available",
           let text = https.url, let url = URL(string: text), url.scheme == "https",
           let host = RexTailnetHost(url: url) {
            return .available(url: host.url, hostID: status.hostID)
        }
        let tailnet = (status.listeners ?? []).filter { $0.transport == "tailscale" }.flatMap { $0.addresses ?? [] }
        if let host = tailnet.lazy.compactMap({ RexTailnetHost(address: "http://" + $0) }).first {
            return .available(url: host.url, hostID: status.hostID)
        }
        return .unavailable
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

    /// The Tailscale address this host's Rex said it serves at, as a
    /// `RexTailnetHost.address`, and the `host_id` it gave then.
    func learned(for host: RexDirectHost) -> (address: String, hostID: String?)? {
        guard let entry = entry(for: host), let address = RexTailnetHost(url: entry.url)?.address else { return nil }
        return (address, entry.hostID)
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

    /// Whether the Rex reached over Tailscale is the one this host's address
    /// was learned from: it says it serves at that address, with the same
    /// `host_id`. With no SSH sign-in beside it, this is what stands for the
    /// host's identity, so it is checked before anything is sent to it. Another
    /// Rex there, serving that moved or stopped, or an address learned with no
    /// `host_id` to check, drops the address, so the next open goes over SSH
    /// and learns it again. An answer that is not a status keeps it.
    func verify(_ outcome: RexDirectDiscovery.Outcome?, for host: RexDirectHost) -> Bool {
        guard let outcome, let entry = entry(for: host) else { return false }
        if case .available(let url, let hostID) = outcome, url == entry.url, let expected = entry.hostID, hostID == expected {
            return true
        }
        forget(host.id)
        return false
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
        if let index = hosts.firstIndex(where: { $0.address == host.address }) {
            hosts[index] = host
        } else {
            hosts.append(host)
        }
        writeTailnetHosts(hosts)
    }

    func forgetTailnetHost(address: String) {
        writeTailnetHosts(tailnetHosts().filter { $0.address != address })
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
/// it: no saved SSH host and no sign-in. Rex admits a caller by its Tailscale
/// identity (WhoIs): only the account that signed the Rex in, unless Rex
/// allows its tailnet's members. This device's Tailscale (Oppi's own node or
/// the Tailscale app's VPN) is the credential, so there is nothing secret to
/// keep. Rex serves its API on a tailnet two ways, and either is reached:
/// its built-in Tailscale node's HTTPS (`https://<name>.<tailnet>.ts.net`,
/// or a Headscale tailnet's MagicDNS name), or a listener on the host's own
/// Tailscale (`tailnet://:PORT`), plain HTTP to the host's tailnet address,
/// which WireGuard already encrypts. Plain HTTP goes only to a tailnet
/// address (100.64.0.0/10 or fd7a:115c:a1e0::/48) or a `*.ts.net` MagicDNS
/// name, which only Tailscale resolves; never to another name, which could
/// resolve off the tailnet.
struct RexTailnetHost: Codable, Hashable, Sendable, Identifiable {
    /// What names the Rex, its key in the store: a lowercased MagicDNS name
    /// without the root dot (`rex.tail1234.ts.net`), with `:port` when it is
    /// not 443, or a tailnet address and port (`100.101.102.103:7297`).
    let address: String
    /// What the Terminal tab calls it: the node's Tailscale device name.
    var name: String
    /// Where Rex serves its API: `https` for a name, `http` for an address.
    let url: URL

    // `dnsName` is the stored key from before addresses were taken.
    private enum CodingKeys: String, CodingKey { case address = "dnsName", name }

    /// A Rex is waited on this long for its welcome: there is no other way in
    /// to fall back to, so it gets longer than a direct attempt beside SSH.
    static let connectTimeout: Duration = .seconds(10)

    /// `address` as typed or stored: a name, `https://name[:port]`, or a
    /// tailnet address with its port (`100.101.102.103:7297`, with or without
    /// `http://` or Rex's own `tailnet://`). Nil for anything else
    /// (`parse` has the rules).
    init?(address: String, name: String? = nil) {
        guard let (normalized, url) = Self.normalized(address) else { return nil }
        self.address = normalized
        self.url = url
        let label = url.host.map { ServerTLSTrustPolicy.isIPLiteral($0) ? $0 : String($0.prefix { $0 != "." }) } ?? normalized
        let given = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.name = given.isEmpty ? label : given
    }

    /// The Rex at `url`, as a host's Rex said it serves (`RexDirectDiscovery`)
    /// or a stand-in profile carries it, by the same rules.
    init?(url: URL, name: String? = nil) {
        self.init(address: url.absoluteString, name: name)
    }

    /// A saved entry is checked again as it is read.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let host = Self(
            address: try values.decode(String.self, forKey: .address),
            name: try values.decodeIfPresent(String.self, forKey: .name)
        ) else {
            throw DecodingError.dataCorruptedError(forKey: .address, in: values, debugDescription: "not a tailnet address")
        }
        self = host
    }

    /// What a person typed for Add Rex by Tailscale Name, as `rex server
    /// tailscale pair` or `rex server status` shows it.
    static func parse(_ text: String) -> Self? {
        Self(address: text)
    }

    /// `text` as an address and its URL, or nil. Case, surrounding spaces, a
    /// trailing slash, and the root dot do not matter. A name
    /// (`<device>.<domain>`, each label a DNS label, two or more) is `https`,
    /// on 443 unless a port is given, or with `http://` and a port, plain HTTP
    /// to a `*.ts.net` name. A tailnet address (100.64.0.0/10 or
    /// fd7a:115c:a1e0::/48) needs its port and is `http`. Anything else is
    /// nil: another scheme, a path, a query, a user, an address off the
    /// tailnet, plain HTTP to a name outside `ts.net`, or HTTPS to an address.
    static func normalized(_ text: String) -> (String, URL)? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var scheme: String?
        // One scheme at most: `https://http://…` is not an address.
        if let prefix = ["https://", "http://", "tailnet://"].first(where: { value.hasPrefix($0) }) {
            scheme = prefix == "https://" ? "https" : "http"
            value.removeFirst(prefix.count)
        }
        if value.hasSuffix("/") { value.removeLast() }
        // `%` would be an IPv6 zone (`…%en0`), which binds to a local interface.
        guard !value.isEmpty, !value.contains(where: { "/?#@ %".contains($0) }) else { return nil }
        /// A port as written: ASCII digits only (no sign, no spaces).
        func portNumber(_ text: Substring) -> Int? {
            guard (1...5).contains(text.count), text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(text)
        }
        // `[v6]:port`, `v4:port`, or `name[:port]`.
        var host = value
        var port: Int?
        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]") else { return nil }
            host = String(value[value.index(after: value.startIndex)..<close])
            let rest = value[value.index(after: close)...]
            if !rest.isEmpty {
                guard rest.hasPrefix(":"), let number = portNumber(rest.dropFirst()) else { return nil }
                port = number
            }
        } else if let colon = value.lastIndex(of: ":") {
            guard value.firstIndex(of: ":") == colon, let number = portNumber(value[value.index(after: colon)...]) else { return nil }
            host = String(value[..<colon])
            port = number
        }
        if let port, !(1...65_535).contains(port) { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        if let canonical = tailnetAddress(host) {
            guard scheme != "https", let port else { return nil }
            // Rebuilt from the parsed bytes, so `1681915905` or `100.64.1`
            // reach the address that was checked, as the resolver would not.
            let bracketed = canonical.contains(":") ? "[\(canonical)]" : canonical
            let address = "\(bracketed):\(port)"
            return URL(string: "http://\(address)").map { (address, $0) }
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy(isLabel), labels.last?.allSatisfy(\.isNumber) == false else { return nil }
        if scheme == "http" {
            // Rex's `tailnet://` listener by the machine's MagicDNS name, which
            // only Tailscale resolves: `http://build.<tailnet>.ts.net:7297`.
            guard host.hasSuffix(".ts.net"), let port else { return nil }
            let address = "http://\(host):\(port)"
            return URL(string: address).map { (address, $0) }
        }
        let address = port.map { $0 == 443 ? host : "\(host):\($0)" } ?? host
        return URL(string: "https://\(address)").map { (address, $0) }
    }

    /// A Tailscale address (IPv4 in 100.64.0.0/10, IPv6 in fd7a:115c:a1e0::/48)
    /// written out again from its bytes, or nil for anything else.
    static func tailnetAddress(_ host: String) -> String? {
        if let v4 = IPv4Address(host) {
            let bytes = [UInt8](v4.rawValue)
            guard RexTailnetPath.isTailscaleAddress(bytes.reduce(0) { $0 << 8 | UInt32($1) }) else { return nil }
            return bytes.map(String.init).joined(separator: ".")
        }
        if let v6 = IPv6Address(host) {
            let bytes = [UInt8](v6.rawValue)
            guard bytes.prefix(6).elementsEqual([0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0]) else { return nil }
            var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard bytes.withUnsafeBytes({ inet_ntop(AF_INET6, $0.baseAddress, &text, socklen_t(text.count)) }) != nil else { return nil }
            return String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        return nil
    }

    private static func isLabel(_ label: Substring) -> Bool {
        guard (1...63).contains(label.count), label.first != "-", label.last != "-" else { return false }
        return label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// Stable for the address, so the terminal a session opened in is found
    /// again whether the node was discovered or added.
    var id: UUID {
        var bytes = Array(SHA256.hash(data: Data("rex-tailnet:\(address)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
