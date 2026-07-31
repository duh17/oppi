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
        irohRelayPreparer: @Sendable (IrohServerTransport) async throws -> Void = { metadata in
            try await IrohTransportRegistry.shared.prepare(iroh: metadata)
        },
        httpAvailabilityProbe: @Sendable (APIClient) async throws -> Void = { client in
            guard try await client.health() else {
                throw IrohTransportError.protocolViolation("Server health probe did not succeed")
            }
        },
        irohAvailabilityProbe: @Sendable (IrohConnectionManager) async throws -> Void = { manager in
            _ = try await manager.selectedPathEvidence()
        },
        operation: @Sendable (APIClient) async throws -> Result
    ) async throws -> Result {
        let credentials = server.credentials
        let discoveredLANCandidate: LANDiscoveredEndpoint? = if server.effectiveRouteMode.requestedTransports.contains(.https) {
            await lanEndpointProvider(credentials)
        } else {
            nil
        }
        let verifiedLANEndpoint: LANDiscoveredEndpoint?
        if let discoveredLANCandidate,
           let selection = LANEndpointSelection.select(
               credentials: credentials,
               discoveredEndpoint: discoveredLANCandidate
           ), selection.transportPath == .lan,
           await lanReachabilityProbe(selection, credentials) {
            verifiedLANEndpoint = discoveredLANCandidate
        } else {
            verifiedLANEndpoint = nil
        }

        let candidates = try ServerTransportPlanResolver.candidates(
            credentials: credentials,
            mode: server.effectiveRouteMode,
            discoveredLANEndpoint: verifiedLANEndpoint
        )

        for candidate in candidates {
            switch candidate {
            case .http(let selection):
                let client = makeHTTPClient(for: server, selection: selection)
                do {
                    try await httpAvailabilityProbe(client)
                } catch {
                    guard mayAdvance(after: error) else { throw error }
                    continue
                }

                // The operation starts only after the read-only availability
                // probe succeeds. Never catch and route around this call: a
                // mutation can have reached the server before its error returns.
                return try await operation(client)

            case .iroh(let metadata):
                do {
                    try await irohRelayPreparer(metadata)
                } catch {
                    guard mayAdvance(after: error) else { throw error }
                    continue
                }

                let manager = managerFactory(metadata)
                var operationStarted = false
                do {
                    try await irohAvailabilityProbe(manager)
                    let baseURL = try await manager.startProxy(token: server.token)
                    let client = APIClient(baseURL: baseURL, token: server.token)
                    operationStarted = true
                    let result = try await operation(client)
                    await manager.shutdown()
                    return result
                } catch {
                    await manager.shutdown()
                    guard !operationStarted, mayAdvance(after: error) else { throw error }
                }
            }
        }

        throw IrohTransportError.unavailable("No authorized server transport is reachable")
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

    private static func makeHTTPClient(
        for server: PairedServer,
        selection: EndpointSelection
    ) -> APIClient {
        APIClient(environment: OppiClientEnvironment(
            baseURL: selection.baseURL,
            bearerToken: server.token,
            pinnedCertificateFingerprint: server.tlsCertFingerprint,
            tlsServerName: selection.tlsServerName
        ))
    }

    private static func mayAdvance(after error: Error) -> Bool {
        if APIClientAvailabilityFailure(error: error) != nil {
            return true
        }
        if let error = error as? IrohTransportError {
            return error.isFallbackEligible
        }
        return false
    }
}
