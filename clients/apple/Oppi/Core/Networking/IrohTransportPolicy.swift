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

    /// Reserved for a future sticky irohPreferred fallback implementation.
    /// This wave deliberately does not act on it: once Iroh is selected, all
    /// failures remain fail-closed rather than changing transport mid-session.
    var isFallbackEligible: Bool {
        if case .unavailable = self { return true }
        return false
    }
}

enum ServerTransportSelection: Equatable, Sendable {
    case iroh(IrohServerTransport)
    case http
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
