import Testing
import Foundation
@testable import Oppi

@Suite("ServerConnection Lifecycle")
@MainActor
struct ServerConnectionLifecycleTests {

    @Test func configureWithValidCredentials() {
        let conn = ServerConnection()
        let result = conn.configure(credentials: ServerCredentials(
            host: "192.168.1.10", port: 7749, token: "sk_abc", name: "Test"
        ))
        #expect(result == true)
        #expect(conn.apiClient != nil)
        #expect(conn.wsClient != nil)
        #expect(conn.credentials?.host == "192.168.1.10")
    }

    @Test func configureIrohOnlyUsesTransparentHTTPAndWebSocketClients() async throws {
        let conn = ServerConnection()
        let credentials = makeTestIrohOnlyCredentials()
        let localURL = try #require(URL(string: "http://127.0.0.1:41991"))
        let result = await conn.configureForUse(
            credentials: credentials,
            routeMode: .irohOnly,
            serverInfoBootstrap: successfulServerInfoBootstrap,
            irohProxyFactory: { _, _ in (nil, localURL) }
        )

        #expect(result)
        #expect(conn.transportPath == .iroh)
        #expect(conn.apiClient != nil)
        #expect(conn.wsClient != nil)
        #expect(conn.currentServerId == "sha256:iroh-server-fp")
        #expect(await conn.apiClient?.baseURL == localURL)
        #expect(conn.credentials?.baseURL == nil, "Loopback URL must not become persisted remote metadata")

        conn.setDiscoveredLANEndpoint(LANDiscoveredEndpoint(
            host: "192.168.1.42",
            port: 7749,
            serverFingerprintPrefix: "iroh-server-fp",
            tlsCertFingerprintPrefix: nil
        ))
        #expect(conn.transportPath == .iroh)
        #expect(await conn.apiClient?.baseURL == localURL)
    }

    @Test func automaticUsesVerifiedLANBeforeMalformedIroh() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials(
            iroh: IrohServerTransport(
                version: 99,
                nodeId: "",
                alpns: [IrohTunnelProtocol.alpn],
                addressMode: .ticket,
                ticket: nil
            )
        )
        conn.setDiscoveredLANEndpoint(LANDiscoveredEndpoint(
            host: "192.168.1.42",
            port: 7749,
            serverFingerprintPrefix: "preferred-server-fp",
            tlsCertFingerprintPrefix: "preferred-tls-fp"
        ))
        var proxyStarted = false

        let result = await conn.configureForUse(
            credentials: credentials,
            serverInfoBootstrap: successfulServerInfoBootstrap,
            irohProxyFactory: { _, _ in
                proxyStarted = true
                throw IrohTransportError.unavailable("must not start")
            }
        )

