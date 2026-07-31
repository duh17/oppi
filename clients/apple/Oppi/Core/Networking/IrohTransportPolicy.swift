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

enum ServerTransportPlan: Equatable, Sendable {
    case http(EndpointSelection)
    case iroh(IrohServerTransport)
}

/// A route identifier used only to exclude candidates within one selection pass.
enum ServerRouteCandidateKind: Sendable, Equatable, Hashable {
    case lan
    case paired
    case iroh
}

enum ServerRouteFailure {
    /// Availability failures may advance to the next candidate. Auth, TLS,
    /// peer, ALPN, framing, and protocol failures fail closed.
    static func mayAdvance(after error: Error) -> Bool {
        if APIClientAvailabilityFailure(error: error) != nil {
            return true
        }
        if let error = error as? IrohTransportError {
            return error.isFallbackEligible
        }
        return false
    }
}

enum ServerTransportPlanResolver {
    /// Builds ordered, authorized routes without retaining connection state.
    /// Exclusions apply only to this invocation; callers own pass lifecycle.
    ///
    /// Iroh metadata is not validated here. A healthy earlier HTTPS candidate
    /// must not inspect a later unused Iroh route; callers validate when the
    /// walk reaches `.iroh`.
    static func candidates(
        credentials: ServerCredentials,
        mode: PairedServerRouteMode,
        discoveredLANEndpoint: LANDiscoveredEndpoint?,
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
            if !excluding.contains(.iroh) {
                result.append(.iroh(iroh))
            }
        }

        return result
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
