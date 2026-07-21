import Foundation

/// Canonical bearer header construction for every authenticated HTTP and
/// WebSocket request, including requests sent to the Iroh loopback proxy.
enum ServerAuthorization {
    static func headerValue(token: String) -> String {
        "Bearer \(token)"
    }

    static func apply(token: String, to request: inout URLRequest) {
        request.setValue(headerValue(token: token), forHTTPHeaderField: "Authorization")
    }
}

/// Builds a transport-aware API client for short-lived processes such as App
/// Intents. Iroh managers and their loopback listeners are always shut down
/// before the operation returns; normal app UI uses ConnectionCoordinator
/// ownership instead.
enum ServerTransportAPIClient {
    static func withClient<Result: Sendable>(
        for server: PairedServer,
        lanEndpointProvider: @Sendable (ServerCredentials) async -> LANDiscoveredEndpoint? = { credentials in
            await discoverLANCandidate(for: credentials)
        },
        lanReachabilityProbe: @Sendable (EndpointSelection, ServerCredentials) async -> Bool = { selection, credentials in
            await LANEndpointSelection.isReachable(selection, credentials: credentials)
        },
        managerFactory: @Sendable (IrohServerTransport) -> IrohConnectionManager = { metadata in
            IrohConnectionManager(iroh: metadata)
        },
        operation: @Sendable (APIClient) async throws -> Result
    ) async throws -> Result {
        let discoveredLANCandidate: LANDiscoveredEndpoint? = if server.credentials.transports.preference != .irohOnly {
            await lanEndpointProvider(server.credentials)
        } else {
            nil
        }
        let verifiedLANEndpoint: LANDiscoveredEndpoint?
        if let discoveredLANCandidate,
           let selection = LANEndpointSelection.select(
               credentials: server.credentials,
               discoveredEndpoint: discoveredLANCandidate
           ), selection.transportPath == .lan,
           await lanReachabilityProbe(selection, server.credentials) {
            verifiedLANEndpoint = discoveredLANCandidate
        } else {
            verifiedLANEndpoint = nil
        }
        let plan = try ServerTransportPlanResolver.resolve(
            credentials: server.credentials,
            discoveredLANEndpoint: verifiedLANEndpoint
        )

        switch plan {
        case .http(let selection):
            return try await withHTTPClient(
                for: server,
                selection: selection,
                operation: operation
            )

        case .iroh(let metadata):
            let manager = managerFactory(metadata)
            let baseURL: URL
            do {
                baseURL = try await manager.startProxy(token: server.token)
                // Establish reachability before invoking the operation. This
                // makes fallback safe even when the operation is mutating.
                _ = try await manager.selectedPathEvidence()
            } catch let error as IrohTransportError where error.isFallbackEligible {
                await manager.shutdown()
                guard server.credentials.transports.preference == .irohPreferred else {
                    throw error
                }
                let fallback = try ServerTransportPlanResolver.resolve(
                    credentials: server.credentials,
                    discoveredLANEndpoint: verifiedLANEndpoint,
                    suppressIroh: true
                )
                guard case .http(let selection) = fallback else { throw error }
                return try await withHTTPClient(
                    for: server,
                    selection: selection,
                    operation: operation
                )
            } catch {
                await manager.shutdown()
                throw error
            }

            do {
                let client = APIClient(baseURL: baseURL, token: server.token)
                let result = try await operation(client)
                await manager.shutdown()
                return result
            } catch {
                // The operation has started. Never replay it over HTTP when its
                // acknowledgement state may be unknown.
                await manager.shutdown()
                throw error
            }
        }
    }

    @MainActor
    private static func discoverLANCandidate(
        for credentials: ServerCredentials,
        timeout: Duration = .milliseconds(300)
    ) async -> LANDiscoveredEndpoint? {
        let discovery = LANDiscovery()
        discovery.start()
        defer { discovery.stop() }

        let startedAt = ContinuousClock.now
        while ContinuousClock.now - startedAt < timeout {
            if let endpoint = discovery.endpoints.first(where: { endpoint in
                LANEndpointSelection.select(
                    credentials: credentials,
                    discoveredEndpoint: endpoint
                )?.transportPath == .lan
            }) {
                return endpoint
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return nil
    }

    private static func withHTTPClient<Result: Sendable>(
        for server: PairedServer,
        selection: EndpointSelection,
        operation: @Sendable (APIClient) async throws -> Result
    ) async throws -> Result {
        let client = APIClient(environment: OppiClientEnvironment(
            baseURL: selection.baseURL,
            bearerToken: server.token,
            pinnedCertificateFingerprint: server.tlsCertFingerprint,
            tlsServerName: selection.tlsServerName
        ))
        return try await operation(client)
    }
}