        #expect(result)
        #expect(!proxyStarted)
        #expect(conn.transportPath == .lan)
        #expect(await conn.apiClient?.baseURL.host == "192.168.1.42")
    }

    @Test func unavailableVerifiedLANContinuesToPairedHTTPSBeforeIroh() async {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        conn.setDiscoveredLANEndpoint(LANDiscoveredEndpoint(
            host: "192.168.1.42",
            port: 7749,
            serverFingerprintPrefix: "preferred-server-fp",
            tlsCertFingerprintPrefix: "preferred-tls-fp"
        ))
        var lanBootstraps = 0
        var irohDials = 0

        let configured = await conn.configureForUse(
            credentials: credentials,
            serverInfoBootstrap: { client, _ in
                if await client.baseURL.host == "192.168.1.42" {
                    lanBootstraps += 1
                    throw URLError(.cannotConnectToHost)
                }
                return successfulServerInfo()
            },
            irohProxyFactory: { _, _ in
                irohDials += 1
                throw IrohTransportError.unavailable("must not dial")
            }
        )

        #expect(configured)
        #expect(lanBootstraps == 1)
        #expect(irohDials == 0)
        #expect(conn.transportPath == .paired)
        #expect(await conn.apiClient?.baseURL.host == "preferred.tailnet.ts.net")
    }

    @Test func unavailableLANUsesSignedPairedHTTPSWithoutIrohDial() async {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        conn.setDiscoveredLANEndpoint(LANDiscoveredEndpoint(
            host: "192.168.1.42",
            port: 7749,
            serverFingerprintPrefix: "preferred-server-fp",
            tlsCertFingerprintPrefix: "preferred-tls-fp"
        ))
        var irohDials = 0

        let configured = await conn.configureForUse(
            credentials: credentials,
            serverInfoBootstrap: { client, _ in
                if await client.baseURL.host == "192.168.1.42" {
                    throw URLError(.notConnectedToInternet)
                }
                return successfulServerInfo()
            },
            irohProxyFactory: { _, _ in
                irohDials += 1
                throw IrohTransportError.unavailable("must not dial")
            }
        )

        #expect(configured)
        #expect(irohDials == 0)
        #expect(conn.transportPath == .paired)
        #expect(await conn.apiClient?.baseURL.host == "preferred.tailnet.ts.net")
    }

    @Test func pairedAvailabilityFailureUsesIrohAndTerminalIrohFailsClosed() async throws {
        let credentials = makeIrohPreferredCredentials()
        let localURL = try #require(URL(string: "http://127.0.0.1:42015"))
        let pairedUnavailable: ServerConnectionInfoBootstrap = { client, _ in
            if await client.baseURL.host == "preferred.tailnet.ts.net" {
                throw URLError(.cannotConnectToHost)
            }
            return successfulServerInfo()
        }
        let available = ServerConnection()

        let configured = await available.configureForUse(
            credentials: credentials,
            serverInfoBootstrap: pairedUnavailable,
            irohProxyFactory: { _, _ in (nil, localURL) }
        )

        #expect(configured)
        #expect(available.transportPath == .iroh)
        #expect(await available.apiClient?.baseURL == localURL)

        let terminal = ServerConnection()
        let rejected = await terminal.configureForUse(
            credentials: credentials,
            serverInfoBootstrap: pairedUnavailable,
            irohProxyFactory: { _, _ in
                throw IrohTransportError.authentication("token rejected")
            }
        )

        #expect(!rejected)
        #expect(terminal.apiClient == nil)
        #expect(terminal.wsClient == nil)
    }

    @Test func pairedFailureThenIrohReachabilityTimeoutExhaustsThePass() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let metadata = try #require(credentials.transports.iroh)
        let provider = GatedReachableEvidenceIrohProvider()
        let manager = IrohConnectionManager(iroh: metadata, provider: provider)
        let localURL = try #require(URL(string: "http://127.0.0.1:42010"))

        let configurationTask = Task { @MainActor in
            await conn.configureForUse(
                credentials: credentials,
                irohReachabilityTimeout: .milliseconds(20),
                serverInfoBootstrap: { client, _ in
                    if await client.baseURL.host == "preferred.tailnet.ts.net" {
                        throw URLError(.cannotConnectToHost)
                    }
                    return successfulServerInfo()
                },
                irohProxyFactory: { _, _ in (manager, localURL) }
            )
        }
        while !(await provider.evidenceIsWaiting) {
            await Task.yield()
        }

        let configured = await configurationTask.value

        #expect(!configured)
        #expect(conn.apiClient == nil)
        #expect(conn.wsClient == nil)
        #expect(await provider.suspendCount == 1, "A timed-out probe must discard the poisoned provider connection")
        await provider.releaseEvidence()
    }

    @Test func establishedIrohFailureExcludesRouteUntilExplicitRetryRebuilds() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let metadata = try #require(credentials.transports.iroh)
        let firstProvider = EstablishedStreamFailureRecoveryProvider()
        let replacementProvider = TrackingReachableIrohProvider()
        let firstManager = IrohConnectionManager(iroh: metadata, provider: firstProvider)
        let replacementManager = IrohConnectionManager(iroh: metadata, provider: replacementProvider)
        let firstURL = try #require(URL(string: "http://127.0.0.1:42037"))
        let replacementURL = try #require(URL(string: "http://127.0.0.1:42038"))
        var factoryCalls = 0

        let factory: @MainActor (IrohServerTransport, String) async throws -> (IrohConnectionManager?, URL) = { _, _ in
            factoryCalls += 1
            return factoryCalls == 1
                ? (firstManager, firstURL)
                : (replacementManager, replacementURL)
        }
        #expect(await conn.configureForUse(
            credentials: credentials,
            routeMode: .irohOnly,
            serverInfoBootstrap: successfulServerInfoBootstrap,
            irohProxyFactory: factory
        ))
        let originalAPIClient = conn.apiClient

        await firstProvider.failEstablishedStream()

        #expect(factoryCalls == 1, "The failed route is excluded for its recovery pass")
        #expect(await firstProvider.shutdownCount == 1)
        #expect(await firstProvider.suspendCount == 0)
        #expect(conn.apiClient == nil)

        #expect(await conn.reconfigureForExplicitRetry(
            credentials: credentials,
            routeMode: .irohOnly,
            serverInfoBootstrap: successfulServerInfoBootstrap,
            irohProxyFactory: factory
        ))
        #expect(factoryCalls == 2)
        #expect(conn.apiClient !== originalAPIClient)
        #expect(await conn.apiClient?.baseURL == replacementURL)
    }

    @Test func repeatedAutomaticRouteRecoveriesUseBackoffUntilAStreamReconnects() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let localURL = try #require(URL(string: "http://127.0.0.1:42039"))
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        var irohDials = 0
        conn._automaticIrohRecoveryNowForTesting = { now }
        conn._refreshAfterAutomaticIrohRecoveryForTesting = {}

        #expect(await conn.configureForUse(
            credentials: credentials,
            serverInfoBootstrap: successfulServerInfoBootstrap,
            irohProxyFactory: { _, _ in
                irohDials += 1
                return (nil, localURL)
            }
        ))

        await conn.handlePersistentStreamHealthFailure(.establishedStreamFailure)
        #expect(irohDials == 1)
        #expect(conn.transportPath == .iroh)

        await conn.handlePersistentStreamHealthFailure(.reconnectThreshold(attempt: 6))
        #expect(irohDials == 1, "A repeated failure inside the first cooldown must not select again")

        now = now.addingTimeInterval(1)
        await conn.handlePersistentStreamHealthFailure(.reconnectThreshold(attempt: 7))
        #expect(conn.transportPath == .paired)

        conn.setAppEventStreamTransportState(.connected)
        await conn.handlePersistentStreamHealthFailure(.establishedStreamFailure)
        #expect(irohDials == 2, "A proven stream reconnect resets automatic recovery backoff")
        #expect(conn.transportPath == .iroh)
    }

    @Test func automaticIrohRecoveryUsesFiveAttemptExponentialBudget() {
        #expect(ServerConnection.automaticIrohRecoveryMaximumAttempts == 5)
        #expect(ServerConnection.automaticIrohRecoveryBackoff(attempt: 1) == 1)
        #expect(ServerConnection.automaticIrohRecoveryBackoff(attempt: 2) == 2)
        #expect(ServerConnection.automaticIrohRecoveryBackoff(attempt: 3) == 4)
        #expect(ServerConnection.automaticIrohRecoveryBackoff(attempt: 4) == 8)
        #expect(ServerConnection.automaticIrohRecoveryBackoff(attempt: 5) == 16)
    }

    @Test func automaticRouteRecoveryStopsAfterFiveAttemptsUntilAStreamReconnects() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let localURL = try #require(URL(string: "http://127.0.0.1:42060"))
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        var irohDials = 0
        conn._automaticIrohRecoveryNowForTesting = { now }
        conn._refreshAfterAutomaticIrohRecoveryForTesting = {}
        let factory: @MainActor (IrohServerTransport, String) async throws -> (IrohConnectionManager?, URL) = { _, _ in
            irohDials += 1
            return (nil, localURL)
        }

        #expect(await conn.configureForUse(
            credentials: credentials,
            serverInfoBootstrap: successfulServerInfoBootstrap,
            irohProxyFactory: factory
        ))

        for (index, delay) in [0.0, 1.0, 2.0, 4.0, 8.0].enumerated() {
            if index > 0 {
                #expect(await conn.configureForUse(
                    credentials: credentials,
                    serverInfoBootstrap: successfulServerInfoBootstrap,
                    irohProxyFactory: factory
                ))
                #expect(conn.transportPath == .paired)
            }
            now = now.addingTimeInterval(delay)
            await conn.handlePersistentStreamHealthFailure(.establishedStreamFailure)
        }
        #expect(irohDials == 5, "Five automatic route selections should run")

        #expect(await conn.configureForUse(
            credentials: credentials,
            serverInfoBootstrap: successfulServerInfoBootstrap,
            irohProxyFactory: factory
        ))
        now = now.addingTimeInterval(16)
        await conn.handlePersistentStreamHealthFailure(.establishedStreamFailure)
        #expect(irohDials == 5, "The sixth automatic selection must remain blocked")

        conn.setAppEventStreamTransportState(.connected)
        await conn.handlePersistentStreamHealthFailure(.establishedStreamFailure)
        #expect(irohDials == 6, "A proven stream reconnect restores the automatic retry budget")
    }

    @Test func terminalFailureDuringExplicitIrohRebuildRemainsFailClosed() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let metadata = try #require(credentials.transports.iroh)
        let provider = EstablishedStreamFailureRecoveryProvider()
        let manager = IrohConnectionManager(iroh: metadata, provider: provider)
        let localURL = try #require(URL(string: "http://127.0.0.1:42048"))
        var factoryCalls = 0
        let factory: @MainActor (IrohServerTransport, String) async throws -> (IrohConnectionManager?, URL) = { _, _ in
            factoryCalls += 1
            if factoryCalls == 1 { return (manager, localURL) }
            throw IrohTransportError.authentication("peer rejected replacement")
        }

        #expect(await conn.configureForUse(
            credentials: credentials,
            routeMode: .irohOnly,
            serverInfoBootstrap: successfulServerInfoBootstrap,
            irohProxyFactory: factory
        ))

        await provider.failEstablishedStream()
        #expect(factoryCalls == 1)
        #expect(conn.apiClient == nil)

        let rejected = await conn.reconfigureForExplicitRetry(
            credentials: credentials,
            routeMode: .irohOnly,
            serverInfoBootstrap: successfulServerInfoBootstrap,
            irohProxyFactory: factory
        )
        #expect(!rejected)
        #expect(factoryCalls == 2)
        #expect(conn.apiClient == nil)
        #expect(conn.wsClient == nil)

        await conn.handlePersistentStreamHealthFailure(.reconnectThreshold(attempt: 7))
        #expect(factoryCalls == 2, "Terminal integrity failures must not enter automatic retry")
    }

    @Test func IrohOnlyEstablishedStreamFailureGoesOfflineUntilExplicitRetry() async throws {
        let conn = ServerConnection()
        let credentials = makeTestIrohOnlyCredentials()
        let metadata = try #require(credentials.transports.iroh)
        let firstProvider = EstablishedStreamFailureRecoveryProvider()
        let replacementProvider = TrackingReachableIrohProvider()
        let firstManager = IrohConnectionManager(iroh: metadata, provider: firstProvider)
        let replacementManager = IrohConnectionManager(iroh: metadata, provider: replacementProvider)
        let firstURL = try #require(URL(string: "http://127.0.0.1:42030"))
        let replacementURL = try #require(URL(string: "http://127.0.0.1:42043"))
        var factoryCalls = 0
        conn._refreshAfterAutomaticIrohRecoveryForTesting = {}

        #expect(await conn.configureForUse(
            credentials: credentials,
            routeMode: .irohOnly,
            serverInfoBootstrap: successfulServerInfoBootstrap,
            irohProxyFactory: { _, _ in
                factoryCalls += 1
                return factoryCalls == 1
                    ? (firstManager, firstURL)
                    : (replacementManager, replacementURL)
            }
        ))
        let originalAPIClient = conn.apiClient

        await firstProvider.failEstablishedStream()

        #expect(factoryCalls == 1)
        #expect(await firstProvider.shutdownCount == 1)
        #expect(conn.apiClient == nil)

        #expect(await conn.reconfigureForExplicitRetry(
            credentials: credentials,
            routeMode: .irohOnly,
            serverInfoBootstrap: successfulServerInfoBootstrap,
            irohProxyFactory: { _, _ in
                factoryCalls += 1
                return (replacementManager, replacementURL)
            }
        ))
        #expect(factoryCalls == 2)
        #expect(conn.transportPath == .iroh)
        #expect(conn.apiClient !== originalAPIClient)
        #expect(await conn.apiClient?.baseURL == replacementURL)
    }

    @Test func serverScopedIrohRetryLeavesOtherManagerUntouched() async throws {
        let firstConnection = ServerConnection()
        let secondConnection = ServerConnection()
        let firstCredentials = makeIrohPreferredCredentials()
        let secondCredentials = makeIrohPreferredCredentials()
        let firstMetadata = try #require(firstCredentials.transports.iroh)
        let secondMetadata = try #require(secondCredentials.transports.iroh)
        let firstProvider = EstablishedStreamFailureRecoveryProvider()
        let replacementProvider = TrackingReachableIrohProvider()
        let secondProvider = EstablishedStreamFailureRecoveryProvider()
        let firstManager = IrohConnectionManager(iroh: firstMetadata, provider: firstProvider)
        let replacementManager = IrohConnectionManager(iroh: firstMetadata, provider: replacementProvider)
        let secondManager = IrohConnectionManager(iroh: secondMetadata, provider: secondProvider)
        let firstURL = try #require(URL(string: "http://127.0.0.1:42035"))
        let replacementURL = try #require(URL(string: "http://127.0.0.1:42044"))
        let secondURL = try #require(URL(string: "http://127.0.0.1:42036"))
        var firstFactoryCalls = 0
        firstConnection._refreshAfterAutomaticIrohRecoveryForTesting = {}

        #expect(await firstConnection.configureForUse(
            credentials: firstCredentials,
            routeMode: .irohOnly,
            serverInfoBootstrap: successfulServerInfoBootstrap,
            irohProxyFactory: { _, _ in
                firstFactoryCalls += 1
                return firstFactoryCalls == 1
                    ? (firstManager, firstURL)
                    : (replacementManager, replacementURL)
            }
        ))
        #expect(await secondConnection.configureForUse(
            credentials: secondCredentials,
            routeMode: .irohOnly,
            serverInfoBootstrap: successfulServerInfoBootstrap,
            irohProxyFactory: { _, _ in (secondManager, secondURL) }
        ))
        let secondAPIClient = secondConnection.apiClient

        await firstProvider.failEstablishedStream()

        #expect(firstFactoryCalls == 1)
        #expect(await firstProvider.shutdownCount == 1)
        #expect(firstConnection.apiClient == nil)
        #expect(await firstConnection.reconfigureForExplicitRetry(
            credentials: firstCredentials,
            routeMode: .irohOnly,
            serverInfoBootstrap: successfulServerInfoBootstrap,
            irohProxyFactory: { _, _ in
                firstFactoryCalls += 1
                return (replacementManager, replacementURL)
            }
        ))
        #expect(firstFactoryCalls == 2)
        #expect(await firstConnection.apiClient?.baseURL == replacementURL)
        #expect(await secondProvider.suspendCount == 0)
        #expect(await secondProvider.shutdownCount == 0)
        #expect(secondConnection.apiClient === secondAPIClient)
        #expect(secondConnection.transportPath == .iroh)
    }

    @Test func activeIrohFailureRestoresPairedHTTPSEligibility() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let metadata = try #require(credentials.transports.iroh)
        let provider = EstablishedStreamFailureRecoveryProvider()
        let manager = IrohConnectionManager(iroh: metadata, provider: provider)
        let localURL = try #require(URL(string: "http://127.0.0.1:42014"))
        var pairedAvailable = false
        var factoryCalls = 0
        conn._refreshAfterAutomaticIrohRecoveryForTesting = {}

        #expect(await conn.configureForUse(
            credentials: credentials,
            serverInfoBootstrap: { client, _ in
                if await client.baseURL.host == "preferred.tailnet.ts.net", !pairedAvailable {
                    throw URLError(.cannotConnectToHost)
                }
                return successfulServerInfo()
            },
            irohProxyFactory: { _, _ in
                factoryCalls += 1
                return (manager, localURL)
            }
        ))
        #expect(conn.transportPath == .iroh)
        pairedAvailable = true

        await provider.failEstablishedStream()

        #expect(factoryCalls == 1, "The failed Iroh route is excluded for this pass")
        #expect(await provider.shutdownCount == 1)
        #expect(conn.transportPath == .paired)
        #expect(await conn.apiClient?.baseURL.host == "preferred.tailnet.ts.net")
    }

    @Test func pairedFailureUsesIrohAndLaterExplicitRetryRestoresPaired() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let localURL = try #require(URL(string: "http://127.0.0.1:41993"))
        var irohDials = 0
        conn._refreshAfterAutomaticIrohRecoveryForTesting = {}

        #expect(await conn.configureForUse(
            credentials: credentials,
            serverInfoBootstrap: successfulServerInfoBootstrap,
            irohProxyFactory: { _, _ in
                irohDials += 1
                return (nil, localURL)
            }
        ))
        #expect(conn.transportPath == .paired)

        await conn.handlePersistentStreamHealthFailure(.reconnectThreshold(attempt: 4))

        #expect(irohDials == 1)
        #expect(conn.transportPath == .iroh)
        #expect(await conn.apiClient?.baseURL == localURL)
        #expect(await conn.apiClient?.environment.pinnedCertificateFingerprint == nil)

        #expect(await conn.reconfigureForExplicitRetry(
            credentials: credentials,
            serverInfoBootstrap: successfulServerInfoBootstrap,
            irohProxyFactory: { _, _ in
                irohDials += 1
                throw IrohTransportError.unavailable("must not dial after paired recovers")
            }
        ))
        #expect(irohDials == 1)
        #expect(conn.transportPath == .paired)
    }

    @Test func unhealthyPairedRouteTriesIrohWithoutWaitingForForeground() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let localURL = try #require(URL(string: "http://127.0.0.1:42019"))
        var attempts = 0
        conn._refreshAfterAutomaticIrohRecoveryForTesting = {}

        #expect(await conn.configureForUse(
            credentials: credentials,
            serverInfoBootstrap: successfulServerInfoBootstrap,
            irohProxyFactory: { _, _ in
                attempts += 1
                return (nil, localURL)
            }
        ))
        #expect(conn.transportPath == .paired)

        await conn.handlePersistentStreamHealthFailure(.reconnectThreshold(attempt: 4))

        #expect(attempts == 1)
        #expect(conn.transportPath == .iroh)
        #expect(await conn.apiClient?.baseURL == localURL)
    }

    @Test func IrohPingTimeoutGoesOfflineUntilExplicitRetry() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let metadata = try #require(credentials.transports.iroh)
        let firstProvider = TrackingReachableIrohProvider()
        let replacementProvider = TrackingReachableIrohProvider()
        let firstManager = IrohConnectionManager(iroh: metadata, provider: firstProvider)
        let replacementManager = IrohConnectionManager(iroh: metadata, provider: replacementProvider)
        let firstURL = try #require(URL(string: "http://127.0.0.1:42020"))
        let replacementURL = try #require(URL(string: "http://127.0.0.1:42045"))
        var factoryCalls = 0
        conn._refreshAfterAutomaticIrohRecoveryForTesting = {}

        #expect(await conn.configureForUse(
            credentials: credentials,
            routeMode: .irohOnly,
            serverInfoBootstrap: successfulServerInfoBootstrap,
            irohProxyFactory: { _, _ in
                factoryCalls += 1
                return factoryCalls == 1
                    ? (firstManager, firstURL)
                    : (replacementManager, replacementURL)
            }
        ))

        await conn.handlePersistentStreamHealthFailure(.pingTimeout)

        #expect(factoryCalls == 1)
        #expect(await firstProvider.shutdownCount == 1)
        #expect(conn.apiClient == nil)

        #expect(await conn.reconfigureForExplicitRetry(
            credentials: credentials,
            routeMode: .irohOnly,
            serverInfoBootstrap: successfulServerInfoBootstrap,
            irohProxyFactory: { _, _ in
                factoryCalls += 1
                return (replacementManager, replacementURL)
            }
        ))
        #expect(factoryCalls == 2)
        #expect(conn.transportPath == .iroh)
        #expect(await conn.apiClient?.baseURL == replacementURL)
    }

    @Test func unhealthyLANPersistentStreamRetriesIroh() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let localURL = try #require(URL(string: "http://127.0.0.1:42026"))
        conn.setDiscoveredLANEndpoint(LANDiscoveredEndpoint(
            host: "192.168.1.42",
            port: 7749,
            serverFingerprintPrefix: "preferred-server-fp",
            tlsCertFingerprintPrefix: "preferred-tls-fp"
        ))
        #expect(await conn.configureForUse(
            credentials: credentials,
            serverInfoBootstrap: { client, _ in
                if await client.baseURL.host == "preferred.tailnet.ts.net" {
                    throw URLError(.cannotConnectToHost)
                }
                return successfulServerInfo()
            },
            irohProxyFactory: { _, _ in (nil, localURL) }
        ))
        #expect(conn.transportPath == .lan)

        await conn.handlePersistentStreamHealthFailure(.pingTimeout)

        #expect(conn.transportPath == .iroh)
        #expect(await conn.apiClient?.baseURL == localURL)
    }

    @Test func explicitRetryRebuildRestoresFocusedAndAppEventIntent() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let firstURL = try #require(URL(string: "http://127.0.0.1:42033"))
        let secondURL = try #require(URL(string: "http://127.0.0.1:42034"))
        #expect(await conn.configureForUse(
            credentials: credentials,
            routeMode: .irohOnly,
            serverInfoBootstrap: { _, _ in successfulServerInfo(appEventStream: true) },
            irohProxyFactory: { _, _ in (nil, firstURL) }
        ))
        conn.setSplitStreamCapabilitiesForTesting(appEventStream: true)
        conn.prepareFocusedSessionStreamEndpointForTesting(
            sessionId: "session-retry",
            workspaceId: "workspace-retry"
        )
        let originalFocusedURL = conn.focusedSessionStreamURLForTesting
        let originalGeneration = conn.persistentStreamGenerationForTesting

        #expect(await conn.reconfigureForExplicitRetry(
            credentials: credentials,
            routeMode: .irohOnly,
            serverInfoBootstrap: { _, _ in successfulServerInfo(appEventStream: true) },
            irohProxyFactory: { _, _ in (nil, secondURL) }
        ))

        #expect(conn.persistentStreamGenerationForTesting > originalGeneration)
        #expect(conn.focusedSessionStreamEndpointKind == "split_session")
        #expect(conn.focusedSessionStreamURLForTesting != originalFocusedURL)
        #expect(conn.focusedSessionStreamURLForTesting?.port == 42034)
        #expect(conn.appEventStreamTransportState == .connecting)
        conn.disconnectAppEventStream()
        conn.disconnectStream()
    }

    @Test func focusedWebSocketHealthCallbackExcludesIrohUntilExplicitRetry() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let metadata = try #require(credentials.transports.iroh)
        let firstProvider = TrackingReachableIrohProvider()
        let replacementProvider = TrackingReachableIrohProvider()
        let firstManager = IrohConnectionManager(iroh: metadata, provider: firstProvider)
        let replacementManager = IrohConnectionManager(iroh: metadata, provider: replacementProvider)
        let firstURL = try #require(URL(string: "http://127.0.0.1:42029"))
        let replacementURL = try #require(URL(string: "http://127.0.0.1:42046"))
        var factoryCalls = 0
        conn._refreshAfterAutomaticIrohRecoveryForTesting = {}
        #expect(await conn.configureForUse(
            credentials: credentials,
            routeMode: .irohOnly,
            serverInfoBootstrap: successfulServerInfoBootstrap,
            irohProxyFactory: { _, _ in
                factoryCalls += 1
                return factoryCalls == 1
                    ? (firstManager, firstURL)
                    : (replacementManager, replacementURL)
            }
        ))

        await conn.reportFocusedStreamHealthFailureForTesting(.pingTimeout)

        #expect(factoryCalls == 1)
        #expect(await firstProvider.shutdownCount == 1)
        #expect(conn.apiClient == nil)

        #expect(await conn.reconfigureForExplicitRetry(
            credentials: credentials,
            routeMode: .irohOnly,
            serverInfoBootstrap: successfulServerInfoBootstrap,
            irohProxyFactory: { _, _ in
                factoryCalls += 1
                return (replacementManager, replacementURL)
            }
        ))
        #expect(factoryCalls == 2)
        #expect(conn.transportPath == .iroh)
        #expect(await conn.apiClient?.baseURL == replacementURL)
    }

    @Test func stalePersistentHealthReportCannotRecoverReplacementTransport() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let firstProvider = EstablishedStreamFailureRecoveryProvider()
        let secondProvider = EstablishedStreamFailureRecoveryProvider()
        let metadata = try #require(credentials.transports.iroh)
        let firstManager = IrohConnectionManager(iroh: metadata, provider: firstProvider)
        let secondManager = IrohConnectionManager(iroh: metadata, provider: secondProvider)
        let firstURL = try #require(URL(string: "http://127.0.0.1:42027"))
        let secondURL = try #require(URL(string: "http://127.0.0.1:42028"))
        #expect(await conn.configureForUse(
            credentials: credentials,
            routeMode: .irohOnly,
            serverInfoBootstrap: successfulServerInfoBootstrap,
            irohProxyFactory: { _, _ in (firstManager, firstURL) }
        ))
        let staleGeneration = conn.persistentStreamGenerationForTesting
        #expect(await conn.configureForUse(
            credentials: credentials,
            routeMode: .irohOnly,
            serverInfoBootstrap: successfulServerInfoBootstrap,
            irohProxyFactory: { _, _ in (secondManager, secondURL) }
        ))
        let replacementAPI = conn.apiClient

        await conn.handlePersistentStreamHealthFailure(
            .reconnectThreshold(attempt: 4),
            expectedGeneration: staleGeneration
        )

        #expect(await firstProvider.shutdownCount == 1, "Superseded manager shuts down during replacement")
        #expect(await firstProvider.suspendCount == 0)
        #expect(await secondProvider.suspendCount == 0)
        #expect(conn.apiClient === replacementAPI)
        #expect(await conn.apiClient?.baseURL == secondURL)
    }

    @Test func concurrentPersistentStreamFailuresCoalesceIntoOneRouteWalk() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let localURL = try #require(URL(string: "http://127.0.0.1:42047"))
        let gate = SupersededSetupGate()
        var irohDials = 0
        conn._refreshAfterAutomaticIrohRecoveryForTesting = {}

        #expect(await conn.configureForUse(
            credentials: credentials,
            serverInfoBootstrap: successfulServerInfoBootstrap,
            irohProxyFactory: { _, _ in
                irohDials += 1
                await gate.waitUntilReleased()
                return (nil, localURL)
            }
        ))

        let firstRecovery = Task { @MainActor in
            await conn.handlePersistentStreamHealthFailure(.pingTimeout)
        }
        while !gate.isWaiting { await Task.yield() }
        let secondRecovery = Task { @MainActor in
            await conn.handlePersistentStreamHealthFailure(
                .reconnectThreshold(attempt: 4)
            )
        }
        while !conn.persistentHealthRecoveryPendingForTesting { await Task.yield() }
        gate.release()
        await firstRecovery.value
        await secondRecovery.value

        #expect(irohDials == 1)
        #expect(conn.transportPath == .iroh)
        #expect(await conn.apiClient?.baseURL == localURL)
    }

    @Test func concurrentFailureRetainsFollowUpWhenRecoveryDoesNotReplaceStreams() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let gate = SupersededSetupGate()
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        var attempts = 0
        conn._automaticIrohRecoveryNowForTesting = { now }

        #expect(await conn.configureForUse(
            credentials: credentials,
            serverInfoBootstrap: successfulServerInfoBootstrap,
            irohProxyFactory: { _, _ in
                attempts += 1
                if attempts == 1 {
                    await gate.waitUntilReleased()
                }
                throw IrohTransportError.unavailable("relay remains unavailable")
            }
        ))
        #expect(conn.transportPath == .paired)

        let streamGeneration = conn.persistentStreamGenerationForTesting
        let firstRecovery = Task { @MainActor in
            await conn.handlePersistentStreamHealthFailure(
                .pingTimeout,
                expectedGeneration: streamGeneration
            )
        }
        while !gate.isWaiting { await Task.yield() }
        let secondRecovery = Task { @MainActor in
            await conn.handlePersistentStreamHealthFailure(
                .reconnectThreshold(attempt: 4),
                expectedGeneration: streamGeneration
            )
        }
        while !conn.persistentHealthRecoveryPendingForTesting { await Task.yield() }
        now = now.addingTimeInterval(1)
        gate.release()
        await firstRecovery.value
        await secondRecovery.value

        #expect(attempts == 2)
        #expect(conn.apiClient == nil)
    }

    @Test func persistentHealthFailureOnHTTPOnlyConnectionFailsOfflineWithoutExpandingRoutes() async {
        let conn = ServerConnection()
        #expect(await conn.configureForUse(
            credentials: makeHTTPOnlyCredentials(),
            serverInfoBootstrap: successfulServerInfoBootstrap
        ))

        await conn.handlePersistentStreamHealthFailure(.reconnectThreshold(attempt: 7))

        #expect(conn.transportPath == .paired)
        #expect(conn.apiClient == nil)
        #expect(conn.wsClient == nil)
    }

    @Test func LANDiscoveredDuringInitialIrohProbeWinsAtNextBoundary() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let metadata = try #require(credentials.transports.iroh)
        let provider = GatedReachableEvidenceIrohProvider()
        let manager = IrohConnectionManager(iroh: metadata, provider: provider)
        let localURL = try #require(URL(string: "http://127.0.0.1:42007"))

        let configurationTask = Task { @MainActor in
            await conn.configureForUse(
                credentials: credentials,
                serverInfoBootstrap: { client, _ in
                    if await client.baseURL.host == "preferred.tailnet.ts.net" {
                        throw URLError(.cannotConnectToHost)
                    }
                    return successfulServerInfo()
                },
                irohProxyFactory: { _, _ in (manager, localURL) }
            )
        }
        while !(await provider.evidenceIsWaiting) {
            await Task.yield()
        }
        conn.setDiscoveredLANEndpoint(LANDiscoveredEndpoint(
            host: "192.168.1.42",
            port: 7749,
            serverFingerprintPrefix: "preferred-server-fp",
            tlsCertFingerprintPrefix: "preferred-tls-fp"
        ))
        await provider.releaseEvidence()
        #expect(await configurationTask.value)
        #expect(conn.transportPath == .iroh)

        await conn.reevaluateIrohPreferredTransportAtBoundary()

        #expect(conn.transportPath == .lan)
        #expect(await provider.shutdownCount == 1)
    }

    @Test func verifiedLANAppearanceReplacesActiveIrohAtBoundary() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let metadata = try #require(credentials.transports.iroh)
        let provider = TrackingReachableIrohProvider()
        let manager = IrohConnectionManager(iroh: metadata, provider: provider)
        let localURL = try #require(URL(string: "http://127.0.0.1:42008"))
        #expect(await conn.configureForUse(
            credentials: credentials,
            serverInfoBootstrap: { client, _ in
                if await client.baseURL.host == "preferred.tailnet.ts.net" {
                    throw URLError(.cannotConnectToHost)
                }
                return successfulServerInfo()
            },
            irohProxyFactory: { _, _ in (manager, localURL) }
        ))
        #expect(conn.transportPath == .iroh)

        let transition = conn.setDiscoveredLANEndpoint(LANDiscoveredEndpoint(
            host: "192.168.1.42",
            port: 7749,
            serverFingerprintPrefix: "preferred-server-fp",
            tlsCertFingerprintPrefix: "preferred-tls-fp"
        ))
        await transition?.value

        #expect(conn.transportPath == .lan)
        #expect(await provider.shutdownCount == 1)
    }

    @Test func LANDiscoveredDuringIrohRecoveryStillWinsTheSupersedingPass() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let metadata = try #require(credentials.transports.iroh)
        let provider = GatedReachableEvidenceIrohProvider()
        let manager = IrohConnectionManager(iroh: metadata, provider: provider)
        let localURL = try #require(URL(string: "http://127.0.0.1:42006"))
        conn._refreshAfterAutomaticIrohRecoveryForTesting = {}

        #expect(await conn.configureForUse(
            credentials: credentials,
            serverInfoBootstrap: successfulServerInfoBootstrap,
            irohProxyFactory: { _, _ in (manager, localURL) }
        ))
        #expect(conn.transportPath == .paired)

        let recovery = Task { @MainActor in
            await conn.handlePersistentStreamHealthFailure(.pingTimeout)
        }
        while !(await provider.evidenceIsWaiting) {
            await Task.yield()
        }
        let transition = conn.setDiscoveredLANEndpoint(LANDiscoveredEndpoint(
            host: "192.168.1.42",
            port: 7749,
            serverFingerprintPrefix: "preferred-server-fp",
            tlsCertFingerprintPrefix: "preferred-tls-fp"
        ))
        await provider.releaseEvidence()
        await recovery.value
        await transition?.value

        #expect(conn.transportPath == .lan)
        #expect(await provider.shutdownCount == 1)
    }

    @Test func overlappingBoundaryReevaluationsCoalesceAndRestorePairedEligibility() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let metadata = try #require(credentials.transports.iroh)
        let provider = CoalescedBoundaryIrohProvider()
        let manager = IrohConnectionManager(iroh: metadata, provider: provider)
        let localURL = try #require(URL(string: "http://127.0.0.1:42012"))
        var pairedAvailable = false

        #expect(await conn.configureForUse(
            credentials: credentials,
            serverInfoBootstrap: { client, _ in
                if await client.baseURL.host == "preferred.tailnet.ts.net", !pairedAvailable {
                    throw URLError(.cannotConnectToHost)
                }
                return successfulServerInfo()
            },
            irohProxyFactory: { _, _ in (manager, localURL) }
        ))
        #expect(conn.transportPath == .iroh)
        pairedAvailable = true

        let firstBoundary = Task { @MainActor in
            await conn.reevaluateIrohPreferredTransportAtBoundary(excluding: [.paired])
        }
        while !(await provider.secondEvidenceIsWaiting) {
            await Task.yield()
        }
        await conn.reevaluateIrohPreferredTransportAtBoundary(excluding: [.iroh])
        await provider.releaseSecondEvidence()
        await firstBoundary.value

        #expect(await provider.evidenceCount == 2)
        #expect(conn.transportPath == .paired)
    }

    @Test func unavailableIrohPassGoesOfflineThenLaterRetryRestoresPaired() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let localURL = try #require(URL(string: "http://127.0.0.1:41994"))
        let provider = SequencedPathEvidenceProvider(results: [
            .success(IrohSelectedPathEvidence(isIP: true, isRelay: false, rttMs: 1)),
            .failure(IrohTransportError.unavailable("path lost")),
        ])
        let metadata = try #require(credentials.transports.iroh)
        let manager = IrohConnectionManager(iroh: metadata, provider: provider)
        var pairedAvailable = false
        let bootstrap: ServerConnectionInfoBootstrap = { client, _ in
            if await client.baseURL.host == "preferred.tailnet.ts.net", !pairedAvailable {
                throw URLError(.cannotConnectToHost)
            }
            return successfulServerInfo()
        }

        #expect(await conn.configureForUse(
            credentials: credentials,
            serverInfoBootstrap: bootstrap,
            irohProxyFactory: { _, _ in (manager, localURL) }
        ))
        #expect(conn.transportPath == .iroh)

        let unavailableRetry = await conn.reconfigureForExplicitRetry(
            credentials: credentials,
            serverInfoBootstrap: bootstrap,
            irohProxyFactory: { _, _ in (manager, localURL) }
        )
        #expect(!unavailableRetry)
        #expect(conn.apiClient == nil)

        pairedAvailable = true
        #expect(await conn.reconfigureForExplicitRetry(
            credentials: credentials,
            serverInfoBootstrap: bootstrap,
            irohProxyFactory: { _, _ in
                throw IrohTransportError.unavailable("must not dial")
            }
        ))
        #expect(conn.transportPath == .paired)
        #expect(await conn.apiClient?.baseURL.host == "preferred.tailnet.ts.net")
    }

    @Test func verifiedLANAppearanceReplacesIrohUsingAutomaticOrder() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let localURL = try #require(URL(string: "http://127.0.0.1:41995"))
        #expect(await conn.configureForUse(
            credentials: credentials,
            serverInfoBootstrap: { client, _ in
                if await client.baseURL.host == "preferred.tailnet.ts.net" {
                    throw URLError(.cannotConnectToHost)
                }
                return successfulServerInfo()
            },
            irohProxyFactory: { _, _ in (nil, localURL) }
        ))
        #expect(conn.transportPath == .iroh)

        let transition = conn.setDiscoveredLANEndpoint(LANDiscoveredEndpoint(
            host: "192.168.1.42",
            port: 7749,
            serverFingerprintPrefix: "preferred-server-fp",
            tlsCertFingerprintPrefix: "preferred-tls-fp"
        ))
        await transition?.value

        #expect(conn.transportPath == .lan)
    }

    @Test func leavingVerifiedLANSelectsPairedHTTPSBeforeIroh() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let localURL = try #require(URL(string: "http://127.0.0.1:41997"))
        var irohDials = 0
        conn.setDiscoveredLANEndpoint(LANDiscoveredEndpoint(
            host: "192.168.1.42",
            port: 7749,
            serverFingerprintPrefix: "preferred-server-fp",
            tlsCertFingerprintPrefix: "preferred-tls-fp"
        ))
        #expect(await conn.configureForUse(
            credentials: credentials,
            serverInfoBootstrap: successfulServerInfoBootstrap,
            irohProxyFactory: { _, _ in
                irohDials += 1
                return (nil, localURL)
            }
        ))
        #expect(conn.transportPath == .lan)

        let transition = conn.setDiscoveredLANEndpoint(nil)
        await transition?.value

        #expect(irohDials == 0)
        #expect(conn.transportPath == .paired)
        #expect(await conn.apiClient?.baseURL.host == "preferred.tailnet.ts.net")
    }

    @Test func terminalIrohFailureAfterPairedRouteFailureRemainsLocked() async {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        var attempts = 0

        #expect(await conn.configureForUse(
            credentials: credentials,
            serverInfoBootstrap: successfulServerInfoBootstrap,
            irohProxyFactory: { _, _ in
                attempts += 1
                throw IrohTransportError.authentication("token rejected")
            }
        ))
        #expect(conn.transportPath == .paired)

        await conn.handlePersistentStreamHealthFailure(.reconnectThreshold(attempt: 4))

        #expect(attempts == 1)
        #expect(conn.apiClient == nil)
        #expect(conn.wsClient == nil)

        conn.setDiscoveredLANEndpoint(LANDiscoveredEndpoint(
            host: "192.168.1.42",
            port: 7749,
            serverFingerprintPrefix: "preferred-server-fp",
            tlsCertFingerprintPrefix: "preferred-tls-fp"
        ))
        #expect(conn.apiClient == nil, "Terminal failure remains locked until explicit reconfiguration")
    }

    @Test func partialIrohSetupFailureShutsDownManager() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let localURL = try #require(URL(string: "http://127.0.0.1:41998"))
        let provider = TrackingTerminalIrohProvider()
        let metadata = try #require(credentials.transports.iroh)
        let manager = IrohConnectionManager(iroh: metadata, provider: provider)

        let configured = await conn.configureForUse(
            credentials: credentials,
            routeMode: .irohOnly,
            serverInfoBootstrap: successfulServerInfoBootstrap,
            irohProxyFactory: { _, _ in (manager, localURL) }
        )

        #expect(!configured)
        #expect(await provider.shutdownCount == 1)
        #expect(conn.apiClient == nil)
    }

    @Test func transportGenerationPreventsTurnRetryAcrossReplacement() async {
        let conn = ServerConnection()
        conn._setActiveSessionIdForTesting("session-1")
        var attempts = 0
        conn._sendMessageForTesting = { _ in
            attempts += 1
            conn.sender.advanceTransportGeneration()
        }

        await #expect(throws: CancellationError.self) {
            try await conn.sendPrompt("do not replay")
        }

        #expect(attempts == 1)
    }

    @Test func explicitReconfigurationFencesTurnRetryDuringRetryDelay() async {
        let conn = ServerConnection()
        conn._setActiveSessionIdForTesting("session-1")
        conn._turnSendRetryDelayForTesting = .milliseconds(1)
        var attempts = 0
        conn._sendMessageForTesting = { _ in
            attempts += 1
            throw WebSocketError.notConnected
        }
        conn.sender._onTurnRetryDelayForTesting = {
            _ = conn.configure(credentials: ServerCredentials(
                host: "replacement.ts.net",
                port: 7749,
                token: "dt_replacement",
                name: "Replacement",
                scheme: .https
            ))
        }

        await #expect(throws: CancellationError.self) {
            try await conn.sendPrompt("must stay on its original transport")
        }

        #expect(attempts == 1)
    }

    @Test func failedExplicitReconfigurationPreservesTerminalLockout() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        var attempts = 0
        #expect(await conn.configureForUse(
            credentials: credentials,
            serverInfoBootstrap: successfulServerInfoBootstrap,
            irohProxyFactory: { _, _ in
                attempts += 1
                throw IrohTransportError.authentication("token rejected")
            }
        ))

        await conn.handlePersistentStreamHealthFailure(.reconnectThreshold(attempt: 4))
        #expect(attempts == 1)
        #expect(conn.apiClient == nil)

        let rejected = await conn.configureForUse(
            credentials: credentials,
            serverInfoBootstrap: { client, _ in
                if await client.baseURL.host == "preferred.tailnet.ts.net" {
                    throw URLError(.cannotConnectToHost)
                }
                return successfulServerInfo()
            },
            irohProxyFactory: { _, _ in
                attempts += 1
                throw IrohTransportError.authentication("still rejected")
            }
        )
        #expect(!rejected)
        #expect(attempts == 2)

        conn.setDiscoveredLANEndpoint(LANDiscoveredEndpoint(
            host: "192.168.1.42",
            port: 7749,
            serverFingerprintPrefix: "preferred-server-fp",
            tlsCertFingerprintPrefix: "preferred-tls-fp"
        ))
        #expect(conn.apiClient == nil, "A failed explicit retry must not clear terminal lockout")
    }

    @Test func terminalExplicitReconfigurationInvalidatesUsablePairedRoute() async {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        #expect(await conn.configureForUse(
            credentials: credentials,
            serverInfoBootstrap: successfulServerInfoBootstrap,
            irohProxyFactory: { _, _ in
                throw IrohTransportError.unavailable("must not dial")
            }
        ))
        #expect(conn.transportPath == .paired)
        #expect(conn.apiClient != nil)

        let rejected = await conn.configureForUse(
            credentials: credentials,
            serverInfoBootstrap: { client, _ in
                if await client.baseURL.host == "preferred.tailnet.ts.net" {
                    throw URLError(.cannotConnectToHost)
                }
                return successfulServerInfo()
            },
            irohProxyFactory: { _, _ in
                throw IrohTransportError.authentication("token rejected")
            }
        )

        #expect(!rejected)
        #expect(conn.apiClient == nil)
        #expect(conn.wsClient == nil)
    }

    @Test func supersededAvailabilityPassCannotOverwriteNewerConfiguration() async throws {
        let conn = ServerConnection()
        let staleCredentials = makeIrohPreferredCredentials()
        let middleCredentials = ServerCredentials(
            host: "middle.ts.net",
            port: 7749,
            token: "dt_middle",
            name: "Middle",
            scheme: .https,
            serverFingerprint: "sha256:middle-fp"
        )
        let newestCredentials = ServerCredentials(
            host: "newest.ts.net",
            port: 7749,
            token: "dt_newest",
            name: "Newest",
            scheme: .https,
            serverFingerprint: "sha256:newest-fp"
        )
        let metadata = try #require(staleCredentials.transports.iroh)
        let provider = GatedUnavailableShutdownIrohProvider()
        let manager = IrohConnectionManager(iroh: metadata, provider: provider)
        let localURL = try #require(URL(string: "http://127.0.0.1:42005"))

        let staleTask = Task { @MainActor in
            await conn.configureForUse(
                credentials: staleCredentials,
                serverInfoBootstrap: { client, _ in
                    if await client.baseURL.host == "preferred.tailnet.ts.net" {
                        throw URLError(.cannotConnectToHost)
                    }
                    return successfulServerInfo()
                },
                irohProxyFactory: { _, _ in (manager, localURL) }
            )
        }
        while !(await provider.shutdownIsWaiting) {
            await Task.yield()
        }

        let middleTask = Task { @MainActor in
            await conn.configureForUse(credentials: middleCredentials, serverInfoBootstrap: successfulServerInfoBootstrap)
        }
        await Task.yield()
        let newestTask = Task { @MainActor in
            await conn.configureForUse(credentials: newestCredentials, serverInfoBootstrap: successfulServerInfoBootstrap)
        }
        await Task.yield()
        await provider.releaseShutdown()
        _ = await staleTask.value
        let middleResult = await middleTask.value
        let newestResult = await newestTask.value

        #expect(!middleResult)
        #expect(newestResult)
        #expect(conn.currentServerId == "sha256:newest-fp")
        #expect(await conn.apiClient?.baseURL.host == "newest.ts.net")
    }

    @Test func unavailableLANCandidateDoesNotOverwritePairedRoute() async {
        let conn = ServerConnection()
        let credentials = ServerCredentials(
            host: "my-server.tail00000.ts.net",
            port: 7749,
            token: "dt_test",
            name: "Test",
            scheme: .https,
            serverFingerprint: "sha256:SERVERFINGERPRINTABCDEF",
            tlsCertFingerprint: "sha256:TLSFINGERPRINTABCDEF"
        )
        var lanBootstraps = 0
        #expect(await conn.configureForUse(
            credentials: credentials,
            serverInfoBootstrap: { client, _ in
                if await client.baseURL.host == "192.168.1.42" {
                    lanBootstraps += 1
                    throw URLError(.cannotConnectToHost)
                }
                return successfulServerInfo()
            }
        ))
        let transition = conn.setDiscoveredLANEndpoint(LANDiscoveredEndpoint(
            host: "192.168.1.42",
            port: 7749,
            serverFingerprintPrefix: "SERVERFINGERPRINT",
            tlsCertFingerprintPrefix: "TLSFINGERPRINT"
        ))
        await transition?.value

        #expect(lanBootstraps == 1)
        #expect(conn.transportPath == .paired)
        #expect(await conn.apiClient?.baseURL.host == "my-server.tail00000.ts.net")
    }

    @Test func replacingLANCandidateCannotAdoptStaleBootstrapResult() async {
        let conn = ServerConnection()
        let credentials = makeHTTPOnlyCredentials()
        let gate = LANCandidateProbeGate(
            reachableHost: "192.168.1.43",
            firstProbeResult: true
        )
        #expect(await conn.configureForUse(
            credentials: credentials,
            serverInfoBootstrap: { client, _ in
                let url = await client.baseURL
                guard url.host?.hasPrefix("192.168.1.") == true else {
                    return successfulServerInfo()
                }
                let selection = EndpointSelection(baseURL: url, transportPath: .lan)
                guard await gate.probe(selection) else {
                    throw URLError(.cannotConnectToHost)
                }
                return successfulServerInfo()
            }
        ))

        let staleTransition = conn.setDiscoveredLANEndpoint(
            makeLANCandidate(host: "192.168.1.42")
        )
        await gate.waitForFirstProbe()
        let currentTransition = conn.setDiscoveredLANEndpoint(
            makeLANCandidate(host: "192.168.1.43")
        )
        await currentTransition?.value
        await gate.releaseFirstProbe()
        await staleTransition?.value

        #expect(conn.transportPath == .lan)
        #expect(await conn.apiClient?.baseURL.host == "192.168.1.43")
        #expect(await gate.probeCount == 2)
    }

    @Test func replacingLANCandidateDuringIrohBoundaryAdoptsNewestCandidate() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let metadata = try #require(credentials.transports.iroh)
        let provider = TrackingReachableIrohProvider()
        let manager = IrohConnectionManager(iroh: metadata, provider: provider)
        let localURL = try #require(URL(string: "http://127.0.0.1:42017"))
        let gate = LANCandidateProbeGate(
            reachableHost: "192.168.1.43",
            firstProbeResult: true
        )
        #expect(await conn.configureForUse(
            credentials: credentials,
            serverInfoBootstrap: { client, _ in
                let url = await client.baseURL
                if url.host == "preferred.tailnet.ts.net" {
                    throw URLError(.cannotConnectToHost)
                }
                if url.host?.hasPrefix("192.168.1.") == true {
                    let selection = EndpointSelection(baseURL: url, transportPath: .lan)
                    guard await gate.probe(selection) else {
                        throw URLError(.cannotConnectToHost)
                    }
                }
                return successfulServerInfo()
            },
            irohProxyFactory: { _, _ in (manager, localURL) }
        ))

        let staleTransition = conn.setDiscoveredLANEndpoint(LANDiscoveredEndpoint(
            host: "192.168.1.42",
            port: 7749,
            serverFingerprintPrefix: "preferred-server-fp",
            tlsCertFingerprintPrefix: "preferred-tls-fp"
        ))
        await gate.waitForFirstProbe()
        let currentTransition = conn.setDiscoveredLANEndpoint(LANDiscoveredEndpoint(
            host: "192.168.1.43",
            port: 7749,
            serverFingerprintPrefix: "preferred-server-fp",
            tlsCertFingerprintPrefix: "preferred-tls-fp"
        ))
        await currentTransition?.value
        await gate.releaseFirstProbe()
        await staleTransition?.value

        #expect(conn.transportPath == .lan)
        #expect(await conn.apiClient?.baseURL.host == "192.168.1.43")
        #expect(await gate.probeCount == 2)
    }

    @Test func repeatedIdenticalLANCandidateStartsOneBootstrap() async {
        let conn = ServerConnection()
        let credentials = makeHTTPOnlyCredentials()
        let counter = LANProbeCounter()
        #expect(await conn.configureForUse(
            credentials: credentials,
            serverInfoBootstrap: { client, _ in
                if await client.baseURL.host == "192.168.1.42" {
                    await counter.increment()
                }
                return successfulServerInfo()
            }
        ))
        let candidate = makeLANCandidate(host: "192.168.1.42")

        let transition = conn.setDiscoveredLANEndpoint(candidate)
        conn.setDiscoveredLANEndpoint(candidate)
        await transition?.value

        #expect(await counter.value == 1)
        #expect(conn.transportPath == .lan)
    }

    @Test func LANDiscoveredAfterIrohBoundaryStillTriggersVerifiedAdoption() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let metadata = try #require(credentials.transports.iroh)
        let provider = TrackingReachableIrohProvider()
        let manager = IrohConnectionManager(iroh: metadata, provider: provider)
        let localURL = try #require(URL(string: "http://127.0.0.1:42016"))
        #expect(await conn.configureForUse(
            credentials: credentials,
            serverInfoBootstrap: { client, _ in
                if await client.baseURL.host == "preferred.tailnet.ts.net" {
                    throw URLError(.cannotConnectToHost)
                }
                return successfulServerInfo()
            },
            irohProxyFactory: { _, _ in (manager, localURL) }
        ))
        #expect(conn.transportPath == .iroh)

        let transition = conn.setDiscoveredLANEndpoint(LANDiscoveredEndpoint(
            host: "192.168.1.42",
            port: 7749,
            serverFingerprintPrefix: "preferred-server-fp",
            tlsCertFingerprintPrefix: "preferred-tls-fp"
        ))
        await transition?.value

        #expect(conn.transportPath == .lan)
        #expect(await provider.shutdownCount == 1)
    }

    @Test func removingUnverifiedCandidateKeepsHealthyIroh() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let metadata = try #require(credentials.transports.iroh)
        let provider = TrackingReachableIrohProvider()
        let manager = IrohConnectionManager(iroh: metadata, provider: provider)
        let localURL = try #require(URL(string: "http://127.0.0.1:42018"))
        var lanBootstraps = 0
        #expect(await conn.configureForUse(
            credentials: credentials,
            serverInfoBootstrap: { client, _ in
                switch await client.baseURL.host {
                case "preferred.tailnet.ts.net":
                    throw URLError(.cannotConnectToHost)
                case "192.168.1.42":
                    lanBootstraps += 1
                    throw URLError(.notConnectedToInternet)
                default:
                    return successfulServerInfo()
                }
            },
            irohProxyFactory: { _, _ in (manager, localURL) }
        ))

        let transition = conn.setDiscoveredLANEndpoint(LANDiscoveredEndpoint(
            host: "192.168.1.42",
            port: 7749,
            serverFingerprintPrefix: "preferred-server-fp",
            tlsCertFingerprintPrefix: "preferred-tls-fp"
        ))
        await transition?.value
        conn.setDiscoveredLANEndpoint(nil)

        #expect(lanBootstraps == 1)
        #expect(conn.transportPath == .iroh)
        #expect(await conn.apiClient?.baseURL == localURL)
    }

    @Test func LANToPairedTransitionFencesSleepingTurnRetry() async {
        let conn = ServerConnection()
        let credentials = ServerCredentials(
            host: "my-server.tail00000.ts.net",
            port: 7749,
            token: "dt_test",
            name: "Test",
            scheme: .https,
            serverFingerprint: "sha256:SERVERFINGERPRINTABCDEF",
            tlsCertFingerprint: "sha256:TLSFINGERPRINTABCDEF"
        )
        conn.setDiscoveredLANEndpoint(LANDiscoveredEndpoint(
            host: "192.168.1.42",
            port: 7749,
            serverFingerprintPrefix: "SERVERFINGERPRINT",
            tlsCertFingerprintPrefix: "TLSFINGERPRINT"
        ))
        #expect(await conn.configureForUse(
            credentials: credentials,
            serverInfoBootstrap: successfulServerInfoBootstrap
        ))
        #expect(conn.transportPath == .lan)
        conn._setActiveSessionIdForTesting("session-1")
        conn._turnSendRetryDelayForTesting = .milliseconds(1)
        var attempts = 0
        conn._sendMessageForTesting = { _ in
            attempts += 1
            throw WebSocketError.notConnected
        }
        conn.sender._onTurnRetryDelayForTesting = {
            conn.setDiscoveredLANEndpoint(nil)
        }

        await #expect(throws: CancellationError.self) {
            try await conn.sendPrompt("never retry across LAN handoff")
        }

        #expect(attempts == 1)
        #expect(conn.transportPath == .paired)
    }

    @Test func supersededSetupShutsDownOnlyTheUnadoptedManager() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let firstProvider = TrackingReachableIrohProvider()
        let adoptedProvider = TrackingReachableIrohProvider()
        let metadata = try #require(credentials.transports.iroh)
        let firstManager = IrohConnectionManager(iroh: metadata, provider: firstProvider)
        let adoptedManager = IrohConnectionManager(iroh: metadata, provider: adoptedProvider)
        let firstURL = try #require(URL(string: "http://127.0.0.1:42001"))
        let adoptedURL = try #require(URL(string: "http://127.0.0.1:42002"))
        let gate = SupersededSetupGate()

        let firstTask = Task { @MainActor in
            await conn.configureForUse(
                credentials: credentials,
                routeMode: .irohOnly,
                serverInfoBootstrap: successfulServerInfoBootstrap,
                irohProxyFactory: { _, _ in
                    await gate.waitUntilReleased()
                    return (firstManager, firstURL)
                }
            )
        }
        while !gate.isWaiting {
            await Task.yield()
        }

        let secondResult = await conn.configureForUse(
            credentials: credentials,
            routeMode: .irohOnly,
            serverInfoBootstrap: successfulServerInfoBootstrap,
            irohProxyFactory: { _, _ in (adoptedManager, adoptedURL) }
        )
        gate.release()
        let firstResult = await firstTask.value

        #expect(secondResult)
        #expect(!firstResult)
        #expect(await firstProvider.shutdownCount == 1)
        #expect(await adoptedProvider.shutdownCount == 0)
        #expect(await conn.apiClient?.baseURL == adoptedURL)
    }

    @Test func supersededSetupDoesNotShutdownManagerAdoptedByNewerSetup() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let provider = TrackingReachableIrohProvider()
        let metadata = try #require(credentials.transports.iroh)
        let sharedManager = IrohConnectionManager(iroh: metadata, provider: provider)
        let firstURL = try #require(URL(string: "http://127.0.0.1:42003"))
        let adoptedURL = try #require(URL(string: "http://127.0.0.1:42004"))
        let gate = SupersededSetupGate()

        let firstTask = Task { @MainActor in
            await conn.configureForUse(
                credentials: credentials,
                routeMode: .irohOnly,
                serverInfoBootstrap: successfulServerInfoBootstrap,
                irohProxyFactory: { _, _ in
                    await gate.waitUntilReleased()
                    return (sharedManager, firstURL)
                }
            )
        }
        while !gate.isWaiting {
            await Task.yield()
        }

        let secondResult = await conn.configureForUse(
            credentials: credentials,
            routeMode: .irohOnly,
            serverInfoBootstrap: successfulServerInfoBootstrap,
            irohProxyFactory: { _, _ in (sharedManager, adoptedURL) }
        )
        gate.release()
        let firstResult = await firstTask.value

        #expect(secondResult)
        #expect(!firstResult)
        #expect(await provider.shutdownCount == 0)
        #expect(await conn.apiClient?.baseURL == adoptedURL)
    }

    @Test func leavingVerifiedLANUsesPairedHTTPSWithoutIrohDial() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        conn.setDiscoveredLANEndpoint(LANDiscoveredEndpoint(
            host: "192.168.1.42",
            port: 7749,
            serverFingerprintPrefix: "preferred-server-fp",
            tlsCertFingerprintPrefix: "preferred-tls-fp"
        ))
        var irohDials = 0
        let configured = await conn.configureForUse(
            credentials: credentials,
            serverInfoBootstrap: successfulServerInfoBootstrap,
            irohProxyFactory: { _, _ in
                irohDials += 1
                throw IrohTransportError.unavailable("must not dial")
            }
        )
        #expect(configured)
        #expect(conn.transportPath == .lan)

        let transition = conn.setDiscoveredLANEndpoint(nil)
        await transition?.value

        #expect(irohDials == 0)
        #expect(conn.transportPath == .paired)
        #expect(await conn.apiClient?.baseURL.host == "preferred.tailnet.ts.net")
    }

    @Test func existingLANIsIdempotentAtForegroundBoundary() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        conn.setDiscoveredLANEndpoint(LANDiscoveredEndpoint(
            host: "192.168.1.42",
            port: 7749,
            serverFingerprintPrefix: "preferred-server-fp",
            tlsCertFingerprintPrefix: "preferred-tls-fp"
        ))
        let configured = await conn.configureForUse(
            credentials: credentials,
            serverInfoBootstrap: successfulServerInfoBootstrap
        )
        let originalAPIClient = conn.apiClient
        #expect(configured)
        #expect(conn.transportPath == .lan)

        await conn.reevaluateIrohPreferredTransportAtBoundary()

        #expect(conn.apiClient === originalAPIClient)
        #expect(conn.transportPath == .lan)
    }

    @Test func terminalExplicitFailureWithoutNewManagerShutsDownActiveIrohManager() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let localURL = try #require(URL(string: "http://127.0.0.1:42009"))
        let provider = TrackingReachableIrohProvider()
        let metadata = try #require(credentials.transports.iroh)
        let manager = IrohConnectionManager(iroh: metadata, provider: provider)
        let configured = await conn.configureForUse(
            credentials: credentials,
            routeMode: .irohOnly,
            serverInfoBootstrap: successfulServerInfoBootstrap,
            irohProxyFactory: { _, _ in (manager, localURL) }
        )
        #expect(configured)
        #expect(conn.transportPath == .iroh)

        let rejected = await conn.configureForUse(
            credentials: credentials,
            routeMode: .irohOnly,
            serverInfoBootstrap: successfulServerInfoBootstrap,
            irohProxyFactory: { _, _ in
                throw IrohTransportError.authentication("rejected before manager return")
            }
        )

        #expect(!rejected)
        #expect(await provider.shutdownCount == 1)
        #expect(conn.apiClient == nil)
        #expect(conn.wsClient == nil)
    }

    @Test func terminalActiveIrohFailureShutsDownActiveAndRejectedManagers() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let localURL = try #require(URL(string: "http://127.0.0.1:41999"))
        let activeProvider = TrackingReachableIrohProvider()
        let rejectedProvider = TrackingTerminalIrohProvider()
        let metadata = try #require(credentials.transports.iroh)
        let activeManager = IrohConnectionManager(iroh: metadata, provider: activeProvider)
        let rejectedManager = IrohConnectionManager(iroh: metadata, provider: rejectedProvider)
        var factoryCalls = 0
        let configured = await conn.configureForUse(
            credentials: credentials,
            routeMode: .irohOnly,
            serverInfoBootstrap: successfulServerInfoBootstrap,
            irohProxyFactory: { _, _ in
                factoryCalls += 1
                return factoryCalls == 1
                    ? (activeManager, localURL)
                    : (rejectedManager, localURL)
            }
        )
        #expect(configured)

        await conn.reevaluateIrohPreferredTransportAtBoundary(excluding: [.paired])

        #expect(factoryCalls == 2)
        #expect(await activeProvider.shutdownCount == 1)
        #expect(await rejectedProvider.shutdownCount == 1)
        #expect(conn.apiClient == nil)
        #expect(conn.wsClient == nil)
    }

    @Test func stopRetryIsFencedAcrossTransportGeneration() async {
        let conn = ServerConnection()
        conn._setActiveSessionIdForTesting("session-1")
        var attempts = 0
        conn._sendMessageForTesting = { _ in
            attempts += 1
            conn.sender.advanceTransportGeneration()
        }

        await #expect(throws: CancellationError.self) {
            try await conn.sendStop()
        }

        #expect(attempts == 1)
    }

    @Test func shortLivedClientUsesPairedHTTPSBeforeIroh() async throws {
        let credentials = makeIrohPreferredCredentials()
        let server = try #require(PairedServer(from: credentials))
        let operationCount = LifecycleOperationCounter()

        let selectedHost = try await ServerTransportAPIClient.withClient(
            for: server,
            lanEndpointProvider: { _ in nil },
            managerFactory: { metadata in
                IrohConnectionManager(iroh: metadata, provider: UnavailableIrohProvider())
            },
            httpAvailabilityProbe: { _ in },
            operation: { api in
                await operationCount.increment()
                return await api.baseURL.host
            }
        )

        #expect(await operationCount.value == 1)
        #expect(selectedHost == "preferred.tailnet.ts.net")
    }

    @Test func shortLivedClientUsesVerifiedLANBeforeIroh() async throws {
        let credentials = makeIrohPreferredCredentials()
        let server = try #require(PairedServer(from: credentials))
        let selectedPort = try await ServerTransportAPIClient.withClient(
            for: server,
            lanEndpointProvider: { _ in
                LANDiscoveredEndpoint(
                    host: "192.168.1.42",
                    port: 8443,
                    serverFingerprintPrefix: "preferred-server-fp",
                    tlsCertFingerprintPrefix: "preferred-tls-fp"
                )
            },
            lanReachabilityProbe: { _, _ in true },
            httpAvailabilityProbe: { _ in },
            operation: { api in await api.baseURL.port }
        )

        #expect(selectedPort == 8443)
    }

    @Test func shortLivedClientRejectsUnreachableLANThenUsesPairedHTTPS() async throws {
        let credentials = makeIrohPreferredCredentials()
        let server = try #require(PairedServer(from: credentials))
        let operationCount = LifecycleOperationCounter()
        let selectedHost = try await ServerTransportAPIClient.withClient(
            for: server,
            lanEndpointProvider: { _ in
                LANDiscoveredEndpoint(
                    host: "192.168.1.42",
                    port: 7749,
                    serverFingerprintPrefix: "preferred-server-fp",
                    tlsCertFingerprintPrefix: "preferred-tls-fp"
                )
            },
            lanReachabilityProbe: { _, _ in false },
            managerFactory: { metadata in
                IrohConnectionManager(iroh: metadata, provider: TrackingReachableIrohProvider())
            },
            httpAvailabilityProbe: { _ in },
            operation: { api in
                await operationCount.increment()
                return await api.baseURL.host
            }
        )

        #expect(await operationCount.value == 1)
        #expect(selectedHost == "preferred.tailnet.ts.net")
    }

    @Test func shortLivedUnpinnedLANClientCarriesSignedTLSServerName() async throws {
        let credentials = makeIrohPreferredCredentials(tlsFingerprint: nil)
        let server = try #require(PairedServer(from: credentials))
        let selected = try await ServerTransportAPIClient.withClient(
            for: server,
            lanEndpointProvider: { _ in
                LANDiscoveredEndpoint(
                    host: "192.168.1.42",
                    port: 7749,
                    serverFingerprintPrefix: "preferred-server-fp",
                    tlsCertFingerprintPrefix: nil
                )
            },
            lanReachabilityProbe: { _, _ in true },
            httpAvailabilityProbe: { _ in },
            operation: { api in
                (await api.baseURL.host, await api.environment.tlsServerName)
            }
        )

        #expect(selected.0 == "192.168.1.42")
        #expect(selected.1 == "preferred.tailnet.ts.net")
    }

    @Test func shortLivedClientNeverReplaysStartedOperation() async throws {
        let credentials = makeIrohPreferredCredentials()
        let server = try #require(PairedServer(from: credentials))
        let operationCount = LifecycleOperationCounter()

        await #expect(throws: IrohTransportError.unavailable("operation failed")) {
            _ = try await ServerTransportAPIClient.withClient(
                for: server,
                lanEndpointProvider: { _ in nil },
                managerFactory: { metadata in
                    IrohConnectionManager(iroh: metadata, provider: ReachableIrohProvider())
                },
                httpAvailabilityProbe: { _ in },
                operation: { _ in
                    await operationCount.increment()
                    throw IrohTransportError.unavailable("operation failed")
                }
            )
        }

        #expect(await operationCount.value == 1)
    }

    @Test func configureIrohOnlyRequiresTunnelMetadataAndFailsClosed() async {
        let conn = ServerConnection()
        var proxyStarted = false
        let result = await conn.configureForUse(
            credentials: makeTestIrohOnlyCredentials(alpns: ["oppi/pair/1"]),
            routeMode: .irohOnly,
            serverInfoBootstrap: successfulServerInfoBootstrap,
            irohProxyFactory: { _, _ in
                proxyStarted = true
                return (nil, URL(string: "http://127.0.0.1:41992")!)
            }
        )

        #expect(!result)
        #expect(!proxyStarted)
        #expect(conn.credentials == nil)
        #expect(conn.apiClient == nil)
        #expect(conn.wsClient == nil)
    }

    @Test func disconnectSessionClearsActiveId() {
        let scenario = EventFlowServerConnectionScenario()
        let conn = scenario.connection

        conn.disconnectSession()

        // After disconnect, messages should be ignored (no active session)
        scenario.whenHandle(.connected(session: makeTestSession(status: .busy)))
        #expect(conn.sessionStore.sessions.isEmpty)
    }

    @Test func flushAndSuspendDelivers() {
        let scenario = EventFlowServerConnectionScenario()

        scenario
            .whenHandle(.agentStart)
            .whenHandle(.textDelta(delta: "buffered"))
            .whenFlush()

        #expect(scenario.timelineItemCount(of: .assistantMessage) == 1)
    }

    @Test func requestStateUsesDispatchSendHook() async throws {
        let conn = ServerConnection()
        var sawGetState = false

        conn._sendMessageForTesting = { message in
            if case .getState = message {
                sawGetState = true
            }
        }

        try await conn.requestState()
        #expect(sawGetState)
    }

    @Test func isConnectedDefaultFalse() {
        let conn = ServerConnection()
        #expect(!conn.isConnected)
    }

    @Test func switchServerConfiguresNewServer() {
        let conn = ServerConnection()
        let creds = ServerCredentials(
            host: "studio.ts.net", port: 7749, token: "sk_studio",
            name: "studio", serverFingerprint: "sha256:studio-fp"
        )
        guard let server = PairedServer(from: creds) else {
            Issue.record("Expected PairedServer to be created from credentials")
            return
        }

        let result = conn.switchServer(to: server)
        #expect(result == true)
        #expect(conn.currentServerId == "sha256:studio-fp")
        #expect(conn.serverResourceStore.activeServerId == "sha256:studio-fp")
        #expect(conn.apiClient != nil)
    }

    @Test func switchServerSkipsIfAlreadyTargeting() {
        let conn = ServerConnection()
        let creds = ServerCredentials(
            host: "studio.ts.net", port: 7749, token: "sk_a",
            name: "studio", serverFingerprint: "sha256:same-fp"
        )
        guard let server = PairedServer(from: creds) else {
            Issue.record("Expected PairedServer to be created from credentials")
            return
        }

        _ = conn.switchServer(to: server)
        let result = conn.switchServer(to: server)
        #expect(result == true)
        #expect(conn.currentServerId == "sha256:same-fp")
    }

    @Test func switchServerChangesTarget() {
        let conn = ServerConnection()
        let creds1 = ServerCredentials(
            host: "studio.ts.net", port: 7749, token: "sk_a",
            name: "studio", serverFingerprint: "sha256:fp-a"
        )
        let creds2 = ServerCredentials(
            host: "mini.ts.net", port: 7749, token: "sk_b",
            name: "mini", serverFingerprint: "sha256:fp-b"
        )
        guard let server1 = PairedServer(from: creds1),
              let server2 = PairedServer(from: creds2)
        else {
            Issue.record("Expected PairedServer values to be created from credentials")
            return
        }

        _ = conn.switchServer(to: server1)
        #expect(conn.currentServerId == "sha256:fp-a")

        _ = conn.switchServer(to: server2)
        #expect(conn.currentServerId == "sha256:fp-b")
    }

    @Test func currentServerIdNilByDefault() {
        let conn = ServerConnection()
        #expect(conn.currentServerId == nil)
    }

    private func makeHTTPOnlyCredentials() -> ServerCredentials {
        ServerCredentials(
            host: "my-server.tail00000.ts.net",
            port: 7749,
            token: "dt_test",
            name: "Test",
            scheme: .https,
            serverFingerprint: "sha256:SERVERFINGERPRINTABCDEF",
            tlsCertFingerprint: "sha256:TLSFINGERPRINTABCDEF"
        )
    }

    private func makeLANCandidate(host: String) -> LANDiscoveredEndpoint {
        LANDiscoveredEndpoint(
            host: host,
            port: 7749,
            serverFingerprintPrefix: "SERVERFINGERPRINT",
            tlsCertFingerprintPrefix: "TLSFINGERPRINT"
        )
    }

    private func makeIrohPreferredCredentials(
        iroh: IrohServerTransport = IrohServerTransport(
            version: 2,
            nodeId: "preferred-node-id",
            alpns: [IrohTunnelProtocol.alpn],
            addressMode: .nodeId,
            ticket: nil
        ),
        tlsFingerprint: String? = "sha256:preferred-tls-fp"
    ) -> ServerCredentials {
        ServerCredentials(
            host: "preferred.tailnet.ts.net",
            port: 7749,
            token: "dt_preferred",
            name: "Preferred",
            scheme: .https,
            serverFingerprint: "sha256:preferred-server-fp",
            tlsCertFingerprint: tlsFingerprint,
            transports: ServerTransports(
                preference: .irohPreferred,
                iroh: iroh,
                http: HTTPServerTransport(
                    host: "preferred.tailnet.ts.net",
                    port: 7749,
                    scheme: .https,
                    tlsCertFingerprint: tlsFingerprint
                )
            )
        )
    }

}

