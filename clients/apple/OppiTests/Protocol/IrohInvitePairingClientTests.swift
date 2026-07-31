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

    @Test func preparesInviteRelaysBeforeOpeningPairingFrame() async throws {
        let response = try IrohFrameCodec.encode(header: [
            "v": 1,
            "kind": "pairResponse",
            "ok": true,
            "deviceToken": "dt_iroh",
        ])
        let preparation = RelayPreparationGate()
        let client = RealIrohInvitePairingClient(
            transport: RelayPreparationCheckingTransport(
                response: response,
                preparation: preparation
            ),
            relayPreparer: { _ in await preparation.markPrepared() }
        )

        let result = await client.pairDevice(
            pairingToken: "pt_invite",
            iroh: irohTransport(),
            deviceName: nil
        )

        #expect(result == .success(deviceToken: "dt_iroh"))
    }

    @Test func preparesRelaysBeforeTheReadOnlyPairingALPNProbe() async throws {
        let preparation = RelayPreparationGate()
        let provider = RelayPreparationProbeProvider(preparation: preparation)
        let manager = IrohConnectionManager(iroh: irohTransport(), provider: provider)
        let probe = RealIrohInvitePairingReachabilityProbe(
            relayPreparer: { _ in await preparation.markPrepared() },
            managerProvider: { _ in manager }
        )

        try await probe.probe(iroh: irohTransport())

        #expect(await provider.alpns() == ["oppi/pair/1"])
        await manager.shutdown()
    }

    @Test func relayPreparationFailureIsReportedBeforePairingDispatch() async {
        let client = RealIrohInvitePairingClient(
            transport: FailingPairingTransport(),
            relayPreparer: { _ in
                throw IrohTransportError.unavailable("https://private-relay.example.test failed")
            }
        )

        let result = await client.pairDevice(
            pairingToken: "pt_invite",
            iroh: irohTransport(),
            deviceName: nil
        )

        #expect(result == .transportUnavailable("Unable to prepare Iroh transport"))
    }

    @Test func pairingExchangeFailureAfterDispatchIsReportedAsResponseUnavailable() async {
        let client = RealIrohInvitePairingClient(
            transport: FailingPairingTransport(),
            relayPreparer: { _ in }
        )

        let result = await client.pairDevice(
            pairingToken: "pt_invite",
            iroh: irohTransport(),
            deviceName: nil
        )

        #expect(result == .responseUnavailable)
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

private actor RelayPreparationGate {
    private var prepared = false

    func markPrepared() {
        prepared = true
    }

    func isPrepared() -> Bool {
        prepared
    }
}

private actor RelayPreparationCheckingTransport: IrohFrameTransport {
    private let response: Data
    private let preparation: RelayPreparationGate

    init(response: Data, preparation: RelayPreparationGate) {
        self.response = response
        self.preparation = preparation
    }

    func exchange(
        iroh: IrohServerTransport,
        alpn: String,
        requestFrame: Data,
        maxResponseBytes: UInt32
    ) async throws -> Data {
        guard await preparation.isPrepared() else {
            throw IrohTransportError.unavailable("relay map was not prepared")
        }
        return response
    }
}

private actor RelayPreparationProbeProvider: IrohConnectionProviding {
    private let preparation: RelayPreparationGate
    private var seenALPNs: [String] = []

    init(preparation: RelayPreparationGate) {
        self.preparation = preparation
    }

    func openStream(alpn: String) async throws -> any IrohByteStream {
        guard await preparation.isPrepared() else {
            throw IrohTransportError.unavailable("relay map was not prepared")
        }
        seenALPNs.append(alpn)
        return PairingProbeStream()
    }

    func suspendConnections() async {}
    func shutdown() async {}

    func alpns() -> [String] {
        seenALPNs
    }
}

private actor PairingProbeStream: IrohByteStream {
    func write(_ data: Data) async throws {}
    func finishWriting() async throws {}
    func read(maxBytes: UInt32) async throws -> Data { Data() }
    func reset(errorCode: UInt64) async {}
}

private actor FailingPairingTransport: IrohFrameTransport {
    func exchange(
        iroh: IrohServerTransport,
        alpn: String,
        requestFrame: Data,
        maxResponseBytes: UInt32
    ) async throws -> Data {
        throw IrohTransportError.unavailable("response lost")
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
