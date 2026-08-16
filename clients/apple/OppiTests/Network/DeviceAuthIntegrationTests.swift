import Foundation
import Testing
@testable import Oppi

// MARK: - Fakes

private struct StubMigrationClient: DeviceAuthMigrationTransport {
    let credential: DeviceCredential?
    let error: DeviceAuthError?
    let pairResponse: PairDeviceResponse?

    init(
        credential: DeviceCredential?,
        error: DeviceAuthError?,
        pairResponse: PairDeviceResponse? = nil
    ) {
        self.credential = credential
        self.error = error
        self.pairResponse = pairResponse
    }

    func migrateDevice(
        deviceName: String?,
        devicePublicKey: DevicePublicKey
    ) async throws -> PairDeviceResponse {
        if let error { throw error }
        if let pairResponse { return pairResponse }
        let credential = try #require(credential)
        return PairDeviceResponse(
            deviceId: credential.deviceId,
            accessToken: credential.accessToken,
            expiresAt: credential.expiresAt,
            refreshChallenge: credential.refreshChallenge
        )
    }
}

private actor RecordingDeviceAuthTransport: DeviceAuthTransport {
    private var challengeCount = 0
    private var refreshCalls: [(nonce: String, signature: String)] = []
    let nextToken: String
    let refreshError: DeviceAuthError?

    init(nextToken: String, refreshError: DeviceAuthError? = nil) {
        self.nextToken = nextToken
        self.refreshError = refreshError
    }

    func requestChallenge(deviceId: String) async throws -> DeviceAuthChallenge {
        challengeCount += 1
        return DeviceAuthChallenge(nonce: "n\(challengeCount)", audience: "oppi:refresh:v1", expiresAt: 2_000_000)
    }

    func refresh(
        deviceId: String,
        nonce: String,
        signature: String
    ) async throws -> DeviceAuthRefreshResult {
        refreshCalls.append((nonce, signature))
        if let refreshError { throw refreshError }
        return DeviceAuthRefreshResult(accessToken: nextToken, expiresAt: 2_000_000, refreshChallenge: nil)
    }

    func refreshCallCount() -> Int { refreshCalls.count }
}

// MARK: - Migration

@MainActor
@Suite("DeviceAuthMigrationService")
struct DeviceAuthMigrationServiceTests {
    private func legacyServer() throws -> PairedServer {
        let credentials = ServerCredentials(
            host: "pairing.example.test",
            port: 443,
            token: "dt_legacy",
            name: "Server",
            scheme: .https,
            serverFingerprint: "sha256:abcdef1234567890"
        )
        return try #require(PairedServer(from: credentials))
    }

    @Test func migratesLegacyDtOnceAndPersistsReplacement() async throws {
        var persisted: [PairedServer] = []
        let credential = DeviceCredential(
            deviceId: "dev_1",
            accessToken: "at_1",
            expiresAt: 2_000_000,
            refreshChallenge: nil
        )
        let service = DeviceAuthMigrationService(
            deviceKeyProvider: { InMemoryP256DeviceKey() },
            clientFactory: { _ in StubMigrationClient(credential: credential, error: nil) },
            persist: { persisted.append($0) }
        )

        let migrated = await service.migrateIfNeeded(try legacyServer())

        #expect(migrated.deviceCredential?.deviceId == "dev_1")
        #expect(migrated.deviceCredential?.accessToken == "at_1")
        #expect(migrated.token == "")
        #expect(persisted.count == 1)
        #expect(persisted.first?.deviceCredential?.deviceId == "dev_1")
    }

    @Test func skipsMigrationWhenAlreadyMigrated() async throws {
        let credentials = ServerCredentials(
            host: "pairing.example.test",
            port: 443,
            token: "",
            name: "Server",
            scheme: .https,
            serverFingerprint: "sha256:abcdef1234567890",
            deviceCredential: DeviceCredential(
                deviceId: "dev_1",
                accessToken: "at_1",
                expiresAt: 2_000_000,
                refreshChallenge: nil
            )
        )
        let server = try #require(PairedServer(from: credentials))
        var persistCalls = 0
        let service = DeviceAuthMigrationService(persist: { _ in persistCalls += 1 })

        let result = await service.migrateIfNeeded(server)

        #expect(result.deviceCredential?.deviceId == "dev_1")
        #expect(persistCalls == 0)
    }

