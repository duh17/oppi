import Foundation

/// Same-Tailscale-user one-tap pairing: probe a peer MagicDNS name, mint an
/// invite, then enroll through the existing `/pair` mutation.
@MainActor
enum TailnetSameUserPairing {
    /// Config-default Oppi port, then HTTPS.
    static let probePorts = [7749, 443]

    enum Failure: Error, Equatable {
        case nodeNotRunning
        case proxyNotReady
        case missingDNSName
        case unreachable
        case invalidInvite
        case pairingFailed(String)
    }

    static func requireRunning(_ state: TailnetNodeState) throws {
        guard state == .running else { throw Failure.nodeNotRunning }
    }

    static func probeURLs(dnsName: String) -> [URL] {
        let host = dnsName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return [] }
        return probePorts.compactMap { URL(string: "https://\(host):\($0)") }
    }

    /// SOCKS is snapshotted when a URLSession is created. `.running` is not
    /// enough: `publishRoute` can still be in flight. Pass the current-generation
    /// proxy after `waitForCurrentGenerationProxy`.
    static func makeBootstrapClient<Client>(
        nodeState: TailnetNodeState,
        proxy: TailnetSOCKSProxy?,
        baseURL: URL,
        makeClient: (URL) -> Client
    ) throws -> Client {
        try requireRunning(nodeState)
        guard proxy != nil else { throw Failure.proxyNotReady }
        return makeClient(baseURL)
    }

    /// Waits until this generation has a published SOCKS proxy. `.running` with
    /// a nil proxy keeps waiting; a generation change fails closed.
    static func waitForCurrentGenerationProxy(
        expectedGeneration: UInt64,
        timeout: Duration = .seconds(10),
        generation: () -> UInt64,
        nodeState: () -> TailnetNodeState,
        proxy: () -> TailnetSOCKSProxy?,
        now: () -> ContinuousClock.Instant = { .now },
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws {
        let deadline = now() + timeout
        while true {
            guard generation() == expectedGeneration else {
                throw Failure.nodeNotRunning
            }
            let state = nodeState()
            if case .failed = state {
                throw Failure.nodeNotRunning
            }
            if state == .running, proxy() != nil {
                return
            }
            if now() >= deadline {
                throw Failure.proxyNotReady
            }
            try await sleep(.milliseconds(20))
        }
    }

    static func firstHealthyProbeURL(
        dnsName: String,
        probe: (URL) async throws -> Bool
    ) async throws -> URL {
        let urls = probeURLs(dnsName: dnsName)
        guard !urls.isEmpty else { throw Failure.missingDNSName }
        var lastError: Error?
        for url in urls {
            do {
                if try await probe(url) { return url }
            } catch {
                lastError = error
            }
        }
        throw lastError ?? Failure.unreachable
    }
}

extension TailnetSameUserPairing {
    /// Classifies a peer from the same probe pairing uses. A certificate
    /// rejection on any port wins over a later refusal: something answered the
    /// handshake but not with a certificate this device trusts for the name.
    static func probeOutcome(
        dnsName: String,
        probe: (URL) async throws -> Bool
    ) async -> TailnetPeerProbe {
        guard ServerTLSTrustPolicy.isTailscaleHostname(dnsName) else { return .notReachable }
        var sawCertificateFailure = false
        do {
            _ = try await firstHealthyProbeURL(dnsName: dnsName) { url in
                do {
                    return try await probe(url)
                } catch {
                    if isCertificateFailure(error) { sawCertificateFailure = true }
                    throw error
                }
            }
            return .ready
        } catch {
            return sawCertificateFailure ? .needsCertificate : .notReachable
        }
    }

    /// Unauthenticated `GET /health` over the node's SOCKS route, 5 s per URL.
    static func health(at url: URL) async throws -> Bool {
        let client = try makeBootstrapClient(
            nodeState: TailnetNodeController.shared.state,
            proxy: TailnetTransportRoute.proxy,
            baseURL: url,
            makeClient: { APIClient(baseURL: $0, token: "") }
        )
        return try await client.health(timeoutInterval: 5)
    }

    /// Readiness needs an Oppi response, not merely a reachable web server.
    /// `server/src/server.ts` returns `{ok: true, protocol: 2}` at `/health`.
    /// System CA trust checks the original HTTPS hostname; redirects are refused.
    static func peerHealth(at url: URL) async throws -> Bool {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        TailnetTransportRoute.apply(to: configuration, proxy: TailnetTransportRoute.Snapshot.forHost(url.host).proxy)
        let session = URLSession(configuration: configuration, delegate: PeerHealthDelegate(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let request = URLRequest(url: url.appendingPathComponent("health"))
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let health = try? JSONDecoder().decode(PeerHealthResponse.self, from: data) else { return false }
        return health.ok && health.protocolVersion == 2
    }

    private struct PeerHealthResponse: Decodable {
        let ok: Bool
        let protocolVersion: Int

        enum CodingKeys: String, CodingKey {
            case ok
            case protocolVersion = "protocol"
        }
    }

    /// Probes every machine concurrently and reports each outcome as it lands.
    /// Cancelling the caller cancels the probes; their outcomes are dropped.
    static func probeOutcomes(
        dnsNames: [String],
        onOutcome: (String, TailnetPeerProbe) -> Void
    ) async {
        await withTaskGroup(of: (String, TailnetPeerProbe).self) { group in
            for dnsName in dnsNames {
                group.addTask {
                    let outcome = await TailnetSameUserPairing.probeOutcome(dnsName: dnsName) { @MainActor url in
                        try TailnetSameUserPairing.requireRunning(TailnetNodeController.shared.state)
                        guard TailnetTransportRoute.proxy != nil else { throw Failure.proxyNotReady }
                        return try await TailnetSameUserPairing.peerHealth(at: url)
                    }
                    return (dnsName, outcome)
                }
            }
            while let result = await group.next() {
                if Task.isCancelled { continue }
                onOutcome(result.0, result.1)
            }
        }
    }

    /// Only certificate verdicts. `secureConnectionFailed` is also what a reset
    /// or SOCKS failure can surface as, so it classifies with refused/timeout.
    static func isCertificateFailure(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
             .serverCertificateHasBadDate, .serverCertificateNotYetValid:
            return true
        default:
            return false
        }
    }
}

/// A health redirect cannot establish readiness at the machine being probed.
private final class PeerHealthDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

extension TailnetSameUserPairing.Failure: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .nodeNotRunning:
            return "Connect Tailscale first."
        case .proxyNotReady:
            return "Tailscale proxy is not ready."
        case .missingDNSName:
            return "This machine has no MagicDNS name."
        case .unreachable:
            return "Could not reach Oppi on this machine."
        case .invalidInvite:
            return "Server returned an invalid pairing invite."
        case .pairingFailed(let message):
            return message
        }
    }
}
