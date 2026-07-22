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

    @Test func activeIrohTunnelFailureEscalatesToPreferredHTTPFallback() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let metadata = try #require(credentials.transports.iroh)
        let provider = ReachableThenUnavailableOpenProvider()
        let manager = IrohConnectionManager(iroh: metadata, provider: provider)
        let localURL = try #require(URL(string: "http://127.0.0.1:42011"))

        let configured = await conn.configureForUse(
            credentials: credentials,
            irohReachabilityTimeout: .milliseconds(20),
            irohProxyFactory: { _, _ in (manager, localURL) }
        )
        #expect(configured)
        #expect(conn.transportPath == .iroh)

        await #expect(throws: IrohTransportError.unavailable("active tunnel unavailable")) {
            _ = try await manager.openTunnelStream(timeout: .milliseconds(20))
        }
        for _ in 0..<100 where conn.transportPath == .iroh {
            await Task.yield()
        }

        #expect(conn.transportPath == .paired)
        #expect(conn.irohFallbackActive)
        #expect(await conn.apiClient?.baseURL.host == "preferred.tailnet.ts.net")
    }

    @Test func establishedIrohStreamFailureRecyclesEndpointBeforeHTTPFallback() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let metadata = try #require(credentials.transports.iroh)
        let provider = EstablishedStreamFailureRecoveryProvider()
        let manager = IrohConnectionManager(iroh: metadata, provider: provider)
        let localURL = try #require(URL(string: "http://127.0.0.1:42013"))

        #expect(await conn.configureForUse(
            credentials: credentials,
            irohProxyFactory: { _, _ in (manager, localURL) }
        ))
        let originalAPIClient = conn.apiClient

        await provider.failEstablishedStream()

        #expect(await provider.endpointRecycleCount == 1)
        #expect(await provider.suspendCount == 1)
        #expect(conn.transportPath == .iroh)
        #expect(!conn.irohFallbackActive)
        #expect(conn.apiClient !== originalAPIClient)
        #expect(await conn.apiClient?.baseURL == localURL)
    }

    @Test func establishedIrohRecoveryProbeFallsBackWhenPeerRemainsUnavailable() async throws {
        let conn = ServerConnection()
        let credentials = makeIrohPreferredCredentials()
        let metadata = try #require(credentials.transports.iroh)
        let provider = EstablishedStreamFailureRecoveryProvider(failRecoveryProbe: true)
        let manager = IrohConnectionManager(iroh: metadata, provider: provider)
        let localURL = try #require(URL(string: "http://127.0.0.1:42014"))

        #expect(await conn.configureForUse(
            credentials: credentials,
            irohProxyFactory: { _, _ in (manager, localURL) }
        ))

        await provider.failEstablishedStream()

        #expect(await provider.endpointRecycleCount == 1)
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

private actor ReachableThenUnavailableOpenProvider: IrohConnectionProviding {
    func openStream(alpn: String) async throws -> any IrohByteStream {
        throw IrohTransportError.unavailable("active tunnel unavailable")
    }

    func selectedPathEvidence(alpn: String) async throws -> IrohSelectedPathEvidence? {
        // A dial/path probe can look healthy while opening a real stream fails.
        IrohSelectedPathEvidence(isIP: true, isRelay: false, rttMs: 1)
    }

    func suspendConnections() async {}
    func shutdown() async {}
}

private actor EstablishedStreamFailureRecoveryProvider: IrohConnectionProviding {
    private let failRecoveryProbe: Bool
    private var failureHandler: (@Sendable () async -> Void)?
    private var evidenceCount = 0
    private(set) var endpointRecycleCount = 0
    private(set) var suspendCount = 0

    init(failRecoveryProbe: Bool = false) {
        self.failRecoveryProbe = failRecoveryProbe
    }

    func openStream(alpn: String) async throws -> any IrohByteStream {
        throw IrohTransportError.unavailable("unused")
    }

    func selectedPathEvidence(alpn: String) async throws -> IrohSelectedPathEvidence? {
        evidenceCount += 1
        if failRecoveryProbe, evidenceCount > 1 {
            throw IrohTransportError.unavailable("peer remains unavailable")
        }
        return IrohSelectedPathEvidence(isIP: true, isRelay: false, rttMs: 1)
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

    func recycleEndpoint() async throws {
        endpointRecycleCount += 1
    }

    func shutdown() async {}
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
