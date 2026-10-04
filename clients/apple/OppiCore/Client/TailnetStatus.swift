import Foundation

// Platform-neutral projection of an embedded Tailscale node (TailscaleKit /
// libtailscale). The iOS adapter feeds it LocalAPI status JSON and IPN bus
// notifications; nothing here links TailscaleKit.

/// `ipn.State` as named by tailscaled. LocalAPI status reports the name as a
/// string; the IPN bus reports the same states as integers.
enum TailnetBackendState: String, Equatable, Sendable {
    case noState = "NoState"
    case inUseOtherUser = "InUseOtherUser"
    case needsLogin = "NeedsLogin"
    case needsMachineAuth = "NeedsMachineAuth"
    case stopped = "Stopped"
    case starting = "Starting"
    case running = "Running"
}

/// What the Tailscale settings screen and transport routing act on.
enum TailnetNodeState: Equatable, Sendable {
    /// Oppi has not started its node.
    case off
    /// The node is starting and has not reported login or run state yet.
    case starting
    /// The node needs interactive login. The URL arrives from control
    /// (IPN bus `BrowseToURL` or status `AuthURL`) shortly after start.
    case needsLogin(URL?)
    /// Logged in; a tailnet admin must approve this device.
    case needsMachineAuth
    /// Joined the tailnet. The loopback SOCKS proxy is published after this.
    case running
    case failed(String)
}

/// One IPN bus notification, reduced to the fields Oppi uses.
struct TailnetBusEvent: Equatable, Sendable {
    var state: TailnetBackendState?
    var browseToURL: String?
    var loginFinished = false
    var errorMessage: String?
    /// The notification carried a netmap, so the machine list may have changed.
    var netmapChanged = false
}

/// Login/run state reduced from IPN bus events and LocalAPI status.
struct TailnetNodeStatus: Equatable, Sendable {
    private(set) var backendState: TailnetBackendState = .noState
    private(set) var loginURL: URL?
    private(set) var errorMessage: String?

    var isRunning: Bool { backendState == .running }

    var nodeState: TailnetNodeState {
        switch backendState {
        case .running:
            return .running
        case .needsMachineAuth:
            return .needsMachineAuth
        case .needsLogin:
            return .needsLogin(loginURL)
        case .inUseOtherUser:
            return .failed("Tailscale is in use by another user on this device.")
        case .noState, .starting, .stopped:
            if let errorMessage { return .failed(errorMessage) }
            // tsnet can publish BrowseToURL before the NeedsLogin state.
            if let loginURL { return .needsLogin(loginURL) }
            return .starting
        }
    }

    mutating func apply(_ event: TailnetBusEvent) {
        if let message = event.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty {
            errorMessage = message
        }
        if let url = Self.loginURL(event.browseToURL) {
            loginURL = url
        }
        if event.loginFinished {
            loginURL = nil
        }
        if let state = event.state {
            backendState = state
            if state == .running {
                loginURL = nil
                errorMessage = nil
            }
        }
    }

    /// LocalAPI status is a full snapshot of the same backend; it also carries
    /// `AuthURL` if the bus notification was missed.
    mutating func apply(_ snapshot: TailnetStatusSnapshot) {
        backendState = snapshot.backendState
        switch snapshot.backendState {
        case .running:
            loginURL = nil
            errorMessage = nil
        case .needsLogin:
            if let authURL = snapshot.authURL { loginURL = authURL }
        default:
            break
        }
    }

    /// Only an https control URL is ever opened in the browser.
    private static func loginURL(_ value: String?) -> URL? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              url.host(percentEncoded: false)?.isEmpty == false else { return nil }
        return url
    }
}

/// A machine on the tailnet as reported by LocalAPI `/localapi/v0/status`.
struct TailnetPeer: Equatable, Identifiable, Sendable {
    let id: String
    let hostName: String
    /// MagicDNS name without the trailing root dot, e.g. `mac-studio.tail1234.ts.net`.
    let dnsName: String
    let os: String?
    let tailscaleIPs: [String]
    let isOnline: Bool

    /// MagicDNS name when present, else the machine's host name.
    var displayName: String {
        if let label = dnsName.split(separator: ".").first, !label.isEmpty {
            return String(label)
        }
        return hostName
    }

    /// Where an SSH check or health probe dials: MagicDNS name when the netmap
    /// has one, else the first tailnet IP.
    var dialHost: String {
        dnsName.isEmpty ? tailscaleIPs.first ?? hostName : dnsName
    }

    /// Phones and tablets never run an Oppi server. LocalAPI reports iPhones
    /// and iPads as `iOS`. An unknown OS stays listed.
    var canHostOppi: Bool {
        switch os?.lowercased() {
        case "ios", "ipados", "android": false
        default: true
        }
    }

    /// SSH setup row. The label follows the OS Tailscale reported, before the
    /// probe has run. macOS and Linux both get a check; other kernels do too,
    /// and the probe says they are unsupported.
    var setupCheckTitle: String {
        switch os?.lowercased() {
        case "macos": "Check this Mac"
        case "linux": "Check this Linux machine"
        default: "Check this machine"
        }
    }

