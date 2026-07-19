import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "LANSelect")

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
    let transportPath: ConnectionTransportPath
}

enum LANEndpointSelection {
    /// Select connection endpoint for a server.
    ///
    /// Trust policy (v1): LAN-direct is allowed only when the discovered
    /// server identity matches the paired identity and HTTPS can authenticate
    /// the paired endpoint. Self-signed endpoints require the paired leaf pin.
    /// Tailscale hostnames may instead use system public-CA trust, but only on
    /// the exact paired port. Optional discovered TLS fingerprint prefix (`tfp`)
    /// is an extra check when a paired leaf pin exists.
    static func select(
        credentials: ServerCredentials,
        discoveredEndpoint: LANDiscoveredEndpoint?
    ) -> EndpointSelection? {
        // Iroh-preferred credentials still permit their signed HTTP transport.
        // Cross-lane priority is owned by ServerTransportPlanResolver; this
        // helper only validates and constructs HTTP/LAN endpoint selections.
        guard credentials.transports.preference != .irohOnly,
              credentials.transports.http != nil,
              let paired = pairedSelection(from: credentials) else {
            return nil
        }

        guard let discoveredEndpoint else {
            return paired
        }

        guard (1...65_535).contains(discoveredEndpoint.port) else {
            logger.warning("LAN rejected: invalid port \(discoveredEndpoint.port)")
            return paired
        }

        guard discoveredMatchesPairedServer(
            discoveredPrefix: discoveredEndpoint.serverFingerprintPrefix,
            pairedFingerprint: credentials.normalizedServerFingerprint
        ) else {
            logger.warning("LAN rejected: server fingerprint mismatch")
            return paired
        }

        guard credentials.resolvedScheme == .https else {
            logger.warning("LAN rejected: plaintext HTTP cannot prove the pinned TLS identity")
            return paired
        }

        if let pinnedTLSFingerprint = normalizeFingerprint(credentials.normalizedTLSCertFingerprint) {
            if let discoveredTLSPrefix = normalizeFingerprint(discoveredEndpoint.tlsCertFingerprintPrefix),
               !pinnedTLSFingerprint.hasPrefix(discoveredTLSPrefix) {
                logger.warning("LAN rejected: TLS fingerprint prefix mismatch")
                return paired
            }
        } else {
            let pairedPort = paired.baseURL.port ?? 443
            guard let pairedHost = paired.baseURL.host,
                  PinnedServerTrustDelegate.allowsPublicCATrustFallback(forHost: pairedHost),
                  discoveredEndpoint.port == pairedPort else {
                logger.warning("LAN rejected: endpoint lacks a pin or exact Tailscale public-CA identity")
                return paired
            }
        }

        let scheme = credentials.resolvedScheme

        // When using HTTPS with a hostname-based TLS cert (e.g. Tailscale),
        // keep the paired hostname in the URL instead of the discovered LAN
        // IP. The cert's CN/SAN won't match a raw IP, and iOS rejects the
        // connection in Release builds. The LAN discovery still confirms
        // server presence + port; Tailscale routes directly over LAN when
        // both peers share the same network.
        let lanHost: String
        if scheme == .https, !credentials.host.isEmpty,
           credentials.host.contains(".") && !credentials.host.allSatisfy({ $0.isNumber || $0 == "." }) {
            // Paired host is a hostname (not an IP) — use it for TLS compat
            lanHost = credentials.host
        } else {
            lanHost = discoveredEndpoint.host
        }

        guard let lanBaseURL = URL(string: "\(scheme.rawValue)://\(lanHost):\(discoveredEndpoint.port)") else {
            return paired
        }

        logger.warning("LAN selected: \(lanHost, privacy: .public):\(discoveredEndpoint.port) (discovered: \(discoveredEndpoint.host, privacy: .public))")

        return EndpointSelection(
            baseURL: lanBaseURL,
            transportPath: .lan
        )
    }

    private static func pairedSelection(from credentials: ServerCredentials) -> EndpointSelection? {
        guard let baseURL = credentials.baseURL else {
            return nil
        }

        return EndpointSelection(
            baseURL: baseURL,
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
