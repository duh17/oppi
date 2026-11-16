import Foundation
import Network
import Synchronization

/// Loopback SOCKS5 proxy of the embedded Tailscale node (TailscaleKit
/// `TailscaleNode.loopback()`). tsnet dials tailnet peers from it and resolves
/// MagicDNS names itself, so iOS needs no VPN.
struct TailnetSOCKSProxy: Equatable, Sendable {
    let host: String
    let port: UInt16
    /// Password for the fixed `tsnet` SOCKS user.
    let credential: String

    static let username = "tsnet"
}

/// Routes Oppi HTTPS/WSS to `*.ts.net` through the embedded node while it is
/// running. Transports read the route when they build a URLSession, so
/// `TailnetNodeController` asks the connection coordinator to rebuild paired
/// tailnet connections whenever the route appears, moves, or goes away.
enum TailnetTransportRoute {
    /// Tailnet MagicDNS suffixes; `ServerTLSTrustPolicy.isTailscaleHostname`
    /// accepts the same public-CA names.
    static let matchDomains = ["ts.net", "beta.tailscale.net"]

    /// A connection shares this immutable route across HTTP and all streams.
    /// Read proxy + generation atomically; neither can change mid-composition.
    struct Snapshot: Sendable, Equatable {
        let proxy: TailnetSOCKSProxy?
        let generation: UInt64

        static var current: Self { TailnetTransportRoute.snapshot }
        static let direct = Self(proxy: nil, generation: 0)

        static func forHost(_ host: String?) -> Self {
            guard let host, ServerTLSTrustPolicy.isTailscaleHostname(host) else { return .direct }
            return .current
        }
    }

    private static let published = Mutex<Snapshot>(.direct)

    static var snapshot: Snapshot { published.withLock { $0 } }

    static var proxy: TailnetSOCKSProxy? {
        published.withLock { $0.proxy }
    }

    static var generation: UInt64 {
        published.withLock { $0.generation }
    }

    static func publish(_ proxy: TailnetSOCKSProxy?, generation: UInt64 = 0) {
        published.withLock { $0 = Snapshot(proxy: proxy, generation: proxy == nil ? 0 : generation) }
    }

    /// Routes `configuration` through the currently published node proxy, if any.
    static func apply(to configuration: URLSessionConfiguration) {
        apply(to: configuration, proxy: proxy)
    }

    /// Adds the node's SOCKS5 proxy for tailnet names only; LAN IPs and public
    /// hosts stay direct. Failover keeps a system Tailscale VPN usable if the
    /// embedded node's loopback listener is gone.
    static func apply(to configuration: URLSessionConfiguration, proxy: TailnetSOCKSProxy?) {
        guard let socks = socksConfiguration(proxy) else { return }
        configuration.proxyConfigurations = [socks]
    }

    /// Routes `configuration` through `proxy` for every destination, not just
    /// `matchDomains`, with no failover (`socksConfiguration`): for a Rex probe
    /// of the node's own peers, whose names may be a Headscale tailnet's.
    static func applyToEveryHost(_ configuration: URLSessionConfiguration, proxy: TailnetSOCKSProxy?) {
        guard let socks = socksConfiguration(proxy, everyHost: true) else { return }
        configuration.proxyConfigurations = [socks]
    }

    /// The same route for a Network framework connection (Rex's WebSockets
    /// over Tailscale, which frame themselves): every destination goes through
    /// the node while it runs, as for `applyToEveryHost`. Without the node the
    /// connection uses the device's own network, a Tailscale VPN's included.
    static func applyToEveryHost(_ parameters: NWParameters, proxy: TailnetSOCKSProxy?) {
        guard let socks = socksConfiguration(proxy, everyHost: true) else { return }
        let context = NWParameters.PrivacyContext(description: "Tailnet")
        context.proxyConfigurations = [socks]
        parameters.setPrivacyContext(context)
    }

    /// `everyHost` (Rex, which may speak plain HTTP that only WireGuard
    /// encrypts) never fails over to the device's own network: should the
    /// node's proxy go away mid-connection, the connection fails instead of
    /// reaching whatever answers that address on Wi-Fi or cellular (carriers
    /// use 100.64.0.0/10 too).
    static func socksConfiguration(_ proxy: TailnetSOCKSProxy?, everyHost: Bool = false) -> ProxyConfiguration? {
        guard let proxy, let port = NWEndpoint.Port(rawValue: proxy.port) else { return nil }
        var socks = ProxyConfiguration(
            socksv5Proxy: .hostPort(host: NWEndpoint.Host(proxy.host), port: port)
        )
        socks.applyCredential(username: TailnetSOCKSProxy.username, password: proxy.credential)
        if !everyHost { socks.matchDomains = matchDomains }
        socks.allowFailover = !everyHost
        return socks
    }

    /// `URLSessionConfiguration.default` routed for Oppi server transports.
    ///
    /// Oppi server traffic never touches an HTTP cache. A disk `URLCache` would
    /// store response bodies and the `Authorization: Bearer` request header in
    /// `Library/Caches/<bundle>/Cache.db`. Every API call already passes
    /// `.reloadIgnoringLocalCacheData`, and the app keeps its own ETag state, so
    /// nothing reads these rows back.
    static func defaultSessionConfiguration(route: Snapshot = .current) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        apply(to: configuration, proxy: route.proxy)
        return configuration
    }
}
