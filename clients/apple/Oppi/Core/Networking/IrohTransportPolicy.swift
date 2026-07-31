import Foundation

enum IrohTunnelProtocol {
    static let alpn = "oppi/http/1"
    static let version = 1
    static let supportedMetadataVersion = 2
    static let maxPrefaceBytes = 16 * 1024

    static func makePreface(token: String) throws -> Data {
        guard !token.isEmpty else {
            throw IrohTransportError.authentication("Missing Iroh device token")
        }
        let frame = try IrohFrameCodec.encode(header: [
            "v": .number(Double(version)),
            "kind": .string("httpTunnel"),
            "authorization": .string(ServerAuthorization.headerValue(token: token)),
        ])
        guard frame.count <= maxPrefaceBytes else {
            throw IrohTransportError.framing("Iroh tunnel preface exceeds \(maxPrefaceBytes) bytes")
        }
        return frame
    }
}

enum IrohTransportError: LocalizedError, Equatable, Sendable {
    case unsupportedMetadataVersion(Int)
    case unsupportedALPN(String)
    case malformedNodeID
    case missingTicket
    case malformedTicket
    case ticketPeerMismatch(expected: String, actual: String)
    case remotePeerMismatch(expected: String, actual: String)
    case unavailable(String)
    case authentication(String)
    case framing(String)
    case protocolViolation(String)
    case listener(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedMetadataVersion(let version):
            "Unsupported Iroh transport metadata version \(version)"
        case .unsupportedALPN(let alpn):
            "Iroh server does not advertise \(alpn)"
        case .malformedNodeID:
            "Signed Iroh node ID is malformed"
        case .missingTicket:
            "Signed Iroh ticket-mode metadata is missing its ticket"
        case .malformedTicket:
            "Signed Iroh endpoint ticket is malformed"
        case .ticketPeerMismatch(let expected, let actual):
            "Iroh ticket peer mismatch (expected \(expected), got \(actual))"
        case .remotePeerMismatch(let expected, let actual):
            "Connected Iroh peer mismatch (expected \(expected), got \(actual))"
        case .unavailable(let message), .authentication(let message), .framing(let message),
             .protocolViolation(let message), .listener(let message):
            message
        }
    }

    /// Only reachability failures may downgrade `irohPreferred` to its signed
    /// HTTP transport. Keep this switch exhaustive so every new error case gets
    /// an explicit security decision.
    var isFallbackEligible: Bool {
        switch self {
        case .unavailable:
            true
        case .unsupportedMetadataVersion,
             .unsupportedALPN,
             .malformedNodeID,
             .missingTicket,
             .malformedTicket,
             .ticketPeerMismatch,
             .remotePeerMismatch,
             .authentication,
             .framing,
             .protocolViolation,
             .listener:
            false
        }
    }
}

enum ServerTransportSelection: Equatable, Sendable {
    case iroh(IrohServerTransport)
    case http
}

enum ServerTransportPlan: Equatable, Sendable {
    case http(EndpointSelection)
    case iroh(IrohServerTransport)

    var candidateKind: ServerRouteCandidateKind {
        switch self {
        case .http(let endpoint):
            endpoint.transportPath == .lan ? .lan : .paired
        case .iroh:
            .iroh
        }
    }
}

/// A route identifier used only to exclude candidates within one selection pass.
enum ServerRouteCandidateKind: Sendable, Equatable, Hashable {
    case lan
    case paired
    case iroh
}

enum ServerTransportPlanResolver {
    /// Builds ordered, authorized routes without retaining connection state.
    /// Exclusions apply only to this invocation; callers own pass lifecycle.
    static func candidates(
        credentials: ServerCredentials,
        mode: PairedServerRouteMode,
        discoveredLANEndpoint: LANDiscoveredEndpoint?,
        validateIrohMetadata: Bool = true,
        excluding: Set<ServerRouteCandidateKind> = []
    ) throws -> [ServerTransportPlan] {
        let authorization = credentials.transports.authorizedTransports
        let effectiveMode = mode.effective(for: authorization)
        var result: [ServerTransportPlan] = []

        if effectiveMode.requestedTransports.contains(.https), authorization.contains(.https) {
            guard credentials.transports.http != nil,
                  let paired = LANEndpointSelection.select(
                      credentials: credentials,
                      discoveredEndpoint: nil
                  ) else {
                throw IrohTransportError.protocolViolation("Signed HTTPS transport has no valid endpoint")
            }
            if effectiveMode == .httpsOnly,
               paired.baseURL.scheme?.lowercased() != ServerScheme.https.rawValue {
                // Historical signed HTTP credentials remain available through
                // Automatic compatibility only. The explicit product setting
                // named HTTPS Only must never authorize plaintext transport.
                throw IrohTransportError.protocolViolation(
                    "HTTPS Only requires a signed HTTPS endpoint"
                )
            }

            if let lan = LANEndpointSelection.select(
                credentials: credentials,
                discoveredEndpoint: discoveredLANEndpoint
            ), lan.transportPath == .lan, !excluding.contains(.lan) {
                result.append(.http(lan))
            }
            if !excluding.contains(.paired) {
                result.append(.http(paired))
            }
        }

        if effectiveMode.requestedTransports.contains(.iroh), authorization.contains(.iroh) {
            guard let iroh = credentials.transports.iroh else {
                throw IrohTransportError.protocolViolation("Signed Iroh transport is missing metadata")
            }
            if validateIrohMetadata {
                try IrohPeerValidator.validate(iroh, requiredALPN: IrohTunnelProtocol.alpn)
            }
            if !excluding.contains(.iroh) {
                result.append(.iroh(iroh))
            }
        }

        return result
    }