    @Test func dtOnlyMigrateResponseLeavesStoredTokenUsable() async throws {
        var persistCalls = 0
        let service = DeviceAuthMigrationService(
            deviceKeyProvider: { InMemoryP256DeviceKey() },
            clientFactory: { _ in
                StubMigrationClient(
                    credential: nil,
                    error: nil,
                    pairResponse: PairDeviceResponse(
                        deviceId: "",
                        accessToken: "",
                        expiresAt: 0,
                        deviceToken: "dt_old_server"
                    )
                )
            },
            persist: { _ in persistCalls += 1 }
        )

        let result = await service.migrateIfNeeded(try legacyServer())

        #expect(result.token == "dt_legacy")
        #expect(result.deviceCredential == nil)
        #expect(persistCalls == 0)
    }

    @Test func migrationFailureLeavesLegacyTokenUsable() async throws {
        var persistCalls = 0
        let service = DeviceAuthMigrationService(
            deviceKeyProvider: { InMemoryP256DeviceKey() },
            clientFactory: { _ in StubMigrationClient(credential: nil, error: .refreshRejected(code: "revoked")) },
            persist: { _ in persistCalls += 1 }
        )

        let result = await service.migrateIfNeeded(try legacyServer())

        // The legacy dt_ remains usable (compat window) — migration must not strand.
        #expect(result.token == "dt_legacy")
        #expect(result.deviceCredential == nil)
        #expect(persistCalls == 0)
    }

    @Test func persistenceFailureRetainsLegacyTokenAndDoesNotInstallReplacement() async throws {
        // The server has already issued the replacement; only the durable
        // client write fails. Migration must retain `dt_` and must not clear the
        // static token or install the device credential.
        let credential = DeviceCredential(
            deviceId: "dev_1",
            accessToken: "at_1",
            expiresAt: 2_000_000,
            refreshChallenge: nil
        )
        let service = DeviceAuthMigrationService(
            deviceKeyProvider: { InMemoryP256DeviceKey() },
            clientFactory: { _ in StubMigrationClient(credential: credential, error: nil) },
            persist: { _ in throw KeychainCredentialMergeError.writeFailed(errSecIO) }
        )

        let result = await service.migrateIfNeeded(try legacyServer())

        #expect(result.token == "dt_legacy")
        #expect(result.deviceCredential == nil)
    }
}

// MARK: - APIClient 401 refresh

