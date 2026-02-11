import Foundation

enum ConnectionSecurityViolation: LocalizedError, Equatable {
    case insecureTailnetTransportBlocked(host: String)
    case insecurePublicTransportBlocked(host: String)

    var errorDescription: String? {
        switch self {
        case .insecureTailnetTransportBlocked(let host):
            return "Server policy blocks insecure HTTP/WebSocket on tailnet host \(host)."
        case .insecurePublicTransportBlocked(let host):
            return "Server policy requires TLS outside tailnet; insecure host \(host) is not allowed."
        }
    }
}

enum ConnectionSecurityPolicy {
    private enum HostClass {
        case tailnet
        case local
        case publicNetwork
    }

    static func evaluate(credentials: ServerCredentials) -> ConnectionSecurityViolation? {
        guard credentials.requireTlsOutsideTailnet != nil || credentials.allowInsecureHttpInTailnet != nil else {
            return nil
        }

        return evaluate(
            host: credentials.host,
            requireTlsOutsideTailnet: credentials.requireTlsOutsideTailnet ?? false,
            allowInsecureHttpInTailnet: credentials.allowInsecureHttpInTailnet ?? true
        )
    }

    static func evaluate(host: String, profile: ServerSecurityProfile) -> ConnectionSecurityViolation? {
        evaluate(
            host: host,
            requireTlsOutsideTailnet: profile.requireTlsOutsideTailnet ?? false,
            allowInsecureHttpInTailnet: profile.allowInsecureHttpInTailnet ?? true
        )
    }

    static func evaluate(
        host: String,
        requireTlsOutsideTailnet: Bool,
        allowInsecureHttpInTailnet: Bool
    ) -> ConnectionSecurityViolation? {
        let hostClass = classifyHost(host)

        switch hostClass {
        case .tailnet:
            if !allowInsecureHttpInTailnet {
                return .insecureTailnetTransportBlocked(host: host)
            }
            return nil

        case .local:
            // Local-network hosts are explicitly allowed by ATS local-network policy.
            return nil

        case .publicNetwork:
            if requireTlsOutsideTailnet {
                return .insecurePublicTransportBlocked(host: host)
            }
            return nil
        }
    }

    private static func classifyHost(_ host: String) -> HostClass {
        let normalized = normalizeHost(host)

        if normalized.hasSuffix(".ts.net") {
            return .tailnet
        }

        if normalized == "localhost" || normalized.hasSuffix(".local") {
            return .local
        }

        if !normalized.contains(".") && !normalized.contains(":") {
            return .local
        }

        if let octets = parseIPv4(normalized) {
            if isTailnetIPv4(octets) { return .tailnet }
            if isLocalIPv4(octets) { return .local }
            return .publicNetwork
        }

        if normalized == "::1" || normalized.hasPrefix("fe80:") {
            return .local
        }

        if normalized.hasPrefix("fd7a:115c:a1e0:") {
            return .tailnet
        }

        if normalized.hasPrefix("fc") || normalized.hasPrefix("fd") {
            return .local
        }

        return .publicNetwork
    }

    private static func normalizeHost(_ host: String) -> String {
        var value = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if value.hasPrefix("[") && value.hasSuffix("]") {
            value.removeFirst()
            value.removeLast()
        }

        return value
    }

    private static func parseIPv4(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return nil }

        var octets: [Int] = []
        octets.reserveCapacity(4)

        for part in parts {
            guard let value = Int(part), (0...255).contains(value) else {
                return nil
            }
            octets.append(value)
        }

        return octets
    }

    private static func isTailnetIPv4(_ octets: [Int]) -> Bool {
        guard octets.count == 4 else { return false }
        guard octets[0] == 100 else { return false }
        return (64...127).contains(octets[1])
    }

    private static func isLocalIPv4(_ octets: [Int]) -> Bool {
        guard octets.count == 4 else { return false }

        if octets[0] == 10 { return true }
        if octets[0] == 127 { return true }
        if octets[0] == 192 && octets[1] == 168 { return true }
        if octets[0] == 169 && octets[1] == 254 { return true }
        if octets[0] == 172 && (16...31).contains(octets[1]) { return true }

        return false
    }
}
