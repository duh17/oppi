import Foundation
import Network
import Synchronization

/// How a connection reached the server: the route, host class, interface, and
/// transport that network events carry. `system_vpn` is inferred: MagicDNS
/// without a published embed SOCKS proxy (official Tailscale VPN or broken
/// resolver). Not a user-facing route picker.
struct NetworkRouteSnapshot: Sendable {
    let route: TelemetryTag.Route
    let hostKind: TelemetryTag.HostKind
    let pathType: TelemetryTag.PathType
    let socksGeneration: Int
    let transportPath: ConnectionTransportPath

    /// The transport as an event's own narrowed `transport` enum; the three
    /// values are the same strings on every network event.
    func transport<T: RawRepresentable>(as type: T.Type) -> T? where T.RawValue == String {
        T(rawValue: transportPath.rawValue)
    }

    /// The same facts as log metadata.
    var logMetadata: [String: String] {
        [
            "route": route.rawValue,
            "hostKind": hostKind.rawValue,
            "pathType": pathType.rawValue,
            "socksGeneration": String(socksGeneration),
            "transport": transportPath.rawValue,
        ]
    }
}

enum NetworkPathTelemetry {

    private static let interfaceKind = Mutex<String>("unknown")

    static func allowsLAN(pathType: String) -> Bool {
        pathType == "wifi" || pathType == "eth"
    }

    static func recordRouteCommitted(selection: EndpointSelection, socksGeneration: UInt64) {
        var metadata = tags(selection: selection, socksGeneration: socksGeneration).logMetadata
        metadata["sinceLaunchMs"] = String(Int(max(0, (CFAbsoluteTimeGetCurrent() - ChatSessionTelemetry.processStartTime) * 1_000)))
        ClientLog.info("Network", "Route committed", metadata: metadata)
    }

    static func note(path: NWPath) {
        let kind: String
        if path.status != .satisfied {
            kind = "unknown"
        } else if path.usesInterfaceType(.cellular) {
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

    static func hostKind(for host: String) -> TelemetryTag.HostKind {
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
    ) -> TelemetryTag.Route {
        if transportPath == .lan { return .lan }
        if ServerTLSTrustPolicy.isTailscaleHostname(host) {
            return socksPublished ? .socks : .systemVpn
        }
        return .paired
    }

    static func tags(
        selection: EndpointSelection?,
        socksGeneration: UInt64 = TailnetTransportRoute.generation
    ) -> NetworkRouteSnapshot {
        let host = selection?.baseURL.host ?? ""
        let transportPath = selection?.transportPath ?? .paired
        return NetworkRouteSnapshot(
            route: routeKind(
                transportPath: transportPath,
                host: host,
                socksPublished: socksGeneration != 0
            ),
            hostKind: hostKind(for: host),
            pathType: TelemetryTag.PathType(rawValue: pathType) ?? .unknown,
            socksGeneration: Int(socksGeneration),
            transportPath: transportPath
        )
    }

    static func recordHandshake(
        selection: EndpointSelection,
        durationMs: Double,
        error: Error? = nil,
        socksGeneration: UInt64 = TailnetTransportRoute.generation
    ) {
        let route = tags(selection: selection, socksGeneration: socksGeneration)
        let errorKind = error.map(TelemetryErrorKind.classify)
        var metadata = route.logMetadata
        metadata["status"] = error == nil ? "ok" : "error"
        if let errorKind { metadata["error_kind"] = errorKind.rawValue }
        ClientLog.info("Network", "HTTPS candidate", metadata: metadata)
        Telemetry.record(
            AppNetworkHandshake(
                durationMs: durationMs,
                socksGeneration: route.socksGeneration,
                route: route.route,
                hostKind: route.hostKind,
                pathType: route.pathType,
                transport: route.transport(as: AppNetworkHandshake.Transport.self),
                status: error == nil ? .ok : .error,
                errorKind: errorKind
            )
        )
    }

    static func recordPingRttMs(
        _ durationMs: Double,
        selection: EndpointSelection?,
        socksGeneration: UInt64 = TailnetTransportRoute.generation
    ) {
        let route = tags(selection: selection, socksGeneration: socksGeneration)
        Telemetry.record(
            AppWsPing(
                rttMs: durationMs,
                socksGeneration: route.socksGeneration,
                route: route.route,
                hostKind: route.hostKind,
                pathType: route.pathType,
                transport: route.transport(as: AppWsPing.Transport.self)
            )
        )
    }
}
