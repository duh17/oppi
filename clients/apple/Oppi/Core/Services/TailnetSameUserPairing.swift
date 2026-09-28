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
        proxy: () -> TailnetSOCKSProxy?
    ) async throws {
        let deadline = ContinuousClock.now + timeout
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
            if ContinuousClock.now >= deadline {
                throw Failure.proxyNotReady
            }
            try await Task.sleep(for: .milliseconds(20))
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
