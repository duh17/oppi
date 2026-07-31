#if IROH_LIVE_INTEROP
import Foundation
import Testing
@testable import Oppi

private final class IrohLiveInteropBundleMarker: NSObject {}

@Suite("Iroh live Apple/server interoperability")
struct IrohLiveInteropTests {
    private struct Fixture: Decodable {
        let pairingToken: String
        let iroh: IrohServerTransport
    }

    @Test("pairs and carries authenticated HTTP through IrohLib")
    func pairingAndHTTP() async throws {
        let encoded = try #require(
            Bundle(for: IrohLiveInteropBundleMarker.self)
                .object(forInfoDictionaryKey: "OPPIIrohLiveInvite") as? String
        )
        let inviteData = try #require(Data(base64Encoded: encoded))
        let fixture = try JSONDecoder().decode(Fixture.self, from: inviteData)

        let pairing = await RealIrohInvitePairingClient().pairDevice(
            pairingToken: fixture.pairingToken,
            iroh: fixture.iroh,
            deviceName: "oppi-apple-interop-test"
        )
        guard case .success(let token) = pairing else {
            Issue.record("Iroh pairing failed: \(pairing)")
            return
        }

        let manager = try await IrohTransportRegistry.shared.manager(for: fixture.iroh)
        let baseURL = try await manager.startProxy(token: token)
        var request = URLRequest(url: baseURL.appendingPathComponent("me"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        var warmLatenciesMs: [Double] = []
        var lastBody = Data()
        var lastResponse: URLResponse?
        for _ in 0..<30 {
            let startedAt = Date()
            let (body, response) = try await URLSession.shared.data(for: request)
            warmLatenciesMs.append(Date().timeIntervalSince(startedAt) * 1_000)
            lastBody = body
            lastResponse = response
        }
        let path = try await manager.selectedPathEvidence()
        await manager.shutdown()

        #expect((lastResponse as? HTTPURLResponse)?.statusCode == 200)
        let user = try JSONDecoder().decode(User.self, from: lastBody)
        #expect(user.user == "owner")
        let selectedPath = try #require(path)
        #expect(selectedPath.isRelay)
        #expect(!selectedPath.isIP)

        let sorted = warmLatenciesMs.sorted()
        let p50 = sorted[sorted.count / 2]
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        print(
            "IROH_SWIFT_RELAY_BENCHMARK samples=\(sorted.count) "
                + "warm_me_p50_ms=\(String(format: "%.2f", p50)) "
                + "warm_me_p95_ms=\(String(format: "%.2f", p95)) "
                + "path_rtt_ms=\(selectedPath.rttMs)"
        )
    }
}
#endif
