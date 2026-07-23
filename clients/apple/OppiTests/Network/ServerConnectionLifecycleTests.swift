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

    @Test func configureIrohPreferredUsesVerifiedLANBeforeMalformedIroh() async throws {
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
            lanReachabilityProbe: { _, _ in true },
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

    @Test func unavailableVerifiedLANContinuesToIrohBeforeHTTPFallback() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let metadata = try #require(credentials.transports.iroh)
        let provider = TrackingReachableIrohProvider()
        let manager = IrohConnectionManager(iroh: metadata, provider: provider)
        let localURL = try #require(URL(string: "http://127.0.0.1:42015"))
        conn.setDiscoveredLANEndpoint(LANDiscoveredEndpoint(
            host: "192.168.1.42",
            port: 7749,
            serverFingerprintPrefix: "preferred-server-fp",
            tlsCertFingerprintPrefix: "preferred-tls-fp"
        ))
        var probeCount = 0

        let configured = await conn.configureForUse(
            credentials: credentials,
            lanReachabilityProbe: { selection, _ in
                probeCount += 1
                #expect(selection.transportPath == .lan)
                return false
            },
            irohProxyFactory: { _, _ in (manager, localURL) }
        )

        #expect(configured)
        #expect(probeCount == 1)
        #expect(conn.transportPath == .iroh)
        #expect(!conn.irohFallbackActive)
        #expect(await conn.apiClient?.baseURL == localURL)
    }

    @Test func unavailableLANAndIrohFallBackToSignedHTTPNotLAN() async {
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
            lanReachabilityProbe: { _, _ in false },
            irohProxyFactory: { _, _ in
                throw IrohTransportError.unavailable("relay unreachable")
            }
        )

        #expect(configured)
        #expect(conn.transportPath == .paired)
        #expect(conn.irohFallbackActive)
        #expect(await conn.apiClient?.baseURL.host == "preferred.tailnet.ts.net")
    }

    @Test func configureIrohPreferredFallsBackOnlyWhenIrohIsUnavailable() async throws {
        let unavailable = ServerConnection()
        let credentials = makeIrohPreferredCredentials()

        let configured = await unavailable.configureForUse(
            credentials: credentials,
            irohProxyFactory: { _, _ in
                throw IrohTransportError.unavailable("relay unreachable")
            }
        )

        #expect(configured)
        #expect(unavailable.transportPath == .paired)
        #expect(unavailable.irohFallbackActive)
        #expect(await unavailable.apiClient?.baseURL.host == "preferred.tailnet.ts.net")

        let terminal = ServerConnection()
        let rejected = await terminal.configureForUse(
            credentials: credentials,
            irohProxyFactory: { _, _ in
                throw IrohTransportError.authentication("token rejected")
            }
        )

        #expect(!rejected)
        #expect(terminal.apiClient == nil)
        #expect(!terminal.irohFallbackActive)
    }

    @Test func irohPreferredFallsBackWhenReachabilityProbeExceedsDeadline() async throws {
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
                irohProxyFactory: { _, _ in (manager, localURL) }
            )
        }
        while !(await provider.evidenceIsWaiting) {
            await Task.yield()
        }

        let configured = await configurationTask.value

        #expect(configured)
        #expect(conn.transportPath == .paired)
        #expect(conn.irohFallbackActive)
        #expect(await conn.apiClient?.baseURL.host == "preferred.tailnet.ts.net")
        #expect(await provider.suspendCount == 1, "A timed-out probe must discard the poisoned provider connection")
        await provider.releaseEvidence()
    }

    @Test func establishedIrohFailureImmediatelyPerformsFullRebuildAndRefresh() async throws {
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
        var refreshCalls = 0
        conn._refreshAfterAutomaticIrohRecoveryForTesting = {
            refreshCalls += 1
        }

        #expect(await conn.configureForUse(
            credentials: credentials,
            irohProxyFactory: { _, _ in
                factoryCalls += 1
                return factoryCalls == 1
                    ? (firstManager, firstURL)
                    : (replacementManager, replacementURL)
            }
        ))
        let originalAPIClient = conn.apiClient

        await firstProvider.failEstablishedStream()

        #expect(factoryCalls == 2)
        #expect(await firstProvider.shutdownCount == 1)
        #expect(await firstProvider.suspendCount == 0)
        #expect(conn.apiClient !== originalAPIClient)
        #expect(await conn.apiClient?.baseURL == replacementURL)
        #expect(refreshCalls == 1)
    }

    @Test func repeatedAutomaticIrohRebuildsUseBackoffUntilAStreamReconnects() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let metadata = try #require(credentials.transports.iroh)
        let managers = [
            IrohConnectionManager(iroh: metadata, provider: TrackingReachableIrohProvider()),
            IrohConnectionManager(iroh: metadata, provider: TrackingReachableIrohProvider()),
            IrohConnectionManager(iroh: metadata, provider: TrackingReachableIrohProvider()),
            IrohConnectionManager(iroh: metadata, provider: TrackingReachableIrohProvider()),
        ]
        let urls = try [42039, 42040, 42041, 42042].map { port in
            try #require(URL(string: "http://127.0.0.1:\(port)"))
        }
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        var factoryCalls = 0
        conn._automaticIrohRecoveryNowForTesting = { now }
        conn._refreshAfterAutomaticIrohRecoveryForTesting = {}

        #expect(await conn.configureForUse(
            credentials: credentials,
            irohProxyFactory: { _, _ in
                defer { factoryCalls += 1 }
                return (managers[factoryCalls], urls[factoryCalls])
            }
        ))

        await conn.handlePersistentStreamHealthFailure(.establishedStreamFailure)
        #expect(factoryCalls == 2)

        await conn.handlePersistentStreamHealthFailure(.reconnectThreshold(attempt: 6))
        #expect(factoryCalls == 2, "A repeated failure inside the first cooldown must not rebuild again")

        now = now.addingTimeInterval(1)
        await conn.handlePersistentStreamHealthFailure(.reconnectThreshold(attempt: 7))
        #expect(factoryCalls == 3)

        conn.setAppEventStreamTransportState(.connected)
        await conn.handlePersistentStreamHealthFailure(.establishedStreamFailure)
        #expect(factoryCalls == 4, "A proven stream reconnect resets automatic recovery backoff")
    }

    @Test func automaticIrohRecoveryUsesFiveAttemptExponentialBudget() {
        #expect(ServerConnection.automaticIrohRecoveryMaximumAttempts == 5)
        #expect(ServerConnection.automaticIrohRecoveryBackoff(attempt: 1) == 1)
        #expect(ServerConnection.automaticIrohRecoveryBackoff(attempt: 2) == 2)
        #expect(ServerConnection.automaticIrohRecoveryBackoff(attempt: 3) == 4)
        #expect(ServerConnection.automaticIrohRecoveryBackoff(attempt: 4) == 8)
        #expect(ServerConnection.automaticIrohRecoveryBackoff(attempt: 5) == 16)
    }

    @Test func automaticIrohRecoveryStopsAfterFiveAttemptsUntilAStreamReconnects() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let metadata = try #require(credentials.transports.iroh)
        let managers = (0..<7).map { _ in
            IrohConnectionManager(iroh: metadata, provider: TrackingReachableIrohProvider())
        }
        let urls = try (42060..<42067).map { port in
            try #require(URL(string: "http://127.0.0.1:\(port)"))
        }
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        var factoryCalls = 0
        conn._automaticIrohRecoveryNowForTesting = { now }
        conn._refreshAfterAutomaticIrohRecoveryForTesting = {}

        #expect(await conn.configureForUse(
            credentials: credentials,
            irohProxyFactory: { _, _ in
                defer { factoryCalls += 1 }
                return (managers[factoryCalls], urls[factoryCalls])
            }
        ))

        for delay in [0.0, 1.0, 2.0, 4.0, 8.0] {
            now = now.addingTimeInterval(delay)
            await conn.handlePersistentStreamHealthFailure(.establishedStreamFailure)
        }
        #expect(factoryCalls == 6, "The initial setup plus five automatic rebuilds should run")

        now = now.addingTimeInterval(16)
        await conn.handlePersistentStreamHealthFailure(.establishedStreamFailure)
        #expect(factoryCalls == 6, "The sixth automatic rebuild must remain blocked")

        conn.setAppEventStreamTransportState(.connected)
        await conn.handlePersistentStreamHealthFailure(.establishedStreamFailure)
        #expect(factoryCalls == 7, "A proven stream reconnect restores the automatic retry budget")
    }

    @Test func terminalFailureDuringAutomaticFullRebuildRemainsFailClosed() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let metadata = try #require(credentials.transports.iroh)
        let provider = EstablishedStreamFailureRecoveryProvider()
        let manager = IrohConnectionManager(iroh: metadata, provider: provider)
        let localURL = try #require(URL(string: "http://127.0.0.1:42048"))
        var factoryCalls = 0

        #expect(await conn.configureForUse(
            credentials: credentials,
            irohProxyFactory: { _, _ in
                factoryCalls += 1
                if factoryCalls == 1 { return (manager, localURL) }
                throw IrohTransportError.authentication("peer rejected replacement")
            }
        ))

        await provider.failEstablishedStream()
        #expect(factoryCalls == 2)
        #expect(conn.apiClient == nil)
        #expect(conn.wsClient == nil)
        #expect(!conn.irohFallbackActive)

        await conn.handlePersistentStreamHealthFailure(.reconnectThreshold(attempt: 7))
        #expect(factoryCalls == 2, "Terminal integrity failures must not enter automatic retry")
    }

    @Test func IrohOnlyEstablishedStreamFailureFullRebuildsWithoutHTTPFallback() async throws {
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
            irohProxyFactory: { _, _ in
                factoryCalls += 1
                return factoryCalls == 1
                    ? (firstManager, firstURL)
                    : (replacementManager, replacementURL)
            }
        ))
        let originalAPIClient = conn.apiClient

        await firstProvider.failEstablishedStream()

        #expect(factoryCalls == 2)
        #expect(await firstProvider.shutdownCount == 1)
        #expect(conn.transportPath == .iroh)
        #expect(!conn.irohFallbackActive)
        #expect(conn.apiClient !== originalAPIClient)
        #expect(await conn.apiClient?.baseURL == replacementURL)
    }

    @Test func serverScopedFullRebuildLeavesOtherIrohManagerUntouched() async throws {
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
            irohProxyFactory: { _, _ in
                firstFactoryCalls += 1
                return firstFactoryCalls == 1
                    ? (firstManager, firstURL)
                    : (replacementManager, replacementURL)
            }
        ))
        #expect(await secondConnection.configureForUse(
            credentials: secondCredentials,
            irohProxyFactory: { _, _ in (secondManager, secondURL) }
        ))
        let secondAPIClient = secondConnection.apiClient

        await firstProvider.failEstablishedStream()

        #expect(firstFactoryCalls == 2)
        #expect(await firstProvider.shutdownCount == 1)
        #expect(await secondProvider.suspendCount == 0)
        #expect(await secondProvider.shutdownCount == 0)
        #expect(secondConnection.apiClient === secondAPIClient)
        #expect(secondConnection.transportPath == .iroh)
    }

    @Test func automaticFullRebuildFallsBackWhenFreshIrohSetupIsUnavailable() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let metadata = try #require(credentials.transports.iroh)
        let provider = EstablishedStreamFailureRecoveryProvider()
        let manager = IrohConnectionManager(iroh: metadata, provider: provider)
        let localURL = try #require(URL(string: "http://127.0.0.1:42014"))
        var factoryCalls = 0
        conn._refreshAfterAutomaticIrohRecoveryForTesting = {}

        #expect(await conn.configureForUse(
            credentials: credentials,
            irohProxyFactory: { _, _ in
                factoryCalls += 1
                if factoryCalls == 1 { return (manager, localURL) }
                throw IrohTransportError.unavailable("fresh Iroh setup unavailable")
            }
        ))

        await provider.failEstablishedStream()

        #expect(factoryCalls == 2)
        #expect(await provider.shutdownCount == 1)
        #expect(conn.transportPath == .paired)
        #expect(conn.irohFallbackActive)
        #expect(await conn.apiClient?.baseURL.host == "preferred.tailnet.ts.net")
    }

    @Test func irohPreferredRetriesStickyFallbackAtExplicitBoundary() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let localURL = try #require(URL(string: "http://127.0.0.1:41993"))
        var attempts = 0

        let configured = await conn.configureForUse(
            credentials: credentials,
            irohProxyFactory: { _, _ in
                attempts += 1
                if attempts == 1 {
                    throw IrohTransportError.unavailable("initial outage")
                }
                return (nil, localURL)
            }
        )
        #expect(configured)
        #expect(conn.transportPath == .paired)
        #expect(conn.irohFallbackActive)

        await conn.reevaluateIrohPreferredTransportAtBoundary()

        #expect(attempts == 2)
        #expect(conn.transportPath == .iroh)
        #expect(!conn.irohFallbackActive)
        #expect(await conn.apiClient?.baseURL == localURL)
        #expect(await conn.apiClient?.environment.pinnedCertificateFingerprint == nil)
    }

    @Test func unhealthyStickyFallbackRetriesIrohWithoutWaitingForForegroundBoundary() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let localURL = try #require(URL(string: "http://127.0.0.1:42019"))
        var attempts = 0

        #expect(await conn.configureForUse(
            credentials: credentials,
            irohProxyFactory: { _, _ in
                attempts += 1
                if attempts == 1 {
                    throw IrohTransportError.unavailable("initial outage")
                }
                return (nil, localURL)
            }
        ))
        #expect(conn.transportPath == .paired)
        #expect(conn.irohFallbackActive)

        await conn.handlePersistentStreamHealthFailure(.reconnectThreshold(attempt: 4))

        #expect(attempts == 2)
        #expect(conn.transportPath == .iroh)
        #expect(!conn.irohFallbackActive)
        #expect(await conn.apiClient?.baseURL == localURL)
    }

    @Test func IrohPingTimeoutPerformsFullRebuild() async throws {
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
            irohProxyFactory: { _, _ in
                factoryCalls += 1
                return factoryCalls == 1
                    ? (firstManager, firstURL)
                    : (replacementManager, replacementURL)
            }
        ))

        await conn.handlePersistentStreamHealthFailure(.pingTimeout)

        #expect(factoryCalls == 2)
        #expect(await firstProvider.shutdownCount == 1)
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
            lanReachabilityProbe: { _, _ in true },
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

    @Test func focusedWebSocketHealthCallbackPerformsFullIrohRebuild() async throws {
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
            irohProxyFactory: { _, _ in
                factoryCalls += 1
                return factoryCalls == 1
                    ? (firstManager, firstURL)
                    : (replacementManager, replacementURL)
            }
        ))

        await conn.reportFocusedStreamHealthFailureForTesting(.pingTimeout)

        #expect(factoryCalls == 2)
        #expect(await firstProvider.shutdownCount == 1)
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
            irohProxyFactory: { _, _ in (firstManager, firstURL) }
        ))
        let staleGeneration = conn.persistentStreamGenerationForTesting
        #expect(await conn.configureForUse(
            credentials: credentials,
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

    @Test func concurrentPersistentStreamFailuresCoalesceIntoOneFullRebuild() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let metadata = try #require(credentials.transports.iroh)
        let firstProvider = EstablishedStreamFailureRecoveryProvider()
        let replacementProvider = TrackingReachableIrohProvider()
        let firstManager = IrohConnectionManager(iroh: metadata, provider: firstProvider)
        let replacementManager = IrohConnectionManager(iroh: metadata, provider: replacementProvider)
        let firstURL = try #require(URL(string: "http://127.0.0.1:42021"))
        let replacementURL = try #require(URL(string: "http://127.0.0.1:42047"))
        let gate = SupersededSetupGate()
        var factoryCalls = 0
        conn._refreshAfterAutomaticIrohRecoveryForTesting = {}

        #expect(await conn.configureForUse(
            credentials: credentials,
            irohProxyFactory: { _, _ in
                factoryCalls += 1
                if factoryCalls == 2 {
                    await gate.waitUntilReleased()
                }
                return factoryCalls == 1
                    ? (firstManager, firstURL)
                    : (replacementManager, replacementURL)
            }
        ))

        let firstRecovery = Task { @MainActor in
            await firstProvider.failEstablishedStream()
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

        #expect(factoryCalls == 2)
        #expect(await firstProvider.shutdownCount == 1)
        #expect(conn.transportPath == .iroh)
        #expect(await conn.apiClient?.baseURL == replacementURL)
    }

    @Test func concurrentFailureRetainsFollowUpWhenRecoveryDoesNotReplaceStreams() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let gate = SupersededSetupGate()
        var attempts = 0

        #expect(await conn.configureForUse(
            credentials: credentials,
            irohProxyFactory: { _, _ in
                attempts += 1
                if attempts == 2 {
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
        gate.release()
        await firstRecovery.value
        await secondRecovery.value

        #expect(attempts == 3)
        #expect(conn.transportPath == .paired)
    }

    @Test func persistentHealthFailureDoesNotChangeHTTPOnlyConnection() async {
        let conn = ServerConnection()
        #expect(await conn.configureForUse(credentials: makeHTTPOnlyCredentials()))
        let originalAPIClient = conn.apiClient

        await conn.handlePersistentStreamHealthFailure(.reconnectThreshold(attempt: 7))

        #expect(conn.transportPath == .paired)
        #expect(conn.apiClient === originalAPIClient)
    }

    @Test func LANDiscoveredDuringInitialIrohProbeWinsBeforeAdoption() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let metadata = try #require(credentials.transports.iroh)
        let provider = GatedReachableEvidenceIrohProvider()
        let manager = IrohConnectionManager(iroh: metadata, provider: provider)
        let localURL = try #require(URL(string: "http://127.0.0.1:42007"))

        let configurationTask = Task { @MainActor in
            await conn.configureForUse(
                credentials: credentials,
                lanReachabilityProbe: { _, _ in true },
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
        let configured = await configurationTask.value

        #expect(configured)
        #expect(conn.transportPath == .lan)
        #expect(await provider.shutdownCount == 1)
    }

    @Test func LANDiscoveredDuringActiveIrohProbeWinsAtBoundary() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let metadata = try #require(credentials.transports.iroh)
        let provider = SecondEvidenceGateIrohProvider()
        let manager = IrohConnectionManager(iroh: metadata, provider: provider)
        let localURL = try #require(URL(string: "http://127.0.0.1:42008"))
        let configured = await conn.configureForUse(
            credentials: credentials,
            lanReachabilityProbe: { _, _ in true },
            irohProxyFactory: { _, _ in (manager, localURL) }
        )
        #expect(configured)
        #expect(conn.transportPath == .iroh)

        let boundaryTask = Task { @MainActor in
            await conn.reevaluateIrohPreferredTransportAtBoundary()
        }
        while !(await provider.secondEvidenceIsWaiting) {
            await Task.yield()
        }
        conn.setDiscoveredLANEndpoint(LANDiscoveredEndpoint(
            host: "192.168.1.42",
            port: 7749,
            serverFingerprintPrefix: "preferred-server-fp",
            tlsCertFingerprintPrefix: "preferred-tls-fp"
        ))
        await provider.releaseSecondEvidence()
        await boundaryTask.value

        #expect(conn.transportPath == .lan)
        #expect(await provider.shutdownCount == 1)
    }

    @Test func LANDiscoveredDuringBoundaryProbeStillWinsOverIroh() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let metadata = try #require(credentials.transports.iroh)
        let provider = GatedReachableEvidenceIrohProvider()
        let manager = IrohConnectionManager(iroh: metadata, provider: provider)
        let localURL = try #require(URL(string: "http://127.0.0.1:42006"))
        var attempts = 0

        let configured = await conn.configureForUse(
            credentials: credentials,
            lanReachabilityProbe: { _, _ in true },
            irohProxyFactory: { _, _ in
                attempts += 1
                if attempts == 1 {
                    throw IrohTransportError.unavailable("initial outage")
                }
                return (manager, localURL)
            }
        )
        #expect(configured)
        #expect(conn.transportPath == .paired)

        let boundaryTask = Task { @MainActor in
            await conn.reevaluateIrohPreferredTransportAtBoundary()
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
        await boundaryTask.value

        #expect(conn.transportPath == .lan)
        #expect(await provider.shutdownCount == 1)
    }

    @Test func overlappingBoundaryReevaluationsCoalesceInsteadOfDroppingRecovery() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let metadata = try #require(credentials.transports.iroh)
        let provider = CoalescedBoundaryIrohProvider()
        let manager = IrohConnectionManager(iroh: metadata, provider: provider)
        let localURL = try #require(URL(string: "http://127.0.0.1:42012"))

        #expect(await conn.configureForUse(
            credentials: credentials,
            irohProxyFactory: { _, _ in (manager, localURL) }
        ))

        let firstBoundary = Task { @MainActor in
            await conn.reevaluateIrohPreferredTransportAtBoundary()
        }
        while !(await provider.secondEvidenceIsWaiting) {
            await Task.yield()
        }
        await conn.reevaluateIrohPreferredTransportAtBoundary()
        await provider.releaseSecondEvidence()
        await firstBoundary.value

        #expect(await provider.evidenceCount == 3)
        #expect(conn.transportPath == .paired)
        #expect(conn.irohFallbackActive)
    }

    @Test func irohPreferredFallsBackWhenBoundaryProbeBecomesUnavailable() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let localURL = try #require(URL(string: "http://127.0.0.1:41994"))
        let provider = SequencedPathEvidenceProvider(results: [
            .success(IrohSelectedPathEvidence(isIP: true, isRelay: false, rttMs: 1)),
            .failure(IrohTransportError.unavailable("path lost")),
        ])
        let metadata = try #require(credentials.transports.iroh)
        let manager = IrohConnectionManager(iroh: metadata, provider: provider)

        let configured = await conn.configureForUse(
            credentials: credentials,
            irohProxyFactory: { _, _ in (manager, localURL) }
        )
        #expect(configured)
        #expect(conn.transportPath == .iroh)

        await conn.reevaluateIrohPreferredTransportAtBoundary()

        #expect(conn.transportPath == .paired)
        #expect(conn.irohFallbackActive)
        #expect(await conn.apiClient?.baseURL.host == "preferred.tailnet.ts.net")
    }

    @Test func verifiedLANReplacesIrohAtExplicitBoundary() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let localURL = try #require(URL(string: "http://127.0.0.1:41995"))
        let configured = await conn.configureForUse(
            credentials: credentials,
            lanReachabilityProbe: { _, _ in true },
            irohProxyFactory: { _, _ in (nil, localURL) }
        )
        #expect(configured)
        #expect(conn.transportPath == .iroh)

        conn.setDiscoveredLANEndpoint(LANDiscoveredEndpoint(
            host: "192.168.1.42",
            port: 7749,
            serverFingerprintPrefix: "preferred-server-fp",
            tlsCertFingerprintPrefix: "preferred-tls-fp"
        ))
        #expect(conn.transportPath == .iroh, "Healthy Iroh is not interrupted immediately")

        await conn.reevaluateIrohPreferredTransportAtBoundary()

        #expect(conn.transportPath == .lan)
        #expect(!conn.irohFallbackActive)
    }

    @Test func leavingVerifiedLANRetriesIrohAtBoundary() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let localURL = try #require(URL(string: "http://127.0.0.1:41997"))
        conn.setDiscoveredLANEndpoint(LANDiscoveredEndpoint(
            host: "192.168.1.42",
            port: 7749,
            serverFingerprintPrefix: "preferred-server-fp",
            tlsCertFingerprintPrefix: "preferred-tls-fp"
        ))
        let configured = await conn.configureForUse(
            credentials: credentials,
            lanReachabilityProbe: { _, _ in true },
            irohProxyFactory: { _, _ in (nil, localURL) }
        )
        #expect(configured)
        #expect(conn.transportPath == .lan)

        conn.setDiscoveredLANEndpoint(nil)
        for _ in 0..<100 where conn.transportPath != .iroh {
            await Task.yield()
        }

        #expect(conn.transportPath == .iroh)
        #expect(await conn.apiClient?.baseURL == localURL)
    }

    @Test func terminalBoundaryFailureDisablesStickyHTTPFallback() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        var attempts = 0

        let configured = await conn.configureForUse(
            credentials: credentials,
            irohProxyFactory: { _, _ in
                attempts += 1
                if attempts == 1 {
                    throw IrohTransportError.unavailable("initial outage")
                }
                throw IrohTransportError.authentication("token rejected")
            }
        )
        #expect(configured)
        #expect(conn.irohFallbackActive)
        #expect(conn.apiClient != nil)

        await conn.reevaluateIrohPreferredTransportAtBoundary()

        #expect(attempts == 2)
        #expect(!conn.irohFallbackActive)
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
        let initiallyConfigured = await conn.configureForUse(
            credentials: credentials,
            irohProxyFactory: { _, _ in
                attempts += 1
                if attempts == 1 {
                    throw IrohTransportError.unavailable("initial outage")
                }
                throw IrohTransportError.authentication("token rejected")
            }
        )
        #expect(initiallyConfigured)

        await conn.reevaluateIrohPreferredTransportAtBoundary()
        #expect(conn.apiClient == nil)

        let rejected = await conn.configureForUse(
            credentials: credentials,
            irohProxyFactory: { _, _ in
                throw IrohTransportError.authentication("still rejected")
            }
        )
        #expect(!rejected)

        conn.setDiscoveredLANEndpoint(LANDiscoveredEndpoint(
            host: "192.168.1.42",
            port: 7749,
            serverFingerprintPrefix: "preferred-server-fp",
            tlsCertFingerprintPrefix: "preferred-tls-fp"
        ))
        #expect(conn.apiClient == nil, "A failed explicit retry must not clear terminal lockout")
    }

    @Test func terminalExplicitReconfigurationInvalidatesUsableFallback() async {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let initiallyConfigured = await conn.configureForUse(
            credentials: credentials,
            irohProxyFactory: { _, _ in
                throw IrohTransportError.unavailable("initial outage")
            }
        )
        #expect(initiallyConfigured)
        #expect(conn.irohFallbackActive)
        #expect(conn.apiClient != nil)

        let rejected = await conn.configureForUse(
            credentials: credentials,
            irohProxyFactory: { _, _ in
                throw IrohTransportError.authentication("token rejected")
            }
        )

        #expect(!rejected)
        #expect(conn.apiClient == nil)
        #expect(conn.wsClient == nil)
        #expect(!conn.irohFallbackActive)
    }

    @Test func supersededAvailabilityFallbackCannotOverwriteNewerConfiguration() async throws {
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
                irohProxyFactory: { _, _ in (manager, localURL) }
            )
        }
        while !(await provider.shutdownIsWaiting) {
            await Task.yield()
        }

        let middleTask = Task { @MainActor in
            await conn.configureForUse(credentials: middleCredentials)
        }
        await Task.yield()
        let newestTask = Task { @MainActor in
            await conn.configureForUse(credentials: newestCredentials)
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

    @Test func unavailableLANCandidateDoesNotOverwritePairedFallback() async {
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
        var probeCount = 0
        #expect(await conn.configureForUse(
            credentials: credentials,
            lanReachabilityProbe: { _, _ in
                probeCount += 1
                return false
            }
        ))
        conn.setDiscoveredLANEndpoint(LANDiscoveredEndpoint(
            host: "192.168.1.42",
            port: 7749,
            serverFingerprintPrefix: "SERVERFINGERPRINT",
            tlsCertFingerprintPrefix: "TLSFINGERPRINT"
        ))
        while probeCount == 0 {
            await Task.yield()
        }
        await Task.yield()

        #expect(probeCount == 1)
        #expect(conn.transportPath == .paired)
        #expect(await conn.apiClient?.baseURL.host == "my-server.tail00000.ts.net")
    }

    @Test func replacingLANCandidateCannotAdoptStaleProbeResult() async {
        let conn = ServerConnection()
        let credentials = makeHTTPOnlyCredentials()
        let gate = LANCandidateProbeGate(
            reachableHost: "192.168.1.43",
            firstProbeResult: true
        )
        #expect(await conn.configureForUse(
            credentials: credentials,
            lanReachabilityProbe: { selection, _ in await gate.probe(selection) }
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
            lanReachabilityProbe: { selection, _ in await gate.probe(selection) },
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

    @Test func repeatedIdenticalLANCandidateStartsOneProbe() async {
        let conn = ServerConnection()
        let credentials = makeHTTPOnlyCredentials()
        let counter = LANProbeCounter()
        #expect(await conn.configureForUse(
            credentials: credentials,
            lanReachabilityProbe: { _, _ in
                await counter.increment()
                return true
            }
        ))
        let candidate = makeLANCandidate(host: "192.168.1.42")

        conn.setDiscoveredLANEndpoint(candidate)
        conn.setDiscoveredLANEndpoint(candidate)
        for _ in 0..<100 where conn.transportPath != .lan {
            await Task.yield()
        }

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
            lanReachabilityProbe: { _, _ in true },
            irohProxyFactory: { _, _ in (manager, localURL) }
        ))
        #expect(conn.transportPath == .iroh)

        conn.setDiscoveredLANEndpoint(LANDiscoveredEndpoint(
            host: "192.168.1.42",
            port: 7749,
            serverFingerprintPrefix: "preferred-server-fp",
            tlsCertFingerprintPrefix: "preferred-tls-fp"
        ))
        for _ in 0..<100 where conn.transportPath != .lan {
            await Task.yield()
        }

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
        var probeCount = 0
        #expect(await conn.configureForUse(
            credentials: credentials,
            lanReachabilityProbe: { _, _ in
                probeCount += 1
                return false
            },
            irohProxyFactory: { _, _ in (manager, localURL) }
        ))

        conn.setDiscoveredLANEndpoint(LANDiscoveredEndpoint(
            host: "192.168.1.42",
            port: 7749,
            serverFingerprintPrefix: "preferred-server-fp",
            tlsCertFingerprintPrefix: "preferred-tls-fp"
        ))
        while probeCount == 0 {
            await Task.yield()
        }
        await Task.yield()
        conn.setDiscoveredLANEndpoint(nil)
        await conn.reevaluateIrohPreferredTransportAtBoundary()

        #expect(conn.transportPath == .iroh)
        #expect(!conn.irohFallbackActive)
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
            lanReachabilityProbe: { _, _ in true }
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
            irohProxyFactory: { _, _ in (sharedManager, adoptedURL) }
        )
        gate.release()
        let firstResult = await firstTask.value

        #expect(secondResult)
        #expect(!firstResult)
        #expect(await provider.shutdownCount == 0)
        #expect(await conn.apiClient?.baseURL == adoptedURL)
    }

    @Test func leavingVerifiedLANUsesStickyHTTPOnlyAfterIrohUnavailable() async throws {
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
            lanReachabilityProbe: { _, _ in true },
            irohProxyFactory: { _, _ in
                throw IrohTransportError.unavailable("remote path unavailable")
            }
        )
        #expect(configured)
        #expect(conn.transportPath == .lan)

        conn.setDiscoveredLANEndpoint(nil)
        await conn.reevaluateIrohPreferredTransportAtBoundary(forceIrohRetry: true)

        #expect(conn.transportPath == .paired)
        #expect(conn.irohFallbackActive)
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
            lanReachabilityProbe: { _, _ in true }
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
            irohProxyFactory: { _, _ in (manager, localURL) }
        )
        #expect(configured)
        #expect(conn.transportPath == .iroh)

        let rejected = await conn.configureForUse(
            credentials: credentials,
            irohProxyFactory: { _, _ in
                throw IrohTransportError.authentication("rejected before manager return")
            }
        )

        #expect(!rejected)
        #expect(await provider.shutdownCount == 1)
        #expect(conn.apiClient == nil)
        #expect(conn.wsClient == nil)
    }

    @Test func terminalActiveIrohFailureShutsDownManager() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let localURL = try #require(URL(string: "http://127.0.0.1:41999"))
        let provider = SequencedPathEvidenceProvider(results: [
            .success(IrohSelectedPathEvidence(isIP: true, isRelay: false, rttMs: 1)),
            .failure(IrohTransportError.authentication("peer rejected")),
        ])
        let metadata = try #require(credentials.transports.iroh)
        let manager = IrohConnectionManager(iroh: metadata, provider: provider)
        let configured = await conn.configureForUse(
            credentials: credentials,
            irohProxyFactory: { _, _ in (manager, localURL) }
        )
        #expect(configured)

        await conn.reevaluateIrohPreferredTransportAtBoundary()

        #expect(await provider.shutdownCount == 1)
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

    @Test func shortLivedClientFallsBackBeforeRunningOperation() async throws {
        let credentials = makeIrohPreferredCredentials()
        let server = try #require(PairedServer(from: credentials))
        let operationCount = LifecycleOperationCounter()

        let selectedHost = try await ServerTransportAPIClient.withClient(
            for: server,
            lanEndpointProvider: { _ in nil },
            managerFactory: { metadata in
                IrohConnectionManager(iroh: metadata, provider: UnavailableIrohProvider())
            },
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
            operation: { api in await api.baseURL.port }
        )

        #expect(selectedPort == 8443)
    }

    @Test func shortLivedClientRejectsUnreachableLANBeforeRunningOperation() async throws {
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
            operation: { api in
                await operationCount.increment()
                return await api.baseURL.host
            }
        )

        #expect(await operationCount.value == 1)
        #expect(selectedHost == "127.0.0.1")
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
