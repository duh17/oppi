import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "LANSelect")

/// Preferred transport path selected for a server connection.
enum ConnectionTransportPath: String, Sendable, Equatable {
    case paired
    case lan
}

/// Bonjour-discovered LAN endpoint candidate for a paired server.
struct LANDiscoveredEndpoint: Sendable, Equatable {
    let host: String
    let port: Int

    /// Prefix of the server identity fingerprint (TXT `sid`).
    let serverFingerprintPrefix: String

    /// Optional prefix of leaf TLS fingerprint (TXT `tfp`).
    let tlsCertFingerprintPrefix: String?
}

/// Concrete endpoint selection used by networking clients.
struct EndpointSelection: Sendable, Equatable {
    let baseURL: URL
    let streamURL: URL
    let transportPath: ConnectionTransportPath
}

enum LANEndpointSelection {
    /// Select connection endpoint for a server.
    ///
    /// Trust policy (v1): LAN-direct is allowed only when
    /// 1) discovered server identity prefix matches paired server fingerprint, and
    /// 2) paired credentials include a pinned TLS leaf fingerprint.
    ///
    /// Optional discovered TLS fingerprint prefix (`tfp`) is treated as an extra check
    /// when present.
    static func select(
        credentials: ServerCredentials,
        discoveredEndpoint: LANDiscoveredEndpoint?
    ) -> EndpointSelection? {
        guard let paired = pairedSelection(from: credentials) else {
            return nil
        }

        guard let discoveredEndpoint else {
            return paired
        }

        guard (1...65_535).contains(discoveredEndpoint.port) else {
            logger.info("LAN rejected: invalid port \(discoveredEndpoint.port)")
            return paired
        }

        guard discoveredMatchesPairedServer(
            discoveredPrefix: discoveredEndpoint.serverFingerprintPrefix,
            pairedFingerprint: credentials.normalizedServerFingerprint
        ) else {
            logger.info("LAN rejected: server fingerprint mismatch")
            return paired
        }

        guard let pinnedTLSFingerprint = normalizeFingerprint(credentials.normalizedTLSCertFingerprint) else {
            logger.info("LAN rejected: no TLS cert fingerprint in paired credentials")
            return paired
        }

        if let discoveredTLSPrefix = normalizeFingerprint(discoveredEndpoint.tlsCertFingerprintPrefix),
           !pinnedTLSFingerprint.hasPrefix(discoveredTLSPrefix) {
            logger.info("LAN rejected: TLS fingerprint prefix mismatch")
            return paired
        }

        let scheme = credentials.resolvedScheme
        guard let lanBaseURL = URL(string: "\(scheme.rawValue)://\(discoveredEndpoint.host):\(discoveredEndpoint.port)"),
              let lanStreamURL = URL(string: "\(scheme.websocketScheme)://\(discoveredEndpoint.host):\(discoveredEndpoint.port)/stream") else {
            return paired
        }

        logger.info("LAN selected: \(discoveredEndpoint.host, privacy: .public):\(discoveredEndpoint.port)")

        return EndpointSelection(
            baseURL: lanBaseURL,
            streamURL: lanStreamURL,
            transportPath: .lan
        )
    }

    private static func pairedSelection(from credentials: ServerCredentials) -> EndpointSelection? {
        guard let baseURL = credentials.baseURL,
              let streamURL = credentials.streamURL else {
            return nil
        }

        return EndpointSelection(
            baseURL: baseURL,
            streamURL: streamURL,
            transportPath: .paired
        )
    }

    private static func discoveredMatchesPairedServer(
        discoveredPrefix: String,
        pairedFingerprint: String?
    ) -> Bool {
        guard let normalizedPaired = normalizeFingerprint(pairedFingerprint),
              let normalizedPrefix = normalizeFingerprint(discoveredPrefix) else {
            return false
        }

        return normalizedPaired.hasPrefix(normalizedPrefix)
    }

    private static func normalizeFingerprint(_ value: String?) -> String? {
        guard let value else { return nil }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("sha256:") {
            return String(trimmed.dropFirst("sha256:".count))
        }

        return trimmed
    }
}