    /// Prefer a Mac, then a Linux host, then any machine that can run Oppi.
    /// Phones and tablets are not setup targets.
    static func preferredSetupPeer(among peers: [TailnetPeer]) -> TailnetPeer? {
        let hosts = peers.filter(\.canHostOppi)
        return hosts.first { $0.os?.lowercased() == "macos" }
            ?? hosts.first { $0.os?.lowercased() == "linux" }
            ?? hosts.first
    }

    /// MagicDNS names compare case-insensitively and may carry the root dot.
    func hasHost(_ host: String) -> Bool {
        guard !dnsName.isEmpty else { return false }
        return Self.normalizedHost(dnsName) == Self.normalizedHost(host)
    }

    private static func normalizedHost(_ host: String) -> String {
        var name = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while name.hasSuffix(".") { name.removeLast() }
        return name
    }
}

/// What an unauthenticated `GET /health` over the tailnet found on a peer.
enum TailnetPeerProbe: Equatable, Sendable {
    case inFlight
    /// Oppi answered.
    case ready
    /// The TLS handshake for the MagicDNS name was answered with a certificate
    /// this device rejects, so Oppi is not serving a Tailscale certificate.
    case needsCertificate
    /// Refused, timed out, or not Oppi.
    case notReachable
}

/// The one state an Online Machines row shows.
enum TailnetPeerStatus: Equatable, Sendable {
    case paired
    case checking
    case ready
    case needsCertificate
    case notReachable
    /// No probe has run (for example the proxy was not ready).
    case unchecked

    /// A peer whose MagicDNS name is a paired server host is paired and needs
    /// no probe. `probe` is nil until one starts.
    static func derive(peer: TailnetPeer, pairedHosts: [String], probe: TailnetPeerProbe?) -> Self {
        if pairedHosts.contains(where: peer.hasHost) { return .paired }
        switch probe {
        case nil: return .unchecked
        case .inFlight: return .checking
        case .ready: return .ready
        case .needsCertificate: return .needsCertificate
        case .notReachable: return .notReachable
        }
    }
}

struct TailnetStatusSnapshot: Equatable, Sendable {
    let backendState: TailnetBackendState
    let authURL: URL?
    let selfDNSName: String?
    let tailnetName: String?
    /// Every peer in the netmap, sorted by display name.
    let peers: [TailnetPeer]

    var onlinePeers: [TailnetPeer] { peers.filter(\.isOnline) }
}

enum TailnetStatusProjectionError: Error, Equatable {
    case unknownBackendState(String)
}

/// Decodes LocalAPI status JSON (Go `ipnstate.Status`). Only the fields Oppi
/// shows are required, so newer tailscaled fields never break decoding.
enum TailnetStatusProjection {
    static func snapshot(fromStatusJSON data: Data) throws -> TailnetStatusSnapshot {
        let status = try JSONDecoder().decode(Status.self, from: data)
        guard let backendState = TailnetBackendState(rawValue: status.BackendState) else {
            throw TailnetStatusProjectionError.unknownBackendState(status.BackendState)
        }
        let authURL = status.AuthURL.flatMap { value -> URL? in
            guard let url = URL(string: value), url.scheme?.lowercased() == "https" else { return nil }
            return url
        }
        let peers = (status.Peer ?? [:]).map { key, peer in
            TailnetPeer(
                id: nonEmpty(peer.ID) ?? key,
                hostName: peer.HostName ?? "",
                dnsName: trimmedDNSName(peer.DNSName),
                os: nonEmpty(peer.OS),
                tailscaleIPs: peer.TailscaleIPs ?? [],
                isOnline: peer.Online ?? false
            )
        }
        .sorted { lhs, rhs in
            let order = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
        return TailnetStatusSnapshot(
            backendState: backendState,
            authURL: authURL,
            selfDNSName: nonEmpty(trimmedDNSName(status.SelfStatus?.DNSName)),
            tailnetName: nonEmpty(status.CurrentTailnet?.Name),
            peers: peers
        )
    }

    private static func trimmedDNSName(_ value: String?) -> String {
        guard var name = value?.trimmingCharacters(in: .whitespacesAndNewlines) else { return "" }
        while name.hasSuffix(".") { name.removeLast() }
        return name
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    // swiftlint:disable identifier_name
    private struct Status: Decodable {
        let BackendState: String
        let AuthURL: String?
        let SelfStatus: PeerStatus?
        let CurrentTailnet: TailnetStatus?
        let Peer: [String: PeerStatus]?

        enum CodingKeys: String, CodingKey {
            case BackendState, AuthURL, CurrentTailnet, Peer
            case SelfStatus = "Self"
        }
    }

    private struct PeerStatus: Decodable {
        let ID: String?
        let HostName: String?
        let DNSName: String?
        let OS: String?
        let TailscaleIPs: [String]?
        let Online: Bool?
    }

    private struct TailnetStatus: Decodable {
        let Name: String?
    }
    // swiftlint:enable identifier_name
}
