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
    /// Hostname from signed pairing metadata used to evaluate public-CA TLS
    /// while the TCP connection targets a Bonjour-discovered LAN IP.
    let tlsServerName: String?

    init(
        baseURL: URL,
        transportPath: ConnectionTransportPath,
        tlsServerName: String? = nil
    ) {
        self.baseURL = baseURL
        self.transportPath = transportPath
        self.tlsServerName = tlsServerName
    }
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
        // Remote authentication is HTTPS/WSS-only. The same rule applies to
        // discovered LAN endpoints so a plaintext invite cannot downgrade auth.
        guard credentials.resolvedScheme == .https,
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

        let tlsServerName: String?
        if let pinnedTLSFingerprint = normalizeFingerprint(credentials.normalizedTLSCertFingerprint) {
            if let discoveredTLSPrefix = normalizeFingerprint(discoveredEndpoint.tlsCertFingerprintPrefix),
               !pinnedTLSFingerprint.hasPrefix(discoveredTLSPrefix) {
                logger.warning("LAN rejected: TLS fingerprint prefix mismatch")
                return paired
            }
            tlsServerName = nil
        } else {
            let pairedPort = paired.baseURL.port ?? 443
            guard let pairedHost = paired.baseURL.host,
                  ServerTLSTrustPolicy.allowsUnpinnedLANShortcut(forHost: pairedHost),
                  discoveredEndpoint.port == pairedPort else {
                logger.warning("LAN rejected: endpoint lacks a pin or exact Tailscale public-CA identity")
                return paired
            }
            // TCP targets the LAN IP, while trust is evaluated against the exact
            // signed Tailscale hostname. This is actual LAN transport without
            // weakening public-CA hostname authentication.
            tlsServerName = pairedHost
        }

        let scheme = credentials.resolvedScheme
        let lanHost = discoveredEndpoint.host

        guard let lanBaseURL = URL(string: "\(scheme.rawValue)://\(lanHost):\(discoveredEndpoint.port)") else {
            return paired
        }

        logger.warning("LAN selected: \(lanHost, privacy: .private):\(discoveredEndpoint.port) (discovered: \(discoveredEndpoint.host, privacy: .private))")

        return EndpointSelection(
            baseURL: lanBaseURL,
            transportPath: .lan,
            tlsServerName: tlsServerName
        )
    }

    static func isReachable(
        _ selection: EndpointSelection,
        credentials: ServerCredentials,
        timeoutInterval: TimeInterval = 2
    ) async -> Bool {
        let client = APIClient(environment: OppiClientEnvironment(
            baseURL: selection.baseURL,
            bearerToken: credentials.effectiveAccessToken,
            pinnedCertificateFingerprint: credentials.normalizedTLSCertFingerprint,
            tlsServerName: selection.tlsServerName
        ))
        do {
            return try await client.health(timeoutInterval: timeoutInterval)
        } catch {
            return false
        }
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

    /// The discovered endpoint that best matches a paired server, among those
    /// `select` would route over LAN: the most specific server-fingerprint
    /// prefix first, then the most specific TLS prefix the paired pin agrees
    /// with (a prefix the pin rules out, or any prefix without a pin, ranks
    /// last), then host and port.
    static func bestEndpoint(
        serverId: String,
        credentials: ServerCredentials,
        among pool: [LANDiscoveredEndpoint]
    ) -> LANDiscoveredEndpoint? {
        guard let normalizedServerId = rankingFingerprint(serverId) else { return nil }
        let normalizedPinnedTLS = rankingFingerprint(credentials.normalizedTLSCertFingerprint)

        let rankedCandidates = pool
            .filter { endpoint in
                guard let prefix = rankingFingerprint(endpoint.serverFingerprintPrefix) else { return false }
                return normalizedServerId.hasPrefix(prefix)
            }
            .sorted { lhs, rhs in
                let lhsServerSpecificity = rankingFingerprint(lhs.serverFingerprintPrefix)?.count ?? 0
                let rhsServerSpecificity = rankingFingerprint(rhs.serverFingerprintPrefix)?.count ?? 0
                if lhsServerSpecificity != rhsServerSpecificity {
                    return lhsServerSpecificity > rhsServerSpecificity
                }

                let lhsTLSSpecificity = tlsPrefixSpecificityScore(
                    endpointTLSPrefix: lhs.tlsCertFingerprintPrefix,
                    normalizedPinnedTLS: normalizedPinnedTLS
                )
                let rhsTLSSpecificity = tlsPrefixSpecificityScore(
                    endpointTLSPrefix: rhs.tlsCertFingerprintPrefix,
                    normalizedPinnedTLS: normalizedPinnedTLS
                )
                if lhsTLSSpecificity != rhsTLSSpecificity {
                    return lhsTLSSpecificity > rhsTLSSpecificity
                }

                if lhs.host != rhs.host {
                    return lhs.host < rhs.host
                }
                return lhs.port < rhs.port
            }

        return rankedCandidates.first { candidate in
            select(credentials: credentials, discoveredEndpoint: candidate)?.transportPath == .lan
        }
    }

    private static func tlsPrefixSpecificityScore(
        endpointTLSPrefix: String?,
        normalizedPinnedTLS: String?
    ) -> Int {
        guard let normalizedPrefix = rankingFingerprint(endpointTLSPrefix) else {
            return 0
        }

        guard let normalizedPinnedTLS else {
            return -1
        }

        return normalizedPinnedTLS.hasPrefix(normalizedPrefix) ? normalizedPrefix.count : -1
    }

    /// `normalizeFingerprint`, with a bare `sha256:` treated as no fingerprint.
    private static func rankingFingerprint(_ value: String?) -> String? {
        guard let normalized = normalizeFingerprint(value), !normalized.isEmpty else { return nil }
        return normalized
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

enum ServerRouteCandidateKind: Hashable, Sendable {
    case paired
    case lan
}

enum ServerRouteFailure {
    static func mayAdvance(after error: Error) -> Bool {
        if APIClientAvailabilityFailure(error: error) != nil {
            return true
        }
        if case APIError.server(let status, _) = error {
            return status == 401 || status == 404 || status == 408 || status >= 500
        }
        return false
    }

    /// A failure a later identical attempt can get past on its own: the server
    /// was unreachable, timed out, or failed on its end. `mayAdvance` also lets
    /// 401 and 404 fall through to the next route, but waiting does not change
    /// those answers.
    static func isTransient(_ error: Error) -> Bool {
        if APIClientAvailabilityFailure(error: error) != nil {
            return true
        }
        if case APIError.server(let status, _) = error {
            return status == 408 || status >= 500
        }
        return false
    }
}

enum ServerTransportPlanResolver {
    static func candidates(
        credentials: ServerCredentials,
        discoveredLANEndpoint: LANDiscoveredEndpoint?,
        excluding: Set<ServerRouteCandidateKind> = [],
        pathType: String = NetworkPathTelemetry.pathType
    ) throws -> [EndpointSelection] {
        guard credentials.resolvedScheme == .https else {
            throw APIError.server(status: 403, message: "HTTPS required")
        }
        guard let paired = LANEndpointSelection.select(credentials: credentials, discoveredEndpoint: nil) else {
            throw APIError.server(status: 400, message: "Unsupported HTTPS server endpoint")
        }
        // Discovery is valid only in the current local-network context.
        var result: [EndpointSelection] = []
        if NetworkPathTelemetry.allowsLAN(pathType: pathType),
           let discoveredLANEndpoint,
           !excluding.contains(.lan),
           let lan = LANEndpointSelection.select(credentials: credentials, discoveredEndpoint: discoveredLANEndpoint),
           lan.transportPath == .lan {
            result.append(lan)
        }
        if !excluding.contains(.paired) { result.append(paired) }
        return result
    }
}
