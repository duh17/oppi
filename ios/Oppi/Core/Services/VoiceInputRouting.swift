import Foundation

@MainActor
final class VoiceInputRouteResolver {
    struct RemoteProbeResult: Sendable {
        let reachable: Bool
        let durationMs: Int
        let cached: Bool
        let host: String
    }

    private struct RemoteProbeCache {
        let endpoint: URL
        let reachable: Bool
        let checkedAt: Date
    }

    private var remoteProbeCache: RemoteProbeCache?
    private let remoteProbeCacheTTL: TimeInterval

    init(remoteProbeCacheTTL: TimeInterval = 15) {
        self.remoteProbeCacheTTL = remoteProbeCacheTTL
    }

    func invalidate() {
        remoteProbeCache = nil
    }

    func updateRemoteEndpoint(_ url: URL?) {
        _ = url
        remoteProbeCache = nil
    }

    func resolveEngine(
        mode: VoiceInputManager.EngineMode,
        remoteEndpoint: URL?,
        fallback: VoiceInputManager.TranscriptionEngine
    ) async -> (engine: VoiceInputManager.TranscriptionEngine, probe: RemoteProbeResult?) {
        switch mode {
        case .onDevice:
            return (fallback, nil)
        case .remote:
            return (.remoteASR, nil)
        case .auto:
            guard let remoteEndpoint else {
                return (fallback, nil)
            }

            let probe = await probeRemoteReachability(endpoint: remoteEndpoint)
            return (probe.reachable ? .remoteASR : fallback, probe)
        }
    }

    func probeRemoteReachability(
        endpoint: URL,
        forceRefresh: Bool = false
    ) async -> RemoteProbeResult {
        if !forceRefresh,
           let cache = remoteProbeCache,
           cache.endpoint == endpoint,
           Date().timeIntervalSince(cache.checkedAt) < remoteProbeCacheTTL {
            return RemoteProbeResult(
                reachable: cache.reachable,
                durationMs: 0,
                cached: true,
                host: endpoint.host ?? "unknown"
            )
        }

        let probeStart = ContinuousClock.now
        let reachable = await Self.remoteEndpointReachable(endpoint)
        let durationMs = Self.elapsedMs(since: probeStart)

        remoteProbeCache = RemoteProbeCache(
            endpoint: endpoint,
            reachable: reachable,
            checkedAt: Date()
        )

        return RemoteProbeResult(
            reachable: reachable,
            durationMs: durationMs,
            cached: false,
            host: endpoint.host ?? "unknown"
        )
    }

    nonisolated private static func remoteEndpointReachable(_ endpoint: URL) async -> Bool {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 1.5

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.5
        config.timeoutIntervalForResource = 2
        config.waitsForConnectivity = false

        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }
            return httpResponse.statusCode < 500
        } catch {
            return false
        }
    }

    nonisolated private static func elapsedMs(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds * 1000
            + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }
}