private actor LANCandidateProbeGate {
    let reachableHost: String
    let firstProbeResult: Bool?
    private var firstProbeContinuation: CheckedContinuation<Void, Never>?
    private(set) var firstProbeIsWaiting = false
    private(set) var probeCount = 0

    init(reachableHost: String, firstProbeResult: Bool? = nil) {
        self.reachableHost = reachableHost
        self.firstProbeResult = firstProbeResult
    }

    func probe(_ selection: EndpointSelection) async -> Bool {
        probeCount += 1
        if probeCount == 1 {
            firstProbeIsWaiting = true
            await withCheckedContinuation { firstProbeContinuation = $0 }
            if let firstProbeResult { return firstProbeResult }
        }
        return selection.baseURL.host == reachableHost
    }

    func waitForFirstProbe() async {
        while !firstProbeIsWaiting {
            await Task.yield()
        }
    }

    func releaseFirstProbe() {
        firstProbeContinuation?.resume()
        firstProbeContinuation = nil
    }
}

private actor LANProbeCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

@MainActor
private final class SupersededSetupGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isWaiting = false

    func waitUntilReleased() async {
        isWaiting = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor CoalescedBoundaryIrohProvider: IrohConnectionProviding {
    private var secondEvidenceContinuation: CheckedContinuation<Void, Never>?
    private(set) var evidenceCount = 0
    private(set) var secondEvidenceIsWaiting = false

    func openStream(alpn: String) async throws -> any IrohByteStream {
        throw IrohTransportError.unavailable("unused")
    }

    func selectedPathEvidence(alpn: String) async throws -> IrohSelectedPathEvidence? {
        evidenceCount += 1
        if evidenceCount == 2 {
            secondEvidenceIsWaiting = true
            await withCheckedContinuation { secondEvidenceContinuation = $0 }
        }
        if evidenceCount == 3 {
            throw IrohTransportError.unavailable("coalesced boundary detects outage")
        }
        return IrohSelectedPathEvidence(isIP: true, isRelay: false, rttMs: 1)
    }

    func releaseSecondEvidence() {
        secondEvidenceContinuation?.resume()
        secondEvidenceContinuation = nil
    }

    func suspendConnections() async {}
    func shutdown() async {}
}

private actor SecondEvidenceGateIrohProvider: IrohConnectionProviding {
    private var evidenceCount = 0
    private var secondEvidenceContinuation: CheckedContinuation<Void, Never>?
    private(set) var secondEvidenceIsWaiting = false
    private(set) var shutdownCount = 0

    func openStream(alpn: String) async throws -> any IrohByteStream {
        throw IrohTransportError.unavailable("unused")
    }

    func selectedPathEvidence(alpn: String) async throws -> IrohSelectedPathEvidence? {
        evidenceCount += 1
        if evidenceCount == 2 {
            secondEvidenceIsWaiting = true
            await withCheckedContinuation { continuation in
                secondEvidenceContinuation = continuation
            }
        }
        return IrohSelectedPathEvidence(isIP: true, isRelay: false, rttMs: 1)
    }

    func releaseSecondEvidence() {
        secondEvidenceContinuation?.resume()
        secondEvidenceContinuation = nil
    }

    func suspendConnections() async {}

    func shutdown() async {
        shutdownCount += 1
    }
}

private actor GatedReachableEvidenceIrohProvider: IrohConnectionProviding {
    private var evidenceContinuation: CheckedContinuation<Void, Never>?
    private(set) var evidenceIsWaiting = false
    private(set) var suspendCount = 0
    private(set) var shutdownCount = 0

    func openStream(alpn: String) async throws -> any IrohByteStream {
        throw IrohTransportError.unavailable("unused")
    }

    func selectedPathEvidence(alpn: String) async throws -> IrohSelectedPathEvidence? {
        evidenceIsWaiting = true
        await withCheckedContinuation { continuation in
            evidenceContinuation = continuation
        }
        return IrohSelectedPathEvidence(isIP: true, isRelay: false, rttMs: 1)
    }

    func releaseEvidence() {
        evidenceContinuation?.resume()
        evidenceContinuation = nil
    }

    func suspendConnections() async {
        suspendCount += 1
    }

    func shutdown() async {
        shutdownCount += 1
    }
}

private actor GatedUnavailableShutdownIrohProvider: IrohConnectionProviding {
    private var shutdownContinuation: CheckedContinuation<Void, Never>?
    private(set) var shutdownIsWaiting = false

    func openStream(alpn: String) async throws -> any IrohByteStream {
        throw IrohTransportError.unavailable("unused")
    }

    func selectedPathEvidence(alpn: String) async throws -> IrohSelectedPathEvidence? {
        throw IrohTransportError.unavailable("path unavailable")
    }

    func suspendConnections() async {}

    func shutdown() async {
        shutdownIsWaiting = true
        await withCheckedContinuation { continuation in
            shutdownContinuation = continuation
        }
    }

    func releaseShutdown() {
        shutdownContinuation?.resume()
        shutdownContinuation = nil
    }
}

private actor EstablishedStreamFailureRecoveryProvider: IrohConnectionProviding {
    private var failureHandler: (@Sendable () async -> Void)?
    private(set) var suspendCount = 0
    private(set) var shutdownCount = 0

    func openStream(alpn: String) async throws -> any IrohByteStream {
        throw IrohTransportError.unavailable("unused")
    }

    func selectedPathEvidence(alpn: String) async throws -> IrohSelectedPathEvidence? {
        IrohSelectedPathEvidence(isIP: true, isRelay: false, rttMs: 1)
    }

    func setEstablishedStreamFailureHandler(
        _ handler: (@Sendable () async -> Void)?
    ) async {
        failureHandler = handler
    }

    func failEstablishedStream() async {
        await failureHandler?()
    }

    func suspendConnections() async {
        suspendCount += 1
    }

    func shutdown() async {
        shutdownCount += 1
    }
}

private actor TrackingReachableIrohProvider: IrohConnectionProviding {
    private(set) var shutdownCount = 0

    func openStream(alpn: String) async throws -> any IrohByteStream {
        throw IrohTransportError.unavailable("unused")
    }

    func selectedPathEvidence(alpn: String) async throws -> IrohSelectedPathEvidence? {
        IrohSelectedPathEvidence(isIP: true, isRelay: false, rttMs: 1)
    }

    func suspendConnections() async {}

    func shutdown() async {
        shutdownCount += 1
    }
}

private actor TrackingTerminalIrohProvider: IrohConnectionProviding {
    private(set) var shutdownCount = 0

    func openStream(alpn: String) async throws -> any IrohByteStream {
        throw IrohTransportError.authentication("unused")
    }

    func selectedPathEvidence(alpn: String) async throws -> IrohSelectedPathEvidence? {
        throw IrohTransportError.authentication("peer rejected")
    }

    func suspendConnections() async {}

    func shutdown() async {
        shutdownCount += 1
    }
}

private actor SequencedPathEvidenceProvider: IrohConnectionProviding {
    private var results: [Result<IrohSelectedPathEvidence?, IrohTransportError>]
    private(set) var shutdownCount = 0

    init(results: [Result<IrohSelectedPathEvidence?, IrohTransportError>]) {
        self.results = results
    }

    func openStream(alpn: String) async throws -> any IrohByteStream {
        throw IrohTransportError.unavailable("unused")
    }

    func selectedPathEvidence(alpn: String) async throws -> IrohSelectedPathEvidence? {
        guard !results.isEmpty else {
            throw IrohTransportError.unavailable("test evidence exhausted")
        }
        return try results.removeFirst().get()
    }

    func suspendConnections() async {}

    func shutdown() async {
        shutdownCount += 1
    }
}

private actor LifecycleOperationCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private struct UnavailableIrohProvider: IrohConnectionProviding {
    func openStream(alpn: String) async throws -> any IrohByteStream {
        throw IrohTransportError.unavailable("relay unreachable")
    }

    func selectedPathEvidence(alpn: String) async throws -> IrohSelectedPathEvidence? {
        throw IrohTransportError.unavailable("relay unreachable")
    }

    func suspendConnections() async {}
    func shutdown() async {}
}

private struct ReachableIrohProvider: IrohConnectionProviding {
    func openStream(alpn: String) async throws -> any IrohByteStream {
        throw IrohTransportError.unavailable("unused")
    }

    func selectedPathEvidence(alpn: String) async throws -> IrohSelectedPathEvidence? {
        IrohSelectedPathEvidence(isIP: true, isRelay: false, rttMs: 1)
    }

    func suspendConnections() async {}
    func shutdown() async {}
}

@Suite("ServerConnection Automatic Routing", .serialized)
@MainActor
struct ServerConnectionAutomaticRoutingTests {
    @Test func deadHTTPCandidateUsesFastDeadlineBeforeIrohGetsIndependentBudget() async throws {
        let conn = ServerConnection()
        let probe = CandidateDeadlineProbe()
        let irohDeadlineGate = CandidateDeadlineGate()
        let localURL = try #require(URL(string: "http://127.0.0.1:42112"))
        conn.setDiscoveredLANEndpoint(LANDiscoveredEndpoint(
            host: "192.168.1.42",
            port: 7749,
            serverFingerprintPrefix: "preferred-server-fp",
            tlsCertFingerprintPrefix: "preferred-tls-fp"
        ))

        let configured = await conn.configureForUse(
            credentials: makeIrohPreferredCredentials(),
            routeMode: .automatic,
            httpBootstrapDeadline: {
                probe.recordHTTPFactory()
                return .init(wait: { probe.expireHTTPDeadline() })
            },
            irohCandidateDeadline: {
                probe.recordIrohFactory()
                return .init(wait: { try await irohDeadlineGate.waitForExpiry() })
            },
            serverInfoBootstrap: { client, deadline in
                if await client.baseURL.host != "127.0.0.1" {
                    try await deadline.waitForExpiry()
                    throw URLError(.timedOut)
                }
                return successfulServerInfo()
            },
            irohProxyFactory: { _, _ in
                await irohDeadlineGate.waitUntilStarted()
                return (nil, localURL)
            }
        )

        #expect(configured)
        #expect(conn.transportPath == .iroh)
        #expect(probe.httpFactoryCount == 2)
        #expect(probe.httpDeadlineExpirations == 2)
        #expect(probe.irohFactoryCount == 1)
        #expect(ServerConnection.httpCandidateTimeoutDefault == .milliseconds(1_500))
        #expect(ServerConnection.irohReachabilityTimeoutDefault == .seconds(8))
    }

    @Test func automaticPairedBootstrapRetainsWinningClientWithoutIrohDial() async throws {
        let conn = ServerConnection()
        var constructedClients: [APIClient] = []
        var irohDials = 0

        let configured = await conn.configureForUse(
            credentials: makeIrohPreferredCredentials(),
            routeMode: .automatic,
            apiClientFactory: { environment, observer in
                let client = APIClient(environment: environment, availabilityObserver: observer)
                constructedClients.append(client)
                return client
            },
            serverInfoBootstrap: { _, _ in successfulServerInfo() },
            irohProxyFactory: { _, _ in
                irohDials += 1
                throw IrohTransportError.unavailable("must not dial")
            }
        )

        #expect(configured)
        #expect(conn.transportPath == .paired)
        #expect(irohDials == 0)
        #expect(constructedClients.count == 1)
        #expect(conn.apiClient === constructedClients[0])
    }

    @Test func automaticPairedAvailabilityFailureDialsIrohOnce() async throws {
        let conn = ServerConnection()
        let localURL = try #require(URL(string: "http://127.0.0.1:42101"))
        var irohDials = 0

        let configured = await conn.configureForUse(
            credentials: makeIrohPreferredCredentials(),
            routeMode: .automatic,
            serverInfoBootstrap: { client, _ in
                if await client.baseURL.host == "preferred.tailnet.ts.net" {
                    throw URLError(.cannotConnectToHost)
                }
                return successfulServerInfo()
            },
            irohProxyFactory: { _, _ in
                irohDials += 1
                return (nil, localURL)
            }
        )

        #expect(configured)
        #expect(irohDials == 1)
        #expect(conn.transportPath == .iroh)
    }

    @Test(arguments: [
        RoutingBootstrapFailure.authentication,
        .decoding,
    ])
    func automaticDoesNotRouteAroundAuthenticationOrDecodeFailure(
        failure: RoutingBootstrapFailure
    ) async {
        let conn = ServerConnection()
        var irohDials = 0

        let configured = await conn.configureForUse(
            credentials: makeIrohPreferredCredentials(),
            routeMode: .automatic,
            serverInfoBootstrap: { _, _ in try failure.throwError() },
            irohProxyFactory: { _, _ in
                irohDials += 1
                throw IrohTransportError.unavailable("must not dial")
            }
        )

        #expect(!configured)
        #expect(irohDials == 0)
        #expect(conn.apiClient == nil)
    }

    @Test func APIAvailabilityObserverAcceptsCurrentClientAndIgnoresStaleClient() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let localURL = try #require(URL(string: "http://127.0.0.1:42102"))
        var observers: [APIClientAvailabilityObserver] = []
        var irohDials = 0
        conn._refreshAfterAutomaticIrohRecoveryForTesting = {}

        let factory: ServerConnectionAPIClientFactory = { environment, observer in
            if let observer { observers.append(observer) }
            return APIClient(environment: environment, availabilityObserver: observer)
        }
        let bootstrap: ServerConnectionInfoBootstrap = { _, _ in successfulServerInfo() }
        let irohFactory: @MainActor (IrohServerTransport, String) async throws -> (IrohConnectionManager?, URL) = { _, _ in
            irohDials += 1
            return (nil, localURL)
        }

        #expect(await conn.configureForUse(
            credentials: credentials,
            routeMode: .automatic,
            apiClientFactory: factory,
            serverInfoBootstrap: bootstrap,
            irohProxyFactory: irohFactory
        ))
        let staleObserver = try #require(observers.first)

        #expect(await conn.reconfigureForExplicitRetry(
            credentials: credentials,
            routeMode: .automatic,
            apiClientFactory: factory,
            serverInfoBootstrap: bootstrap,
            irohProxyFactory: irohFactory
        ))
        let currentObserver = try #require(observers.last)

        await staleObserver(.cannotConnectToHost)
        #expect(irohDials == 0)

        await currentObserver(.cannotConnectToHost)
        #expect(irohDials == 1)
        #expect(conn.transportPath == .iroh)
    }

    @Test func failedRouteExclusionIsRestoredOnLaterExplicitRetry() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        var pairedBootstraps = 0
        var irohDials = 0
        var currentObserver: APIClientAvailabilityObserver?
        conn._refreshAfterAutomaticIrohRecoveryForTesting = {}

        #expect(await conn.configureForUse(
            credentials: credentials,
            routeMode: .automatic,
            apiClientFactory: { environment, observer in
                currentObserver = observer
                return APIClient(environment: environment, availabilityObserver: observer)
            },
            serverInfoBootstrap: { client, _ in
                if await client.baseURL.host == "preferred.tailnet.ts.net" {
                    pairedBootstraps += 1
                }
                return successfulServerInfo()
            },
            irohProxyFactory: { _, _ in
                irohDials += 1
                throw IrohTransportError.unavailable("iroh unavailable")
            }
        ))

        await currentObserver?(.cannotConnectToHost)
        #expect(pairedBootstraps == 1, "The failed paired route is excluded from its recovery pass")
        #expect(irohDials == 1)
        #expect(conn.apiClient == nil)

        #expect(await conn.reconfigureForExplicitRetry(
            credentials: credentials,
            routeMode: .automatic,
            serverInfoBootstrap: { client, _ in
                if await client.baseURL.host == "preferred.tailnet.ts.net" {
                    pairedBootstraps += 1
                }
                return successfulServerInfo()
            },
            irohProxyFactory: { _, _ in
                irohDials += 1
                throw IrohTransportError.unavailable("must not dial after paired recovers")
            }
        ))
        #expect(pairedBootstraps == 2)
        #expect(irohDials == 1)
        #expect(conn.transportPath == .paired)
    }

    @Test func healthyForegroundIrohRecyclesInPlaceWithoutRouteHandoff() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let metadata = try #require(credentials.transports.iroh)
        let provider = ForegroundRecoveryIrohProvider()
        let manager = IrohConnectionManager(iroh: metadata, provider: provider)

        #expect(await conn.configureForUse(
            credentials: credentials,
            routeMode: .automatic,
            serverInfoBootstrap: { client, _ in
                if await client.baseURL.host == "preferred.tailnet.ts.net" {
                    throw URLError(.cannotConnectToHost)
                }
                return successfulServerInfo()
            },
            irohProxyFactory: { _, token in
                (manager, try await manager.startProxy(token: token))
            }
        ))
        let originalAPIClient = conn.apiClient
        let originalGeneration = conn.persistentStreamGenerationForTesting

        let result = await conn.resetIrohTransportForForegroundRecoveryIfNeeded()

        #expect(result == .retained)
        #expect(conn.transportPath == .iroh)
        #expect(conn.apiClient === originalAPIClient)
        #expect(conn.persistentStreamGenerationForTesting == originalGeneration)
        #expect(await provider.recycleCount == 1)
        #expect(await provider.evidenceCount == 2)
    }

    @Test func changedForegroundLoopbackRestoresFocusedAndAppEventStreamsWithOneRebuild() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let metadata = try #require(credentials.transports.iroh)
        let provider = ForegroundRecoveryIrohProvider()
        let manager = IrohConnectionManager(iroh: metadata, provider: provider)
        let firstURL = try #require(URL(string: "http://127.0.0.1:42113"))
        let secondURL = try #require(URL(string: "http://127.0.0.1:42114"))
        var commits: [ConnectionTransportPath] = []
        var appEventStarts = 0
        var focusedConnects = 0
        var focusedStreamContinuations: [AsyncStream<StreamFrameEvent>.Continuation] = []
        conn._onCommittedCompositionForTesting = { commits.append($0) }
        conn._startAppEventStreamForTesting = { _ in appEventStarts += 1 }
        conn._connectStreamForTesting = {
            focusedConnects += 1
            return AsyncStream { focusedStreamContinuations.append($0) }
        }
        conn._foregroundIrohProxyURLForTesting = { _, _ in secondURL }

        #expect(await conn.configureForUse(
            credentials: credentials,
            routeMode: .irohOnly,
            serverInfoBootstrap: { _, _ in successfulServerInfo(appEventStream: true) },
            irohProxyFactory: { _, _ in (manager, firstURL) }
        ))
        conn._setActiveSessionIdForTesting("session-foreground")
        conn.prepareFocusedSessionStreamEndpointForTesting(
            sessionId: "session-foreground",
            workspaceId: "workspace-foreground"
        )
        let sessionEvents = AsyncStream<SessionStreamEvent> { continuation in
            conn.sessionEventContinuations["session-foreground"] = continuation
        }
        conn.connectStream()
        let originalGeneration = conn.persistentStreamGenerationForTesting

        let result = await conn.resetIrohTransportForForegroundRecoveryIfNeeded()

        #expect(result == .retained)
        #expect(commits == [.iroh, .iroh])
        #expect(conn.persistentStreamGenerationForTesting == originalGeneration + 1)
        #expect(conn.focusedSessionStreamEndpointKind == "split_session")
        #expect(conn.focusedSessionStreamURLForTesting?.port == 42114)
        #expect(conn.sessionEventContinuations["session-foreground"] != nil)
        #expect(focusedConnects == 2)
        #expect(appEventStarts == 2)
        #expect(focusedStreamContinuations.count == 2)
        _ = sessionEvents
        conn.disconnectAppEventStream()
        conn.disconnectStream()
    }

    @Test func failedForegroundIrohRecycleWalksAlternativesOnce() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let metadata = try #require(credentials.transports.iroh)
        let provider = ForegroundRecoveryIrohProvider(recycleFails: true)
        let manager = IrohConnectionManager(iroh: metadata, provider: provider)
        let localURL = try #require(URL(string: "http://127.0.0.1:42105"))
        var pairedAvailable = false
        var pairedBootstraps = 0
        var irohDials = 0

        #expect(await conn.configureForUse(
            credentials: credentials,
            routeMode: .automatic,
            serverInfoBootstrap: { client, _ in
                if await client.baseURL.host == "preferred.tailnet.ts.net" {
                    pairedBootstraps += 1
                    if !pairedAvailable { throw URLError(.cannotConnectToHost) }
                }
                return successfulServerInfo()
            },
            irohProxyFactory: { _, _ in
                irohDials += 1
                return (manager, localURL)
            }
        ))
        pairedAvailable = true

        let recovery = await conn.resetIrohTransportForForegroundRecoveryIfNeeded()
        #expect(recovery == .availabilityFailure)
        await conn.reevaluateIrohPreferredTransportAtBoundary(excluding: [.iroh])

        #expect(conn.transportPath == .paired)
        #expect(pairedBootstraps == 2)
        #expect(irohDials == 1)
        #expect(await provider.recycleCount == 1)
    }

    @Test func committedTransitionPreservesFocusedIntentAndAdvancesOneComposition() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let localURL = try #require(URL(string: "http://127.0.0.1:42106"))
        var pairedObserver: APIClientAvailabilityObserver?
        var commits: [ConnectionTransportPath] = []
        conn._refreshAfterAutomaticIrohRecoveryForTesting = {}
        conn._onCommittedCompositionForTesting = { commits.append($0) }

        #expect(await conn.configureForUse(
            credentials: credentials,
            routeMode: .automatic,
            apiClientFactory: { environment, observer in
                if environment.baseURL.host == "preferred.tailnet.ts.net" {
                    pairedObserver = observer
                }
                return APIClient(environment: environment, availabilityObserver: observer)
            },
            serverInfoBootstrap: { _, _ in successfulServerInfo() },
            irohProxyFactory: { _, _ in (nil, localURL) }
        ))
        conn.prepareFocusedSessionStreamEndpointForTesting(
            sessionId: "session-composition",
            workspaceId: "workspace-composition"
        )
        let initialGeneration = conn.persistentStreamGenerationForTesting

        await pairedObserver?(.cannotConnectToHost)

        #expect(commits == [.paired, .iroh])
        #expect(conn.persistentStreamGenerationForTesting == initialGeneration + 1)
        #expect(conn.focusedSessionStreamEndpointKind == "split_session")
        #expect(conn.focusedSessionStreamURLForTesting?.port == 42106)
    }

    @Test func HTTPSOnlyNeverDialsIroh() async {
        let conn = ServerConnection()
        var irohDials = 0

        let configured = await conn.configureForUse(
            credentials: makeIrohPreferredCredentials(),
            routeMode: .httpsOnly,
            serverInfoBootstrap: { _, _ in successfulServerInfo() },
            irohProxyFactory: { _, _ in
                irohDials += 1
                throw IrohTransportError.unavailable("must not dial")
            }
        )

        #expect(configured)
        #expect(conn.transportPath == .paired)
        #expect(irohDials == 0)
    }

    @Test func IrohOnlyNeverConstructsHTTPClient() async throws {
        let conn = ServerConnection()
        let localURL = try #require(URL(string: "http://127.0.0.1:42107"))
        var constructedHosts: [String] = []

        let configured = await conn.configureForUse(
            credentials: makeIrohPreferredCredentials(),
            routeMode: .irohOnly,
            apiClientFactory: { environment, observer in
                constructedHosts.append(environment.baseURL.host ?? "")
                return APIClient(environment: environment, availabilityObserver: observer)
            },
            serverInfoBootstrap: { _, _ in successfulServerInfo() },
            irohProxyFactory: { _, _ in (nil, localURL) }
        )

        #expect(configured)
        #expect(constructedHosts == ["127.0.0.1"])
        #expect(conn.transportPath == .iroh)
    }

    @Test func concurrentCurrentAvailabilityReportsCoalesceIntoOneRouteWalk() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let localURL = try #require(URL(string: "http://127.0.0.1:42108"))
        let gate = RoutingGate()
        var observer: APIClientAvailabilityObserver?
        var irohDials = 0
        conn._refreshAfterAutomaticIrohRecoveryForTesting = {}

        #expect(await conn.configureForUse(
            credentials: credentials,
            routeMode: .automatic,
            apiClientFactory: { environment, nextObserver in
                if environment.baseURL.host == "preferred.tailnet.ts.net" {
                    observer = nextObserver
                }
                return APIClient(environment: environment, availabilityObserver: nextObserver)
            },
            serverInfoBootstrap: { _, _ in successfulServerInfo() },
            irohProxyFactory: { _, _ in
                irohDials += 1
                await gate.waitUntilReleased()
                return (nil, localURL)
            }
        ))
        let currentObserver = try #require(observer)

        let first = Task { await currentObserver(.cannotConnectToHost) }
        await gate.waitUntilBlocked()
        await currentObserver(.networkConnectionLost)
        await gate.release()
        await first.value

        #expect(irohDials == 1)
        #expect(conn.transportPath == .iroh)
    }

    @Test func supersededIrohCandidateCleansOnlyLosingManager() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let metadata = try #require(credentials.transports.iroh)
        let firstProvider = TrackingIrohProvider()
        let winningProvider = TrackingIrohProvider()
        let firstManager = IrohConnectionManager(iroh: metadata, provider: firstProvider)
        let winningManager = IrohConnectionManager(iroh: metadata, provider: winningProvider)
        let firstURL = try #require(URL(string: "http://127.0.0.1:42109"))
        let winningURL = try #require(URL(string: "http://127.0.0.1:42110"))
        let gate = RoutingGate()

        let first = Task { @MainActor in
            await conn.configureForUse(
                credentials: credentials,
                routeMode: .irohOnly,
                serverInfoBootstrap: { _, _ in successfulServerInfo() },
                irohProxyFactory: { _, _ in
                    await gate.waitUntilReleased()
                    return (firstManager, firstURL)
                }
            )
        }
        await gate.waitUntilBlocked()

        let winner = await conn.configureForUse(
            credentials: credentials,
            routeMode: .irohOnly,
            serverInfoBootstrap: { _, _ in successfulServerInfo() },
            irohProxyFactory: { _, _ in (winningManager, winningURL) }
        )
        await gate.release()
        let superseded = await first.value

        #expect(winner)
        #expect(!superseded)
        #expect(await firstProvider.shutdownCount == 1)
        #expect(await winningProvider.shutdownCount == 0)
        #expect(await conn.apiClient?.baseURL == winningURL)
    }

    @Test func routeNeutralRecoveryKeepsFiveAttemptBudgetAndSenderFence() async {
        #expect(ServerConnection.automaticIrohRecoveryMaximumAttempts == 5)
        #expect(ServerConnection.automaticIrohRecoveryBackoff(attempt: 1) == 1)
        #expect(ServerConnection.automaticIrohRecoveryBackoff(attempt: 2) == 2)
        #expect(ServerConnection.automaticIrohRecoveryBackoff(attempt: 3) == 4)
        #expect(ServerConnection.automaticIrohRecoveryBackoff(attempt: 4) == 8)
        #expect(ServerConnection.automaticIrohRecoveryBackoff(attempt: 5) == 16)

        let conn = ServerConnection()
        conn._setActiveSessionIdForTesting("session-1")
        var attempts = 0
        conn._sendMessageForTesting = { _ in
            attempts += 1
            conn.sender.advanceTransportGeneration()
        }
        await #expect(throws: CancellationError.self) {
            try await conn.sendPrompt("do not replay")
        }
        #expect(attempts == 1)
    }
}

