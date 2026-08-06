import Foundation

/// Validates pairing-specific signed metadata and proves the server accepts
/// `oppi/pair/1` without sending the one-time pairing request.
protocol IrohInvitePairingReachabilityProbing: Sendable {
    func probe(iroh: IrohServerTransport) async throws
}

struct RealIrohInvitePairingReachabilityProbe: IrohInvitePairingReachabilityProbing {
    private let relayPreparer: @Sendable (IrohServerTransport) async throws -> Void
    private let managerProvider: @Sendable (IrohServerTransport) async throws -> IrohConnectionManager

    init(
        relayPreparer: @escaping @Sendable (IrohServerTransport) async throws -> Void = { transport in
            try await IrohTransportRegistry.shared.prepare(iroh: transport)
        },
        managerProvider: @escaping @Sendable (IrohServerTransport) async throws -> IrohConnectionManager = { transport in
            try await IrohTransportRegistry.shared.manager(for: transport)
        }
    ) {
        self.relayPreparer = relayPreparer
        self.managerProvider = managerProvider
    }

    func probe(iroh: IrohServerTransport) async throws {
        try IrohPeerValidator.validate(iroh, requiredALPN: "oppi/pair/1")
        try await relayPreparer(iroh)
        let manager = try await managerProvider(iroh)
        try await manager.probeReachability(alpn: "oppi/pair/1")
    }
}

struct RealIrohInvitePairingClient: IrohInvitePairingClient {
    private let transport: any IrohFrameTransport
    private let relayPreparer: @Sendable (IrohServerTransport) async throws -> Void
    private let alpn = "oppi/pair/1"
    private let maxPairingFrameBytes: UInt32 = 4 + 16 * 1024

    init(
        transport: any IrohFrameTransport = IrohLibFrameTransport(),
        relayPreparer: @escaping @Sendable (IrohServerTransport) async throws -> Void = { transport in
            try await IrohTransportRegistry.shared.prepare(iroh: transport)
        }
    ) {
        self.transport = transport
        self.relayPreparer = relayPreparer
    }

    func pairDevice(
        pairingToken: String,
        iroh: IrohServerTransport,
        deviceName: String?
    ) async -> IrohInvitePairingResult {
        var header: [String: JSONValue] = [
            "v": 1,
            "kind": "pairRequest",
            "pairingToken": .string(pairingToken),
        ]
        if let deviceName, !deviceName.isEmpty {
            header["deviceName"] = .string(deviceName)
        }

        let request: Data
        do {
            request = try IrohFrameCodec.encode(header: header)
        } catch {
            return .pairingRejected(status: 502, message: "Invalid Iroh pairing request")
        }

        do {
            // The pairing frame is the first Iroh dial for a new invite, so
            // add its signed relays before opening the stream.
            try await relayPreparer(iroh)
        } catch {
            // Do not expose signed relay metadata through pairing diagnostics.
            return .transportUnavailable("Unable to prepare Iroh transport")
        }

        let responseBytes: Data
        do {
            // Entering exchange is the mutation-dispatch boundary. The route
            // was already proven by the read-only pairing probe, but a response
            // failure here cannot prove whether the server consumed the invite.
            responseBytes = try await transport.exchange(
                iroh: iroh,
                alpn: alpn,
                requestFrame: request,
                maxResponseBytes: maxPairingFrameBytes
            )
        } catch {
            return .responseUnavailable
        }

        do {
            let response = try IrohFrameCodec.decode(
                responseBytes,
                maxHeaderBytes: 16 * 1024,
                maxBodyBytes: 0
            ).header
            return parsePairingResponse(response)
        } catch {
            return .pairingRejected(status: 502, message: "Invalid Iroh pairing response")
        }
    }

    private func parsePairingResponse(_ header: [String: JSONValue]) -> IrohInvitePairingResult {
        guard header["kind"]?.stringValue == "pairResponse",
              header["v"]?.numberValue == 1,
              let ok = header["ok"]?.boolValue else {
            return .pairingRejected(status: 502, message: "Invalid Iroh pairing response")
        }

        if ok, let deviceToken = header["deviceToken"]?.stringValue, !deviceToken.isEmpty {
            let credentialTransports: [CredentialTransport]?
            if let values = header["credentialTransports"]?.arrayValue {
                let decoded = values.compactMap { value in
                    value.stringValue.flatMap(CredentialTransport.init(rawValue:))
                }
                guard decoded.count == values.count else {
                    return .pairingRejected(status: 502, message: "Invalid Iroh pairing response")
                }
                credentialTransports = decoded
            } else {
                credentialTransports = nil
            }
            return .success(
                deviceToken: deviceToken,
                credentialTransports: credentialTransports
            )
        }

        let status = header["status"]?.numberValue.map(Int.init) ?? 500
        let message = header["error"]?.stringValue ?? "Iroh pairing failed"
        return .pairingRejected(status: status, message: message)
    }
}