@Suite("APIClient device-key auth")
struct DeviceAuthAPIClientTests {
    private func makeClient(token: String) -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let environment = OppiClientEnvironment(
            baseURL: URL(string: "http://localhost:7749")!,
            bearerToken: token
        )
        return APIClient(environment: environment, configuration: config)
    }

    private func attachSession(to client: APIClient, transport: any DeviceAuthTransport) {
        let session = DeviceAuthSession(
            deviceId: "dev_1",
            key: InMemoryP256DeviceKey(),
            accessToken: "at_expired",
            expiresAt: Date().addingTimeInterval(600),
            transport: transport
        )
        client.attachAuthSession(session)
    }

    @Test func refreshesOnceAndRetriesOn401() async throws {
        let client = makeClient(token: "at_expired")
        defer { MockURLProtocol.handler = nil }
        let transport = RecordingDeviceAuthTransport(nextToken: "at_fresh")
        attachSession(to: client, transport: transport)

        var seenTokens: [String] = []
        MockURLProtocol.handler = { request in
            let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
            seenTokens.append(auth)
            if auth == "Bearer at_expired" {
                return (
                    Data(#"{"error":"Unauthorized"}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
                )
            }
            return (
                Data(#"{"user":"u1","name":"Test"}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }

        let user = try await client.me()

        #expect(user.user == "u1")
        #expect(seenTokens == ["Bearer at_expired", "Bearer at_fresh"])
        #expect(await transport.refreshCallCount() == 1)
    }

    @Test func failsClosedWithoutLoopWhenRefreshRejected() async throws {
        let client = makeClient(token: "at_expired")
        defer { MockURLProtocol.handler = nil }
        let transport = RecordingDeviceAuthTransport(
            nextToken: "at_fresh",
            refreshError: .refreshRejected(code: "revoked")
        )
        attachSession(to: client, transport: transport)

        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            return (
                Data(#"{"error":"Unauthorized"}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            )
        }

        do {
            _ = try await client.me()
            Issue.record("expected refresh rejection to fail closed")
        } catch let error as DeviceAuthError {
            #expect(error == .refreshRejected(code: "revoked"))
        }

        #expect(requestCount == 1)
        #expect(await transport.refreshCallCount() == 1)
    }
}

// MARK: - Production APIClient ↔ DeviceAuthSession wiring (self-deadlock guard)

private struct TestTimeoutError: Error {}

/// Run `body` with a hard deadline. A deadlocked refresh would suspend forever,
/// so the deadline converts a hang into a thrown `TestTimeoutError`.
private func withDeadline<T: Sendable>(
    seconds: Double,
    _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TestTimeoutError()
        }
        guard let result = try await group.next() else { throw TestTimeoutError() }
        group.cancelAll()
        return result
    }
}

@Suite("APIClient production device-key refresh wiring")
struct DeviceAuthSelfReferentialWiringTests {
    /// Builds the exact production wiring: the `DeviceAuthSession`'s transport is
    /// the SAME `APIClient` that owns it, and the static bearer is empty (a
    /// device-key-migrated server). This is the shape that previously deadlocked.
    private func makeSelfReferentialClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let environment = OppiClientEnvironment(
            baseURL: URL(string: "http://localhost:7749")!,
            bearerToken: ""
        )
        return APIClient(environment: environment, configuration: config)
    }

    @Test func refreshCompletesAnd401RetriesOnceThroughTheSameClient() async throws {
        let client = makeSelfReferentialClient()
        defer { MockURLProtocol.handler = nil }

        let session = DeviceAuthSession(
            deviceId: "dev_1",
            key: InMemoryP256DeviceKey(),
            accessToken: "at_expired",
            expiresAt: Date().addingTimeInterval(600),
            transport: client
        )
        client.attachAuthSession(session)

        var meRequests: [String] = []
        var challengeAuthorization: [String?] = []
        var refreshAuthorization: [String?] = []
        MockURLProtocol.handler = { request in
            let auth = request.value(forHTTPHeaderField: "Authorization")
            switch request.url?.path {
            case "/auth/challenge":
                challengeAuthorization.append(auth)
                let body = #"{"nonce":"n1","audience":"oppi:refresh:v1","expiresAt":4102444800000}"#
                return (
                    Data(body.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            case "/auth/refresh":
                refreshAuthorization.append(auth)
                let body = #"{"accessToken":"at_fresh","expiresAt":4102444800000,"refreshChallenge":null}"#
                return (
                    Data(body.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            default:
                meRequests.append(auth ?? "")
                if auth == "Bearer at_expired" {
                    return (
                        Data(#"{"error":"Unauthorized"}"#.utf8),
                        HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
                    )
                }
                return (
                    Data(#"{"user":"u1","name":"Test"}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            }
        }

        // The deadline proves the refresh does not deadlock: with the old
        // `authorizedToken()` re-entry this would suspend forever on its own
        // in-flight refresh and the deadline task would win.
        let user = try await withDeadline(seconds: 5) {
            try await client.me()
        }

        #expect(user.user == "u1")
        // /me was attempted once with the stale bearer, then retried once.
        #expect(meRequests == ["Bearer at_expired", "Bearer at_fresh"])
        // Challenge/refresh crossed the network listener with NO outer bearer
        // (empty static token after migration) — never the session's own token.
        #expect(challengeAuthorization == [nil])
        #expect(refreshAuthorization == [nil])
    }
}

// MARK: - Codable compatibility

@Suite("Device credential persistence")
struct DeviceCredentialCodableTests {
    @Test func oldRecordWithoutDeviceCredentialDecodesAsLegacy() throws {
        let credentials = ServerCredentials(
            host: "pairing.example.test",
            port: 443,
            token: "dt_legacy",
            name: "Server",
            scheme: .https,
            serverFingerprint: "sha256:abcdef1234567890"
        )
        let server = try #require(PairedServer(from: credentials))
        #expect(server.deviceCredential == nil)

        let data = try JSONEncoder().encode(server)
        let decoded = try JSONDecoder().decode(PairedServer.self, from: data)

        #expect(decoded.deviceCredential == nil)
        #expect(decoded.token == "dt_legacy")
    }

    @Test func newRecordWithDeviceCredentialRoundTrips() throws {
        let credentials = ServerCredentials(
            host: "pairing.example.test",
            port: 443,
            token: "",
            name: "Server",
            scheme: .https,
            serverFingerprint: "sha256:abcdef1234567890",
            deviceCredential: DeviceCredential(
                deviceId: "dev_1",
                accessToken: "at_1",
                expiresAt: 2_000_000,
                refreshChallenge: DeviceAuthChallenge(nonce: "n", audience: "oppi:refresh:v1", expiresAt: 2_000_060)
            )
        )
        let server = try #require(PairedServer(from: credentials))

        let data = try JSONEncoder().encode(server)
        let decoded = try JSONDecoder().decode(PairedServer.self, from: data)

        #expect(decoded.deviceCredential?.deviceId == "dev_1")
        #expect(decoded.deviceCredential?.accessToken == "at_1")
    }
}