enum RoutingBootstrapFailure: Sendable {
    case authentication
    case decoding

    func throwError() throws -> ServerInfo {
        switch self {
        case .authentication:
            throw APIError.server(status: 401, message: "unauthorized")
        case .decoding:
            throw DecodingError.dataCorrupted(.init(
                codingPath: [],
                debugDescription: "invalid server info"
            ))
        }
    }
}

@MainActor
private func makeIrohPreferredCredentials() -> ServerCredentials {
    ServerCredentials(
        host: "preferred.tailnet.ts.net",
        port: 7749,
        token: "dt_preferred",
        name: "Preferred",
        scheme: .https,
        serverFingerprint: "sha256:preferred-server-fp",
        tlsCertFingerprint: "sha256:preferred-tls-fp",
        transports: ServerTransports(
            preference: .irohPreferred,
            iroh: IrohServerTransport(
                version: 2,
                nodeId: "preferred-node-id",
                alpns: [IrohTunnelProtocol.alpn],
                addressMode: .nodeId,
                ticket: nil
            ),
            http: HTTPServerTransport(
                host: "preferred.tailnet.ts.net",
                port: 7749,
                scheme: .https,
                tlsCertFingerprint: "sha256:preferred-tls-fp"
            )
        )
    )
}

@MainActor
private func successfulServerInfoBootstrap(
    _: APIClient,
    _: APIClient.BootstrapDeadline
) async throws -> ServerInfo {
    successfulServerInfo()
}

