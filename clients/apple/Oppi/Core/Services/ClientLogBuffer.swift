import Foundation

enum ClientLogLevel: String, Codable, Sendable {
    case debug
    case info
    case warning
    case error
}

enum ClientLog {
    static func record(
        _ level: ClientLogLevel,
        category: String,
        message: String,
        metadata: [String: String] = [:]
    ) {
#if !DEBUG
        // Keep release breadcrumb volume low. Sentry gets warning+error only.
        guard level == .warning || level == .error else { return }
#endif

        Task.detached(priority: .utility) {
            await SentryService.shared.recordBreadcrumb(
                level: level,
                category: category,
                message: message,
                metadata: metadata
            )
        }
    }

    static func info(_ category: String, _ message: String, metadata: [String: String] = [:]) {
        record(.info, category: category, message: message, metadata: metadata)
    }

    // periphery:ignore - API surface; warning log level not yet consumed
    static func warning(_ category: String, _ message: String, metadata: [String: String] = [:]) {
        record(.warning, category: category, message: message, metadata: metadata)
    }

    static func error(_ category: String, _ message: String, metadata: [String: String] = [:]) {
        record(.error, category: category, message: message, metadata: metadata)
    }

    /// Privacy-preserving network error metadata for remote diagnostics.
    ///
    /// Do not include localized descriptions or failing URLs here: both can
    /// contain private hostnames, LAN IPs, paths, or query strings. Domain and
    /// numeric code are enough to distinguish TLS, DNS, handoff, and timeout
    /// failures without leaking server identity.
    static func networkErrorMetadata(_ error: Error) -> [String: String] {
        let nsError = error as NSError
        var metadata: [String: String] = [
            "errorDomain": nsError.domain,
            "errorCode": String(nsError.code),
        ]

        if nsError.domain == NSURLErrorDomain {
            metadata["urlErrorCode"] = String(nsError.code)
        }

        return metadata
    }

    /// Privacy-preserving endpoint metadata for remote diagnostics.
    ///
    /// Hostnames and IPs are deliberately reduced to coarse classes. This lets
    /// us prove whether a failure happened on Tailscale, private LAN, localhost,
    /// or a public hostname without uploading the actual address.
    static func endpointMetadata(_ url: URL?, prefix: String) -> [String: String] {
        guard let url else {
            return [
                "\(prefix)Scheme": "none",
                "\(prefix)HostKind": "none",
                "\(prefix)Port": "none",
            ]
        }

        return [
            "\(prefix)Scheme": url.scheme ?? "unknown",
            "\(prefix)HostKind": hostKind(url.host),
            "\(prefix)Port": url.port.map(String.init) ?? "default",
        ]
    }

    static func hostKind(_ host: String?) -> String {
        guard var normalized = host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalized.isEmpty else {
            return "none"
        }

        if normalized.hasPrefix("[") && normalized.hasSuffix("]") {
            normalized = String(normalized.dropFirst().dropLast())
        }

        if normalized == "localhost" {
            return "localhost"
        }

        if normalized.hasSuffix(".ts.net") || normalized.hasSuffix(".beta.tailscale.net") {
            return "tailscale"
        }

        if normalized.hasSuffix(".local") {
            return "local-hostname"
        }

        if let ipv4Kind = ipv4HostKind(normalized) {
            return ipv4Kind
        }

        if normalized.contains(":") {
            if normalized == "::1" { return "localhost" }
            if normalized.hasPrefix("fc") || normalized.hasPrefix("fd") || normalized.hasPrefix("fe80") {
                return "private-ipv6"
            }
            return "ipv6"
        }

        return "hostname"
    }

    private static func ipv4HostKind(_ value: String) -> String? {
        let parts = value.split(separator: ".")
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else {
            return nil
        }

        if octets[0] == 127 {
            return "localhost"
        }
        if octets[0] == 10
            || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
            || (octets[0] == 169 && octets[1] == 254) {
            return "private-ipv4"
        }
        return "public-ipv4"
    }
}
