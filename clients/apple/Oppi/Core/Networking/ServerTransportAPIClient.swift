import Foundation

enum ServerAuthorization {
    static func headerValue(token: String) -> String { "Bearer \(token)" }

    static func apply(token: String, to request: inout URLRequest) {
        request.setValue(headerValue(token: token), forHTTPHeaderField: "Authorization")
    }

    static func resolvedToken(_ resolved: String?, fallback: String) -> String {
        DeviceAuthSession.resolvedToken(resolved, fallback: fallback)
    }
}

/// Builds the HTTPS client used by short-lived app intents and extensions.
enum ServerTransportAPIClient {
    static func withClient<Result: Sendable>(
        for server: PairedServer,
        lanEndpointProvider: @Sendable (ServerCredentials) async -> LANDiscoveredEndpoint? = { credentials in
            await discoverLANCandidate(for: credentials)
        },
        lanReachabilityProbe: @Sendable (EndpointSelection, ServerCredentials) async -> Bool = { selection, credentials in
            await LANEndpointSelection.isReachable(selection, credentials: credentials)
        },
        httpAvailabilityProbe: @Sendable (APIClient) async throws -> Void = { client in
            guard try await client.health() else { throw APIError.invalidResponse }
        },
        operation: @Sendable (APIClient) async throws -> Result
    ) async throws -> Result {
        let credentials = server.credentials
        let discovered = await lanEndpointProvider(credentials)
        let verified: LANDiscoveredEndpoint? = if let discovered,
                          let selection = LANEndpointSelection.select(credentials: credentials, discoveredEndpoint: discovered),
                          selection.transportPath == .lan,
                          await lanReachabilityProbe(selection, credentials) {
            discovered
        } else { nil }
        guard let selection = LANEndpointSelection.select(credentials: credentials, discoveredEndpoint: verified) else {
            throw APIError.server(status: 400, message: "Unsupported HTTPS server endpoint")
        }
        let client = try makeHTTPClient(for: server, selection: selection)
        try await httpAvailabilityProbe(client)
        return try await operation(client)
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
            if let endpoint = discovery.endpoints.first(where: {
                LANEndpointSelection.select(credentials: credentials, discoveredEndpoint: $0)?.transportPath == .lan
            }) { return endpoint }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return nil
    }

    private static func makeHTTPClient(for server: PairedServer, selection: EndpointSelection) throws -> APIClient {
        let client = APIClient(environment: OppiClientEnvironment(
            baseURL: selection.baseURL,
            bearerToken: server.credentials.effectiveAccessToken,
            pinnedCertificateFingerprint: server.tlsCertFingerprint,
            tlsServerName: selection.tlsServerName
        ))
        guard let credential = server.deviceCredential else { return client }
        let session = DeviceAuthSession(
            credential: credential,
            key: try DeviceKeyProvider.shared.loadOrCreate(),
            transport: client,
            onRefresh: { result in
                try? KeychainDeviceCredentialMerger.mergeRefresh(
                    serverId: server.id,
                    accessToken: result.accessToken,
                    expiresAt: Int64(result.expiresAt),
                    refreshChallenge: result.refreshChallenge
                )
            }
        )
        client.attachAuthSession(session)
        return client
    }
}
