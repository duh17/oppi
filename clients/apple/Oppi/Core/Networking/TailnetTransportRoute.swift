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

    private static let published = Mutex<(proxy: TailnetSOCKSProxy?, generation: UInt64)>((nil, 0))

    static var proxy: TailnetSOCKSProxy? {
        published.withLock { $0.proxy }
    }

    static var generation: UInt64 {
        published.withLock { $0.generation }
    }

    static func publish(_ proxy: TailnetSOCKSProxy?, generation: UInt64 = 0) {
        published.withLock { $0 = (proxy, proxy == nil ? 0 : generation) }
    }

    /// Routes `configuration` through the currently published node proxy, if any.
    static func apply(to configuration: URLSessionConfiguration) {
        apply(to: configuration, proxy: proxy)
    }

    /// Adds the node's SOCKS5 proxy for tailnet names only; LAN IPs and public
    /// hosts stay direct. Failover keeps a system Tailscale VPN usable if the
    /// embedded node's loopback listener is gone.
    static func apply(to configuration: URLSessionConfiguration, proxy: TailnetSOCKSProxy?) {
        guard let proxy, let port = NWEndpoint.Port(rawValue: proxy.port) else { return }
        var socks = ProxyConfiguration(
            socksv5Proxy: .hostPort(host: NWEndpoint.Host(proxy.host), port: port)
        )
        socks.applyCredential(username: TailnetSOCKSProxy.username, password: proxy.credential)
        socks.matchDomains = matchDomains
        socks.allowFailover = true
        configuration.proxyConfigurations = [socks]
    }

    /// `URLSessionConfiguration.default` routed for Oppi server transports.
    static func defaultSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        apply(to: configuration)
        return configuration
    }
}