    /// Temporary compatibility seam for callers that have not yet walked
    /// candidates. It retains their current behavior; new routing code must use
    /// `candidates` so `irohPreferred` is never interpreted as candidate order.
    static func resolve(
        credentials: ServerCredentials,
        discoveredLANEndpoint: LANDiscoveredEndpoint?,
        suppressIroh: Bool = false
    ) throws -> ServerTransportPlan {
        if credentials.transports.preference != .irohOnly,
           let lan = LANEndpointSelection.select(
               credentials: credentials,
               discoveredEndpoint: discoveredLANEndpoint
           ),
           lan.transportPath == .lan {
            return .http(lan)
        }

        if suppressIroh {
            guard credentials.transports.preference == .irohPreferred,
                  let http = LANEndpointSelection.select(
                      credentials: credentials,
                      discoveredEndpoint: nil
                  ) else {
                throw IrohTransportError.protocolViolation(
                    "Iroh fallback requires a signed HTTP transport"
                )
            }
            return .http(http)
        }

        switch try IrohTransportPolicy.select(credentials: credentials) {
        case .http:
            guard let http = LANEndpointSelection.select(
                credentials: credentials,
                discoveredEndpoint: nil
            ) else {
                throw IrohTransportError.protocolViolation("HTTP transport has no valid endpoint")
            }
            return .http(http)
        case .iroh(let iroh):
            return .iroh(iroh)
        }
    }
}

enum IrohTransportPolicy {
    static func select(credentials: ServerCredentials) throws -> ServerTransportSelection {
        switch credentials.transports.preference {
        case .httpOnly:
            guard credentials.transports.http != nil else {
                throw IrohTransportError.protocolViolation("HTTP-only credentials have no HTTP transport")
            }
            return .http

        case .irohOnly:
            guard let iroh = credentials.transports.iroh else {
                throw IrohTransportError.protocolViolation("Iroh-only credentials have no Iroh transport")
            }
            try IrohPeerValidator.validate(iroh, requiredALPN: IrohTunnelProtocol.alpn)
            return .iroh(iroh)

        case .irohPreferred:
            if let iroh = credentials.transports.iroh,
               iroh.alpns.contains(IrohTunnelProtocol.alpn) {
                // Advertising the tunnel commits this connection attempt to
                // Iroh. Invalid version/address metadata is a protocol error,
                // not a reason to silently downgrade to HTTP.
                try IrohPeerValidator.validate(iroh, requiredALPN: IrohTunnelProtocol.alpn)
                return .iroh(iroh)
            }
            guard credentials.transports.http != nil else {
                throw IrohTransportError.protocolViolation(
                    "Iroh-preferred credentials support neither the tunnel nor HTTP"
                )
            }
            return .http
        }
    }
}

enum IrohPeerValidator {
    static func validate(_ iroh: IrohServerTransport, requiredALPN: String) throws {
        guard iroh.version == IrohTunnelProtocol.supportedMetadataVersion else {
            throw IrohTransportError.unsupportedMetadataVersion(iroh.version)
        }
        guard !iroh.nodeId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IrohTransportError.malformedNodeID
        }
        guard iroh.alpns.contains(requiredALPN) else {
            throw IrohTransportError.unsupportedALPN(requiredALPN)
        }
        if iroh.addressMode == .ticket {
            guard let ticket = iroh.ticket?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !ticket.isEmpty else {
                throw IrohTransportError.missingTicket
            }
        }
    }

    static func validateTicketPeer(expectedNodeID: String, ticketNodeID: String) throws {
        guard expectedNodeID == ticketNodeID else {
            throw IrohTransportError.ticketPeerMismatch(expected: expectedNodeID, actual: ticketNodeID)
        }
    }

    static func validateConnectedPeer(expectedNodeID: String, remoteNodeID: String) throws {
        guard expectedNodeID == remoteNodeID else {
            throw IrohTransportError.remotePeerMismatch(expected: expectedNodeID, actual: remoteNodeID)
        }
    }
}
