import Foundation
import Network
import Synchronization

/// Tags for comparing Oppi's HTTPS/WSS routes. `system-vpn` is inferred:
/// MagicDNS without a published embed SOCKS proxy (official Tailscale VPN or
/// broken resolver). Not a user-facing route picker.
enum NetworkPathTelemetry {
    enum RouteKind: String, Sendable {
        case lan
        case socks
        case systemVpn = "system-vpn"
        case paired
    }

    enum HostKind: String, Sendable {
        case tailscale
        case local
        case ip
        case dns
    }

    private static let interfaceKind = Mutex<String>("unknown")

    static func note(path: NWPath) {
        let kind: String
        if path.usesInterfaceType(.cellular) {
            kind = "cell"
        } else if path.usesInterfaceType(.wifi) {
            kind = "wifi"
        } else if path.usesInterfaceType(.wiredEthernet) {
            kind = "eth"
        } else {
            kind = "other"
        }
        interfaceKind.withLock { $0 = kind }
    }

    static var pathType: String {
        interfaceKind.withLock { $0 }
    }

    static func hostKind(for host: String) -> HostKind {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ServerTLSTrustPolicy.isTailscaleHostname(normalized) { return .tailscale }
        if ServerTLSTrustPolicy.isIPLiteral(normalized) { return .ip }
        if normalized == "localhost" || normalized.hasSuffix(".localhost") || normalized.hasSuffix(".local") {
            return .local
        }
        return .dns
    }

    static func routeKind(
        transportPath: ConnectionTransportPath,
        host: String,
        socksPublished: Bool = TailnetTransportRoute.proxy != nil
    ) -> RouteKind {
        if transportPath == .lan { return .lan }
        if ServerTLSTrustPolicy.isTailscaleHostname(host) {
            return socksPublished ? .socks : .systemVpn
        }
        return .paired
    }

    static func tags(selection: EndpointSelection?) -> [String: String] {
        let host = selection?.baseURL.host ?? ""
        return [
            "route": routeKind(
                transportPath: selection?.transportPath ?? .paired,
                host: host
            ).rawValue,
            "hostKind": hostKind(for: host).rawValue,
            "pathType": pathType,
            "socksGeneration": String(TailnetTransportRoute.generation),
            "transport": selection?.transportPath.rawValue ?? ConnectionTransportPath.paired.rawValue,
        ]
    }

    static func failReason(for error: Error) -> String {
        if let urlError = error as? URLError {
            return urlError.code.rawValue.description
        }
        if case APIError.server(let status, _) = error {
            return "http_\(status)"
        }
        return String(describing: type(of: error))
    }

    static func recordHandshake(
        selection: EndpointSelection,
        durationMs: Double,
        success: Bool,
        error: Error? = nil
    ) {
        var tags = tags(selection: selection)
        tags["status"] = success ? "ok" : "error"
        if let error {
            tags["failReason"] = failReason(for: error)
        }
        ClientLog.info("Network", "HTTPS candidate", metadata: tags.merging([
            "durationMs": String(Int(durationMs.rounded())),
        ]) { _, new in new })
        Task.detached(priority: .utility) {
            await ChatMetricsService.shared.record(
                metric: .networkHandshakeMs,
                value: durationMs,
                unit: .ms,
                tags: tags
            )
        }
    }

    static func recordPingRttMs(_ durationMs: Double, selection: EndpointSelection?) {
        guard durationMs.isFinite, durationMs >= 0 else { return }
        let tags = tags(selection: selection)
        Task.detached(priority: .utility) {
            await ChatMetricsService.shared.record(
                metric: .networkWsPingRttMs,
                value: durationMs,
                unit: .ms,
                tags: tags
            )
        }
    }
}
