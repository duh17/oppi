import Foundation
import Testing
@testable import Oppi

@Suite("Iroh invite pairing client")
struct IrohInvitePairingClientTests {
    @Test func sendsPairRequestAndParsesDeviceToken() async throws {
        let response = try IrohFrameCodec.encode(header: [
            "v": 1,
            "kind": "pairResponse",
            "ok": true,
            "deviceToken": "dt_iroh",
        ])
        let transport = RecordingPairingTransport(response: response)
        let client = RealIrohInvitePairingClient(transport: transport)

        let result = await client.pairDevice(
            pairingToken: "pt_invite",
            iroh: irohTransport(),
            deviceName: "Duh Ifone"
        )
        let request = try await transport.decodedRequest()

        #expect(result == .success(deviceToken: "dt_iroh"))
        #expect(request.header["kind"] == "pairRequest")
        #expect(request.header["pairingToken"] == "pt_invite")
        #expect(request.header["deviceName"] == "Duh Ifone")
        #expect(await transport.alpns() == ["oppi/pair/1"])
    }

    @Test func parsesPairingRejectionWithoutTransportFallbackSignal() async throws {
        let response = try IrohFrameCodec.encode(header: [
            "v": 1,
            "kind": "pairResponse",
            "ok": false,
            "status": 401,
            "error": "Invalid or expired pairing token",
        ])
        let client = RealIrohInvitePairingClient(transport: RecordingPairingTransport(response: response))

        let result = await client.pairDevice(
            pairingToken: "pt_invite",
            iroh: irohTransport(),
            deviceName: nil
        )

        #expect(result == .pairingRejected(status: 401, message: "Invalid or expired pairing token"))
    }

    private func irohTransport() -> IrohServerTransport {
        IrohServerTransport(
            version: 2,
            nodeId: "node-id-test",
            alpns: ["oppi/pair/1"],
            addressMode: .ticket,
            ticket: "endpoint-test"
        )
    }
}

private actor RecordingPairingTransport: IrohFrameTransport {
    private let response: Data
    private var requests: [Data] = []
    private var seenALPNs: [String] = []

    init(response: Data) {
        self.response = response
    }

    func exchange(
        iroh: IrohServerTransport,
        alpn: String,
        requestFrame: Data,
        maxResponseBytes: UInt32
    ) async throws -> Data {
        seenALPNs.append(alpn)
        requests.append(requestFrame)
        return response
    }

    func decodedRequest() throws -> IrohFrame {
        try IrohFrameCodec.decode(requests[0])
    }

    func alpns() -> [String] {
        seenALPNs
    }
}
