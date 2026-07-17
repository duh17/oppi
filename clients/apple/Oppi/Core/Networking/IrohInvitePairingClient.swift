import Foundation

struct RealIrohInvitePairingClient: IrohInvitePairingClient {
    private let transport: any IrohFrameTransport
    private let alpn = "oppi/pair/1"
    private let maxPairingFrameBytes: UInt32 = 4 + 16 * 1024

    init(transport: any IrohFrameTransport = IrohLibFrameTransport()) {
        self.transport = transport
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

        let responseBytes: Data
        do {
            responseBytes = try await transport.exchange(
                iroh: iroh,
                alpn: alpn,
                requestFrame: request,
                maxResponseBytes: maxPairingFrameBytes
            )
        } catch {
            return .transportUnavailable(error.localizedDescription)
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
            return .success(deviceToken: deviceToken)
        }

        let status = header["status"]?.numberValue.map(Int.init) ?? 500
        let message = header["error"]?.stringValue ?? "Iroh pairing failed"
        return .pairingRejected(status: status, message: message)
    }
}