@MainActor
private func successfulServerInfo(appEventStream: Bool = false) -> ServerInfo {
    ServerInfo(
        name: "Test",
        version: "1.0.0",
        uptime: 1,
        os: "darwin",
        arch: "arm64",
        hostname: "test.local",
        nodeVersion: "22",
        piVersion: "1",
        configVersion: 1,
        identity: nil,
        runtimeUpdate: nil,
        uploadProtocol: nil,
        images: nil,
        capabilities: .init(
            sessionStream: .init(version: 1),
            dictationStream: nil,
            appEventStream: appEventStream ? .init(version: 1) : nil,
            extensionNativeUI: nil,
            controlSessions: nil
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

private final class CandidateDeadlineProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _httpFactoryCount = 0
    private var _httpDeadlineExpirations = 0
    private var _irohFactoryCount = 0

    var httpFactoryCount: Int { lock.withLock { _httpFactoryCount } }
    var httpDeadlineExpirations: Int { lock.withLock { _httpDeadlineExpirations } }
    var irohFactoryCount: Int { lock.withLock { _irohFactoryCount } }

    func recordHTTPFactory() {
        lock.withLock { _httpFactoryCount += 1 }
    }

    func expireHTTPDeadline() {
        lock.withLock { _httpDeadlineExpirations += 1 }
    }

    func recordIrohFactory() {
        lock.withLock { _irohFactoryCount += 1 }
    }

}

private actor CandidateDeadlineGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForExpiry() async throws {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        try await Task.sleep(for: .seconds(3_600))
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
}

private actor RoutingGate {
    private var blocked = false
    private var released = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilReleased() async {
        blocked = true
        blockedWaiters.forEach { $0.resume() }
        blockedWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilBlocked() async {
        guard !blocked else { return }
        await withCheckedContinuation { blockedWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private actor TrackingIrohProvider: IrohConnectionProviding {
    private(set) var shutdownCount = 0

    func openStream(alpn: String) async throws -> any IrohByteStream {
        throw IrohTransportError.unavailable("unused")
    }

    func selectedPathEvidence(alpn: String) async throws -> IrohSelectedPathEvidence? {
        IrohSelectedPathEvidence(isIP: true, isRelay: false, rttMs: 1)
    }

    func suspendConnections() async {}
    func shutdown() async { shutdownCount += 1 }
}

private actor ForegroundRecoveryIrohProvider: IrohConnectionProviding {
    let recycleFails: Bool
    private(set) var recycleCount = 0
    private(set) var evidenceCount = 0

    init(recycleFails: Bool = false) {
        self.recycleFails = recycleFails
    }

    func openStream(alpn: String) async throws -> any IrohByteStream {
        throw IrohTransportError.unavailable("unused")
    }

    func selectedPathEvidence(alpn: String) async throws -> IrohSelectedPathEvidence? {
        evidenceCount += 1
        return IrohSelectedPathEvidence(isIP: true, isRelay: false, rttMs: 1)
    }

    func recycleEndpoint() async throws {
        recycleCount += 1
        if recycleFails {
            throw IrohTransportError.unavailable("recycle failed")
        }
    }

    func suspendConnections() async {}
    func shutdown() async {}
}
