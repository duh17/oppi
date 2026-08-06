import Foundation
import Testing
@testable import Oppi

@MainActor
@Suite("Credential-aware routing", .serialized)
struct CredentialAwareRoutingTests {
    @Test func bindingMissingNarrowsIrohAndFreshRecoveryUsesHTTPS() async throws {
        defer { TestURLProtocol.handler = nil }
        let connection = ServerConnection()
        connection._refreshAfterAutomaticIrohRecoveryForTesting = {}
        let credentials = dualCredentials()
        let loopbackURL = try #require(URL(string: "http://127.0.0.1:42100"))
        var pairedAvailable = false
        var pairedBootstraps = 0
        var irohDials = 0
        var persistedGrants: [CredentialTransportGrant] = []

        #expect(await connection.configureForUse(
            credentials: credentials,
            apiClientFactory: testAPIClient,
            serverInfoBootstrap: { client, _ in
                if await client.baseURL.host == "paired.example.test" {
                    pairedBootstraps += 1
                    if !pairedAvailable { throw URLError(.cannotConnectToHost) }
                }
                return serverInfo()
            },
            irohProxyFactory: { _, _ in
                irohDials += 1
                return (nil, loopbackURL)
            },
            credentialGrantDidChange: { persistedGrants.append($0) }
        ))
        #expect(connection.transportPath == .iroh)

        TestURLProtocol.handler = { request in
            let response = try #require(HTTPURLResponse(
                url: request.url ?? loopbackURL,
                statusCode: 403,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            ))
            return (Data(#"{"error":"forbidden","code":"binding_missing"}"#.utf8), response)
        }
        pairedAvailable = true

        await #expect(throws: APIError.self) {
            _ = try await connection.apiClient?.me()
        }
        await connection.awaitPersistentHealthRecoveryForTesting()

        #expect(persistedGrants == [.http])
        #expect(connection.credentials?.credentialGrant == .http)
        #expect(connection.transportPath == .paired)
        #expect(connection.apiClient != nil)
        #expect(pairedBootstraps == 2)
        #expect(irohDials == 1, "The narrowed credential must not redial Iroh")
        #expect(connection.canAutomaticallyRetryInitialTransport)
    }

    @Test func unknownTokenAndIntegrityFailuresRemainFailClosed() async throws {
        defer { TestURLProtocol.handler = nil }
        let connection = ServerConnection()
        let credentials = dualCredentials()
        let loopbackURL = try #require(URL(string: "http://127.0.0.1:42101"))
        var pairedAvailable = false
        var pairedBootstraps = 0

        #expect(await connection.configureForUse(
            credentials: credentials,
            apiClientFactory: testAPIClient,
            serverInfoBootstrap: { client, _ in
                if await client.baseURL.host == "paired.example.test" {
                    pairedBootstraps += 1
                    if !pairedAvailable { throw URLError(.cannotConnectToHost) }
                }
                return serverInfo()
            },
            irohProxyFactory: { _, _ in (nil, loopbackURL) }
        ))

        TestURLProtocol.handler = { request in
            let response = try #require(HTTPURLResponse(
                url: request.url ?? loopbackURL,
                statusCode: 401,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            ))
            return (Data(#"{"error":"unauthorized","code":"unknown_token"}"#.utf8), response)
        }

        await #expect(throws: APIError.self) {
            _ = try await connection.apiClient?.me()
        }
        for _ in 0..<100 where connection.apiClient != nil {
            await Task.yield()
        }

        #expect(connection.apiClient == nil)
        #expect(!connection.canAutomaticallyRetryInitialTransport)
        await connection.handlePersistentStreamHealthFailure(.reconnectThreshold(attempt: 7))
        #expect(pairedBootstraps == 1, "Fail-closed credentials must not recover automatically")

        pairedAvailable = true
        #expect(await connection.reconfigureForExplicitRetry(
            credentials: credentials,
            apiClientFactory: testAPIClient,
            serverInfoBootstrap: { client, _ in
                if await client.baseURL.host == "paired.example.test" {
                    pairedBootstraps += 1
                    return serverInfo()
                }
                throw IrohTransportError.authentication("integrity failure")
            },
            irohProxyFactory: { _, _ in
                throw IrohTransportError.authentication("integrity failure")
            }
        ))
        #expect(connection.transportPath == .paired)
        #expect(pairedBootstraps == 2)
    }

    private func dualCredentials() -> ServerCredentials {
        ServerCredentials(
            host: "paired.example.test",
            port: 443,
            token: "dt_dual",
            name: "Credential Server",
            scheme: .https,
            serverFingerprint: "sha256:credential-server",
            transports: ServerTransports(
                preference: .irohPreferred,
                iroh: IrohServerTransport(
                    version: 2,
                    nodeId: "signed-node",
                    alpns: [IrohTunnelProtocol.alpn],
                    addressMode: .nodeId,
                    ticket: nil
                ),
                http: HTTPServerTransport(
                    host: "paired.example.test",
                    port: 443,
                    scheme: .https,
                    tlsCertFingerprint: nil
                )
            ),
            credentialGrant: [.http, .iroh]
        )
    }

    private func testAPIClient(
        environment: OppiClientEnvironment,
        availabilityObserver: APIClientAvailabilityObserver?
    ) -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestURLProtocol.self]
        return APIClient(
            environment: environment,
            configuration: configuration,
            availabilityObserver: availabilityObserver
        )
    }

    private func serverInfo() -> ServerInfo {
        ServerInfo(
            name: "Credential Server",
            version: "1",
            uptime: 1,
            os: "darwin",
            arch: "arm64",
            hostname: "test",
            nodeVersion: "22",
            piVersion: "1",
            configVersion: 1,
            identity: nil,
            runtimeUpdate: nil,
            uploadProtocol: nil,
            images: nil,
            capabilities: nil,
            stats: .init(
                workspaceCount: 0,
                activeSessionCount: 0,
                totalSessionCount: 0,
                skillCount: 0,
                modelCount: 0
            )
        )
    }
}
