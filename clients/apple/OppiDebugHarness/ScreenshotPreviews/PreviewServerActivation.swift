#if DEBUG
import Foundation

extension ConnectionCoordinator {
    /// Make `server` the active server of a screenshot preview the way a cold
    /// launch does: its shell (stores, active selection) now, then its transport
    /// through `ensureConnectionReady`, with `/server/info` answered in process
    /// and no wait for Bonjour. `apiClient` becomes the connection's client and
    /// answers its requests; without one the connection gets a real client for
    /// `server.host`. Give preview servers a reserved `.invalid` host (RFC 6761):
    /// it never resolves, so those requests fail as unreachable instead of
    /// reaching a real machine, whose refusal would fail the route closed.
    @discardableResult
    func activatePreviewServer(_ server: PairedServer, apiClient: APIClient? = nil) -> ServerConnection {
        _serverInfoBootstrapForTesting = { _, _ in Self.previewServerInfo }
        _initialLANEndpointForTesting = { _ in nil }
        if let apiClient {
            _apiClientFactoryForTesting = { _, _ in apiClient }
        }
        let connection = activatePairedServerShell(server)
        if let apiClient {
            connection.setAPIClientForTesting(apiClient)
        }
        Task { await self.ensureConnectionReady(for: server) }
        return connection
    }

    private static let previewServerInfo = ServerInfo(
        name: "Preview",
        version: ServerReleaseVersion.minimumSupported,
        uptime: 1,
        os: "darwin",
        arch: "arm64",
        hostname: "preview.invalid",
        nodeVersion: "22",
        piVersion: "1",
        configVersion: 1,
        identity: nil,
        uploadProtocol: nil,
        images: nil,
        capabilities: .init(
            sessionStream: .init(version: 1),
            dictationStream: nil,
            appEventStream: nil,
            extensionNativeUI: nil
        ),
        stats: .init(
            workspaceCount: 0,
            activeSessionCount: 0,
            totalSessionCount: 0,
            skillCount: 0,
            modelCount: 0
        )
    )
}
#endif
