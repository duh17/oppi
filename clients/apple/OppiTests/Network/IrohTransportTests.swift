import Foundation
import IrohLib
import Network
import Testing
@testable import Oppi

@Suite("Iroh transport policy and protocol")
struct IrohTransportTests {
    @Test func preferredAndOnlyAuthorizeIrohCandidates() throws {
        let preferred = credentials(preference: .irohPreferred, includeHTTP: true)
        let only = credentials(preference: .irohOnly, includeHTTP: false)

        #expect(try ServerTransportPlanResolver.candidates(
            credentials: preferred,
            mode: .automatic,
            discoveredLANEndpoint: nil
        ).map(Self.routeKind) == [.paired, .iroh])
        #expect(try ServerTransportPlanResolver.candidates(
            credentials: only,
            mode: .automatic,
            discoveredLANEndpoint: nil
        ).map(Self.routeKind) == [.iroh])
    }

    @Test func preferredWithoutTunnelALPNStillBuildsHTTPAndIrohCandidates() throws {
        let preferred = credentials(
            preference: .irohPreferred,
            includeHTTP: true,
            alpns: ["oppi/pair/1"]
        )
        let only = credentials(
            preference: .irohOnly,
            includeHTTP: false,
            alpns: ["oppi/pair/1"]
        )

        // Candidate build must not validate unused Iroh metadata. Walk-time
        // validation fails closed when Iroh is actually selected.
        #expect(try ServerTransportPlanResolver.candidates(
            credentials: preferred,
            mode: .automatic,
            discoveredLANEndpoint: nil
        ).map(Self.routeKind) == [.paired, .iroh])
        let onlyCandidates = try ServerTransportPlanResolver.candidates(
            credentials: only,
            mode: .automatic,
            discoveredLANEndpoint: nil
        )
        #expect(onlyCandidates.map(Self.routeKind) == [.iroh])
        guard case .iroh(let transport) = onlyCandidates[0] else {
            Issue.record("irohOnly must produce an Iroh candidate")
            return
        }
        #expect(throws: IrohTransportError.unsupportedALPN(IrohTunnelProtocol.alpn)) {
            try IrohPeerValidator.validate(transport, requiredALPN: IrohTunnelProtocol.alpn)
        }
    }

    @Test func validatesTicketAndConnectedPeerAgainstSignedNodeID() throws {
        #expect(throws: IrohTransportError.ticketPeerMismatch(expected: "signed", actual: "ticket")) {
            try IrohPeerValidator.validateTicketPeer(expectedNodeID: "signed", ticketNodeID: "ticket")
        }
        #expect(throws: IrohTransportError.remotePeerMismatch(expected: "signed", actual: "remote")) {
            try IrohPeerValidator.validateConnectedPeer(expectedNodeID: "signed", remoteNodeID: "remote")
        }
        try IrohPeerValidator.validateTicketPeer(expectedNodeID: "signed", ticketNodeID: "signed")
        try IrohPeerValidator.validateConnectedPeer(expectedNodeID: "signed", remoteNodeID: "signed")
    }

    @Test func preferredTunnelProtocolErrorsDoNotDowngradeToHTTP() throws {
        let invalid = credentials(
            preference: .irohPreferred,
            includeHTTP: true,
            alpns: [IrohTunnelProtocol.alpn],
            addressMode: .ticket
        )
        // Building candidates must leave malformed later Iroh metadata alone so a
        // healthy HTTPS candidate can still win. Validation happens at walk time.
        let candidates = try ServerTransportPlanResolver.candidates(
            credentials: invalid,
            mode: .automatic,
            discoveredLANEndpoint: nil
        )
        #expect(candidates.map(Self.routeKind) == [.paired, .iroh])
        guard case .iroh(let transport) = candidates[1] else {
            Issue.record("Expected trailing Iroh candidate")
            return
        }
        #expect(throws: IrohTransportError.missingTicket) {
            try IrohPeerValidator.validate(transport, requiredALPN: IrohTunnelProtocol.alpn)
        }
    }

    @Test func signedPreferencesMapToAuthorizedTransportSets() {
        #expect(credentials(preference: .httpOnly, includeHTTP: true)
            .transports.authorizedTransports == [.https])
        #expect(credentials(preference: .irohOnly, includeHTTP: false)
            .transports.authorizedTransports == [.iroh])
        #expect(credentials(preference: .irohPreferred, includeHTTP: true)
            .transports.authorizedTransports == [.https, .iroh])
    }

    @Test func persistedHTTPOnlyCredentialGrantRemovesIrohCandidate() throws {
        let serverJSON = """
        {
          "id": "sha256:grant-test",
          "name": "Grant Test",
          "host": "server.example.test",
          "port": 443,
          "scheme": "https",
          "token": "dt_http_only",
          "fingerprint": "sha256:grant-test",
          "transports": {
            "preference": "irohPreferred",
            "iroh": {
              "version": 2,
              "nodeId": "signed-node",
              "alpns": ["oppi/http/1"],
              "addressMode": "node-id"
            },
            "http": {
              "host": "server.example.test",
              "port": 443,
              "scheme": "https"
            }
          },
          "credentialTransports": ["http"],
          "routeMode": "automatic",
          "addedAt": 0,
          "sortOrder": 0
        }
        """
        let server = try JSONDecoder().decode(PairedServer.self, from: Data(serverJSON.utf8))

        #expect(try ServerTransportPlanResolver.candidates(
            credentials: server.credentials,
            mode: .automatic,
            discoveredLANEndpoint: nil
        ).map(Self.routeKind) == [.paired])
    }

    @Test func irohOnlyDoesNotEscapeToHTTPWhenCredentialGrantLacksIroh() throws {
        let serverJSON = """
        {
          "id": "sha256:iroh-only-grant-test",
          "name": "Grant Test",
          "host": "server.example.test",
          "port": 443,
          "scheme": "https",
          "token": "dt_http_only",
          "fingerprint": "sha256:iroh-only-grant-test",
          "transports": {
            "preference": "irohPreferred",
            "iroh": {
              "version": 2,
              "nodeId": "signed-node",
              "alpns": ["oppi/http/1"],
              "addressMode": "node-id"
            },
            "http": {
              "host": "server.example.test",
              "port": 443,
              "scheme": "https"
            }
          },
          "credentialTransports": ["http"],
          "routeMode": "irohOnly",
          "addedAt": 0,
          "sortOrder": 0
        }
        """
        let server = try JSONDecoder().decode(PairedServer.self, from: Data(serverJSON.utf8))

        #expect(try ServerTransportPlanResolver.candidates(
            credentials: server.credentials,
            mode: server.effectiveRouteMode,
            discoveredLANEndpoint: nil
        ).isEmpty)
    }

    @Test func candidateBuilderOrdersAutomaticAndRestrictsExplicitModes() throws {
        let credentials = credentials(
            preference: .irohPreferred,
            includeHTTP: true,
            tlsCertFingerprint: "sha256:leaf"
        )
        let lan = LANDiscoveredEndpoint(
            host: "192.0.2.10",
            port: 443,
            serverFingerprintPrefix: "server",
            tlsCertFingerprintPrefix: nil
        )

        #expect(try ServerTransportPlanResolver.candidates(
            credentials: credentials,
            mode: .automatic,
            discoveredLANEndpoint: lan
        ).map(Self.routeKind) == [.lan, .paired, .iroh])
        #expect(try ServerTransportPlanResolver.candidates(
            credentials: credentials,
            mode: .httpsOnly,
            discoveredLANEndpoint: lan
        ).map(Self.routeKind) == [.lan, .paired])
        #expect(try ServerTransportPlanResolver.candidates(
            credentials: credentials,
            mode: .irohOnly,
            discoveredLANEndpoint: lan
        ).map(Self.routeKind) == [.iroh])
    }

    @Test func HTTPSOnlyRejectsPlaintextHTTPWhileAutomaticKeepsAuthorizedCompatibility() throws {
        let plaintext = credentials(
            preference: .httpOnly,
            includeHTTP: true,
            httpScheme: .http
        )

        #expect(try ServerTransportPlanResolver.candidates(
            credentials: plaintext,
            mode: .automatic,
            discoveredLANEndpoint: nil
        ).map(Self.routeKind) == [.paired])
        #expect(throws: IrohTransportError.protocolViolation(
            "HTTPS Only requires a signed HTTPS endpoint"
        )) {
            _ = try ServerTransportPlanResolver.candidates(
                credentials: plaintext,
                mode: .httpsOnly,
                discoveredLANEndpoint: nil
            )
        }
    }

    @Test func candidateExclusionsApplyToOneBuildOnly() throws {
        let credentials = credentials(preference: .irohPreferred, includeHTTP: true)

        #expect(try ServerTransportPlanResolver.candidates(
            credentials: credentials,
            mode: .automatic,
            discoveredLANEndpoint: nil,
            excluding: [.paired]
        ).map(Self.routeKind) == [.iroh])
        #expect(try ServerTransportPlanResolver.candidates(
            credentials: credentials,
            mode: .automatic,
            discoveredLANEndpoint: nil
        ).map(Self.routeKind) == [.paired, .iroh])
    }

    private static func routeKind(_ plan: ServerTransportPlan) -> ServerRouteCandidateKind {
        switch plan {
        case .http(let endpoint):
            endpoint.transportPath == .lan ? .lan : .paired
        case .iroh:
            .iroh
        }
    }

    @Test func ticketModeRequiresTicketAndSupportedVersion() {
        let missingTicket = transport(addressMode: .ticket, ticket: nil)
        #expect(throws: IrohTransportError.missingTicket) {
            try IrohPeerValidator.validate(missingTicket, requiredALPN: IrohTunnelProtocol.alpn)
        }

        let unsupported = IrohServerTransport(
            version: 99,
            nodeId: "signed-node",
            alpns: [IrohTunnelProtocol.alpn],
            addressMode: .nodeId,
            ticket: nil
        )
        #expect(throws: IrohTransportError.unsupportedMetadataVersion(99)) {
            try IrohPeerValidator.validate(unsupported, requiredALPN: IrohTunnelProtocol.alpn)
        }
    }

    @Test func relayMetadataCanonicalizesAndTreatsEmptyAsPublicDefault() throws {
        let decoded = try JSONDecoder().decode(
            IrohServerTransport.self,
            from: Data("""
            {
              "version": 2,
              "nodeId": "signed-node",
              "alpns": ["oppi/http/1"],
              "addressMode": "node-id",
              "ticket": null,
              "relayUrls": [
                "https://RELAY.example.test/",
                "https://relay.example.test",
                "https://relay-two.example.test:8443/"
              ]
            }
            """.utf8)
        )

        #expect(decoded.relayUrls == [
            "https://relay-two.example.test:8443",
            "https://relay.example.test",
        ])

        let publicDefault = try JSONDecoder().decode(
            IrohServerTransport.self,
            from: Data("""
            {
              "version": 2,
              "nodeId": "signed-node",
              "alpns": ["oppi/http/1"],
              "addressMode": "node-id",
              "ticket": null,
              "relayUrls": []
            }
            """.utf8)
        )
        #expect(publicDefault.relayUrls == nil)
    }

    @Test func invalidRelayMetadataFailsClosedDuringDecoding() throws {
        let invalidRelaySets = [
            ["http://relay.example.test"],
            ["https://user:password@relay.example.test"],
            ["https://relay.example.test/?query=value"],
            ["https://relay.example.test/#fragment"],
            ["https://relay.example.test/not-root"],
            ["https://localhost"],
            ["https://relay.localhost"],
            ["https://127.0.0.1"],
            ["https://10.0.0.1"],
            ["https://172.16.0.1"],
            ["https://192.168.0.1"],
            ["https://169.254.0.1"],
            ["https://0.0.0.0"],
            ["https://[::1]"],
            ["https://[fc00::1]"],
            ["https://[fe80::1]"],
            ["https://[::]"],
            ["https://[::ffff:192.168.0.1]"],
            Array(repeating: "https://relay.example.test", count: 9),
        ]

        for relayURLs in invalidRelaySets {
            let data = try JSONSerialization.data(withJSONObject: [
                "version": 2,
                "nodeId": "signed-node",
                "alpns": ["oppi/http/1"],
                "addressMode": "node-id",
                "relayUrls": relayURLs,
            ])
            #expect(throws: (any Error).self) {
                _ = try JSONDecoder().decode(IrohServerTransport.self, from: data)
            }
        }
    }

    @Test func signedRelayValidationAllowsPublicIPLiteralAndSelfHostedDNSNameWithoutResolvingIt() throws {
        let canonical = try IrohRelayURLs.canonicalize([
            "https://198.51.100.10",
            "https://[2001:db8::10]",
            "https://owner-relay.example.test",
        ])

        #expect(canonical == [
            "https://198.51.100.10",
            "https://[2001:db8::10]",
            "https://owner-relay.example.test",
        ])
    }

    @Test func relayMembershipReinstallsPairedAndInFlightRelaysOnEndpointRebind() throws {
        let first = IrohServerTransport(
            version: 2,
            nodeId: "first",
            alpns: [IrohTunnelProtocol.alpn],
            addressMode: .nodeId,
            ticket: nil,
            relayUrls: ["https://relay-one.example.test"]
        )
        let inFlightInvite = IrohServerTransport(
            version: 2,
            nodeId: "second",
            alpns: [IrohTunnelProtocol.alpn],
            addressMode: .nodeId,
            ticket: nil,
            relayUrls: ["https://relay-two.example.test"]
        )
        var membership = IrohRelayMapMembership()

        try membership.register(first)
        membership.associate(withEndpointGeneration: 1)
        membership.markInstalled(["https://relay-one.example.test"], onEndpointGeneration: 1)
        try membership.register(inFlightInvite)

        #expect(membership.urlsNeedingInstallation == ["https://relay-two.example.test"])
        #expect(membership.desiredURLs == [
            "https://relay-one.example.test",
            "https://relay-two.example.test",
        ])

        // A fake rebind gets a fresh default map, so both accumulated sources
        // must be installed again rather than trusting generation 1's record.
        membership.associate(withEndpointGeneration: 2)
        #expect(membership.urlsNeedingInstallation == membership.desiredURLs)
    }

    @Test func relayMembershipReconcilesReplacementAndSharedOwnership() throws {
        let first = IrohServerTransport(
            version: 2,
            nodeId: "first",
            alpns: [IrohTunnelProtocol.alpn],
            addressMode: .nodeId,
            ticket: nil,
            relayUrls: ["https://shared.example.test", "https://old.example.test"]
        )
        let second = IrohServerTransport(
            version: 2,
            nodeId: "second",
            alpns: [IrohTunnelProtocol.alpn],
            addressMode: .nodeId,
            ticket: nil,
            relayUrls: ["https://shared.example.test"]
        )
        var membership = IrohRelayMapMembership()
        try membership.register(first)
        try membership.register(second)
        membership.associate(withEndpointGeneration: 1)
        membership.markInstalled(membership.desiredURLs, onEndpointGeneration: 1)

        try membership.register(IrohServerTransport(
            version: 2,
            nodeId: "first",
            alpns: [IrohTunnelProtocol.alpn],
            addressMode: .nodeId,
            ticket: nil,
            relayUrls: ["https://new.example.test"]
        ))

        #expect(membership.urlsNeedingInstallation == ["https://new.example.test"])
        #expect(membership.urlsNeedingRemoval == ["https://old.example.test"])
        #expect(membership.desiredURLs == [
            "https://new.example.test",
            "https://shared.example.test",
        ])

        membership.markRemoved(membership.urlsNeedingRemoval, onEndpointGeneration: 1)
        membership.markInstalled(membership.urlsNeedingInstallation, onEndpointGeneration: 1)
        membership.remove(ownerNodeID: "second")

        #expect(membership.urlsNeedingRemoval == ["https://shared.example.test"])
        #expect(membership.desiredURLs == ["https://new.example.test"])
    }

    @Test func relayMapErrorIsRedactedBeforePublicLogging() {
        let redacted = IrohRelayMapFailure.redacted(
            IrohTransportError.unavailable("https://private-relay.example.test failed")
        )

        #expect(redacted == .unavailable("Unable to update signed Iroh relays"))
        #expect(!redacted.localizedDescription.contains("private-relay.example.test"))
    }

    @Test func pathEvidenceUsesOnlyUnambiguousPrivacySafeCategories() {
        #expect(IrohSelectedPathEvidence(isIP: true, isRelay: false, rttMs: 12).pathKind == .direct)
        #expect(IrohSelectedPathEvidence(isIP: false, isRelay: true, rttMs: 80).pathKind == .relay)
        #expect(IrohSelectedPathEvidence(isIP: false, isRelay: false, rttMs: 0).pathKind == .unknown)
        #expect(IrohSelectedPathEvidence(isIP: true, isRelay: true, rttMs: 0).pathKind == .unknown)
    }

    @Test func connectErrorMappingDowngradesOnlyAvailabilityKinds() {
        for kind in [
            IrohErrorKind.connect,
            .connection,
            .relay,
            .closed,
            .timeout,
        ] {
            #expect(IrohLibConnectionProvider.mapConnectError(
                kind: kind,
                detail: "private detail"
            ).isFallbackEligible)
        }

        for kind in [
            IrohErrorKind.alpn,
            .invalidInput,
            .bind,
            .keyParsing,
            .ticketParsing,
            .stream,
            .datagram,
            .callback,
            .internal,
        ] {
            #expect(!IrohLibConnectionProvider.mapConnectError(
                kind: kind,
                detail: "private detail"
            ).isFallbackEligible)
        }
    }

    @Test func telemetryErrorsCollapseToLowCardinalityKinds() {
        #expect(IrohTransportTelemetry.errorKind(IrohTransportError.unavailable("private detail")) == "unavailable")
        #expect(IrohTransportTelemetry.errorKind(IrohTransportError.remotePeerMismatch(
            expected: "private expected",
            actual: "private actual"
        )) == "remote_peer")
        #expect(IrohTransportTelemetry.errorKind(CancellationError()) == "cancelled")
        do {
            _ = try EndpointId.fromString(s: "not-an-endpoint-id")
            Issue.record("Expected Iroh endpoint parsing to fail")
        } catch {
            #expect(IrohTransportTelemetry.errorKind(error) == "key_parsing")
        }
    }

    @Test func failedStreamInvalidatesOnlyItsConnectionGeneration() {
        var generations = IrohConnectionGenerations()
        let stale = generations.advance(alpn: IrohTunnelProtocol.alpn)
        let replacement = generations.advance(alpn: IrohTunnelProtocol.alpn)

        let staleInvalidated = generations.invalidateIfCurrent(
            alpn: IrohTunnelProtocol.alpn,
            generation: stale
        )
        #expect(!staleInvalidated)
        #expect(generations.isCurrent(alpn: IrohTunnelProtocol.alpn, generation: replacement))
        let replacementInvalidated = generations.invalidateIfCurrent(
            alpn: IrohTunnelProtocol.alpn,
            generation: replacement
        )
        #expect(replacementInvalidated)
        #expect(!generations.isCurrent(alpn: IrohTunnelProtocol.alpn, generation: replacement))
    }

    @MainActor
    @Test func streamMetricsUseOnlyBoundedIrohIdentity() async throws {
        let connection = ServerConnection()
        let loopbackURL = try #require(URL(string: "http://127.0.0.1:12345"))
        let configured = await connection.configureForUse(
            credentials: credentials(preference: .irohOnly, includeHTTP: false),
            serverInfoBootstrap: { _, _ in
                ServerInfo(
                    name: "Test",
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
            },
            irohProxyFactory: { _, _ in (nil, loopbackURL) }
        )

        #expect(configured)
        #expect(connection.streamEndpointHostKindForMetrics() == "iroh")
    }

    @MainActor
    @Test func streamMetricsBucketHTTPHostInsteadOfUploadingIt() {
        let connection = ServerConnection()
        let configured = connection.configure(credentials: ServerCredentials(
            host: "private-node.tail123.ts.net",
            port: 7749,
            token: "dt_test",
            name: "Test",
            scheme: .https
        ))

        #expect(configured)
        #expect(connection.streamEndpointHostKindForMetrics() == "tailscale")
    }

    @Test func localRequestWithoutAuthorizationIsRejected() {
        let request = Data("GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)
        #expect(throws: IrohTransportError.authentication(
            "Local tunnel request Authorization does not match tunnel context"
        )) {
            _ = try IrohLoopbackProxy.validateLocalRequest(
                request,
                expectedAuthorization: "Bearer expected"
            )
        }
    }

    @Test func localRequestWithWrongAuthorizationIsRejected() {
        let request = Data(
            "GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer wrong\r\n\r\n".utf8
        )
        #expect(throws: IrohTransportError.authentication(
            "Local tunnel request Authorization does not match tunnel context"
        )) {
            _ = try IrohLoopbackProxy.validateLocalRequest(
                request,
                expectedAuthorization: "Bearer expected"
            )
        }
    }

    @Test func localRequestWithMatchingAuthorizationIsAccepted() throws {
        let expected = ServerAuthorization.headerValue(token: "expected")
        let url = try #require(URL(string: "http://127.0.0.1/health"))
        var request = URLRequest(url: url)
        ServerAuthorization.apply(token: "expected", to: &request)
        #expect(request.value(forHTTPHeaderField: "Authorization") == expected)

        let raw = Data(
            "GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: \(expected)\r\n\r\n".utf8
        )
        #expect(try IrohLoopbackProxy.validateLocalRequest(raw, expectedAuthorization: expected))
    }

    @Test func partialLocalHeaderTimesOutAndReleasesPeer() async {
        let release = AsyncCounter()

        await #expect(throws: IrohTransportError.authentication(
            "Local tunnel request header timed out"
        )) {
            _ = try await IrohLoopbackProxy.receiveAuthenticatedRequest(
                expectedAuthorization: "Bearer expected",
                timeout: .milliseconds(20),
                onTimeout: { release.increment() },
                receive: {
                    try await Task.sleep(for: .seconds(10))
                    return (Data("GET / HTTP/1.1\r\n".utf8), false)
                }
            )
        }

        #expect(release.value() == 1)
    }

    @Test func stalledPeerDoesNotBlockAuthenticatedTraffic() async throws {
        let release = AsyncCounter()
        let stalled = Task {
            try await IrohLoopbackProxy.receiveAuthenticatedRequest(
                expectedAuthorization: "Bearer expected",
                timeout: .milliseconds(20),
                onTimeout: { release.increment() },
                receive: {
                    try await Task.sleep(for: .seconds(10))
                    return (Data(), false)
                }
            )
        }

        let source = FragmentedRequestSource([
            Data("GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n".utf8),
            Data("Authorization: Bearer expected\r\n\r\n".utf8),
        ])
        let accepted = try await IrohLoopbackProxy.receiveAuthenticatedRequest(
            expectedAuthorization: "Bearer expected",
            timeout: .seconds(1),
            onTimeout: {},
            receive: { try await source.next() }
        )

        #expect(String(data: accepted.data, encoding: .utf8)?.contains("GET /health") == true)
        await #expect(throws: IrohTransportError.authentication(
            "Local tunnel request header timed out"
        )) {
            _ = try await stalled.value
        }
        #expect(release.value() == 1)
    }

    @Test func oversizedCompletedLocalHeaderIsRejected() {
        let fixed = Data(
            "GET / HTTP/1.1\r\nAuthorization: Bearer expected\r\nX-Fill: ".utf8
        )
        var request = fixed
        request.append(Data(repeating: 97, count: (64 * 1024 + 1) - fixed.count))
        request.append(Data("\r\n\r\n".utf8))

        #expect(throws: IrohTransportError.framing(
            "Local tunnel request headers exceed 65536 bytes"
        )) {
            _ = try IrohLoopbackProxy.validateLocalRequest(
                request,
                expectedAuthorization: "Bearer expected"
            )
        }
    }

    @Test func fragmentedHTTPRequestIsAccepted() async throws {
        let source = FragmentedRequestSource([
            Data("POST /upload HTTP/1.1\r\nHost: localhost\r\nAuthor".utf8),
            Data("ization: Bearer expected\r\nContent-Length: 4\r\n\r\nbody".utf8),
        ])
        let request = try await IrohLoopbackProxy.collectAuthenticatedRequest(
            expectedAuthorization: "Bearer expected",
            receive: { try await source.next() }
        )

        #expect(request.data.suffix(4) == Data("body".utf8))
    }

    @Test func fragmentedWebSocketUpgradeIsAccepted() async throws {
        let source = FragmentedRequestSource([
            Data("GET /stream HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n".utf8),
            Data("Connection: Upgrade\r\nAuthorization: Bearer expected\r\n\r\n".utf8),
        ])
        let request = try await IrohLoopbackProxy.collectAuthenticatedRequest(
            expectedAuthorization: "Bearer expected",
            receive: { try await source.next() }
        )

        #expect(String(data: request.data, encoding: .utf8)?.contains("Upgrade: websocket") == true)
    }

    @Test func failedResponsePumpPreservesForwardedByteCount() async {
        let counter = IrohTunnelByteCounter()
        let source = FailingIrohResponseSource(
            firstChunk: Data(repeating: 7, count: 4_096),
            error: IrohTransportError.unavailable("injected failure")
        )
        let sink = ForwardedChunkSink()

        await #expect(throws: IrohTransportError.unavailable("injected failure")) {
            try await IrohLoopbackProxy.pumpIrohToLocal(
                counter: counter,
                read: { try await source.read() },
                send: { data, _ in await sink.send(data) }
            )
        }

        #expect(counter.snapshot().responseBytes == 4_096)
        #expect(await sink.byteCount() == 4_096)
    }

    @Test func localPeerCancellationAfterResponseDoesNotEmitTunnelError() {
        for error in [
            NWError.posix(.ECANCELED),
            NWError.posix(.ECONNRESET),
            NWError.posix(.EPIPE),
            NWError.posix(.ENOTCONN),
        ] {
            let failure = IrohTunnelPumpFailure(endpoint: .localPeer, underlyingError: error)
            #expect(!IrohLoopbackProxy.shouldRecordTunnelPumpError(failure, responseBytes: 1))
        }
        for error in [CancellationError(), URLError(.cancelled)] as [Error] {
            let failure = IrohTunnelPumpFailure(endpoint: .localPeer, underlyingError: error)
            #expect(!IrohLoopbackProxy.shouldRecordTunnelPumpError(failure, responseBytes: 1))
        }
    }

    @Test func preResponseLocalAndAllIrohFailuresRemainReportable() {
        let localReset = IrohTunnelPumpFailure(
            endpoint: .localPeer,
            underlyingError: NWError.posix(.ECONNRESET)
        )
        let localTimeout = IrohTunnelPumpFailure(
            endpoint: .localPeer,
            underlyingError: NWError.posix(.ETIMEDOUT)
        )
        let irohReset = IrohTunnelPumpFailure(
            endpoint: .iroh,
            underlyingError: NWError.posix(.ECONNRESET)
        )

        #expect(IrohLoopbackProxy.shouldRecordTunnelPumpError(localReset, responseBytes: 0))
        #expect(IrohLoopbackProxy.shouldRecordTunnelPumpError(localTimeout, responseBytes: 1))
        #expect(IrohLoopbackProxy.shouldRecordTunnelPumpError(irohReset, responseBytes: 1))
    }

    @Test func failedIrohPumpCancelsLocalPeerBeforeWaitingForBlockedUpload() async {
        let gate = PumpFailureGate()
        let cancellation = PeerCancellationRecorder()

        let bridge = Task {
            try await IrohLoopbackProxy.runBidirectionalPumps(
                includeLocalToIroh: true,
                localToIroh: { await gate.blockLocalPump() },
                irohToLocal: {
                    await gate.signalFailure()
                    throw IrohTransportError.unavailable("injected Iroh timeout")
                },
                cancelPeer: { cancellation.record() },
                cancelTransport: {}
            )
        }

        await gate.waitForFailure()
        for _ in 0..<100 where !cancellation.wasRecorded() {
            await Task.yield()
        }
        let cancelledBeforeUploadReleased = cancellation.wasRecorded()
        await gate.releaseLocalPump()
        _ = try? await bridge.value

        #expect(
            cancelledBeforeUploadReleased,
            "An Iroh read failure must close loopback TCP before waiting for an idle WebSocket upload pump"
        )
    }

    @Test func authenticatedPrefaceIsBoundedAndRedactable() throws {
        let bytes = try IrohTunnelProtocol.makePreface(token: "dt_secret")
        let frame = try IrohFrameCodec.decode(
            bytes,
            maxHeaderBytes: IrohTunnelProtocol.maxPrefaceBytes,
            maxBodyBytes: 0
        )

        #expect(bytes.count <= IrohTunnelProtocol.maxPrefaceBytes)
        #expect(frame.header["v"] == 1)
        #expect(frame.header["kind"] == "httpTunnel")
        #expect(frame.header["authorization"] == "Bearer dt_secret")
        #expect(IrohFrameCodec.redact(header: frame.header)["authorization"] == "[redacted]")
    }

    private func credentials(
        preference: TransportPreference,
        includeHTTP: Bool,
        alpns: [String] = [IrohTunnelProtocol.alpn],
        addressMode: IrohAddressMode = .nodeId,
        tlsCertFingerprint: String? = nil,
        httpScheme: ServerScheme = .https
    ) -> ServerCredentials {
        ServerCredentials(
            host: includeHTTP ? "server.example.test" : "",
            port: includeHTTP ? 443 : 0,
            token: "dt_test",
            name: "Iroh",
            scheme: includeHTTP ? httpScheme : nil,
            serverFingerprint: "sha256:server",
            tlsCertFingerprint: tlsCertFingerprint,
            transports: ServerTransports(
                preference: preference,
                iroh: transport(alpns: alpns, addressMode: addressMode),
                http: includeHTTP
                    ? HTTPServerTransport(
                        host: "server.example.test",
                        port: 443,
                        scheme: httpScheme,
                        tlsCertFingerprint: tlsCertFingerprint
                    )
                    : nil
            )
        )
    }

    private func transport(
        alpns: [String] = [IrohTunnelProtocol.alpn],
        addressMode: IrohAddressMode = .nodeId,
        ticket: String? = nil
    ) -> IrohServerTransport {
        IrohServerTransport(
            version: 2,
            nodeId: "signed-node",
            alpns: alpns,
            addressMode: addressMode,
            ticket: ticket
        )
    }
}

@Suite("Short-lived server transport")
struct ServerTransportAPIClientTests {
    @Test func automaticUsesPairedHTTPSWithoutStartingIroh() async throws {
        let events = ShortLivedTransportEvents()
        let managerCreations = AsyncCounter()

        let result = try await ServerTransportAPIClient.withClient(
            for: server(mode: .automatic),
            lanEndpointProvider: { _ in nil },
            managerFactory: { metadata in
                managerCreations.increment()
                return IrohConnectionManager(iroh: metadata)
            },
            httpAvailabilityProbe: { client in
                let host = await client.baseURL.host ?? ""
                await events.append("httpsProbe:\(host)")
            },
            irohAvailabilityProbe: { _ in await events.append("irohProbe") },
            operation: { client in
                let host = await client.baseURL.host ?? ""
                await events.append("operation:\(host)")
                return host
            }
        )

        #expect(result == "server.example.test")
        #expect(await events.snapshot() == [
            "httpsProbe:server.example.test",
            "operation:server.example.test",
        ])
        #expect(managerCreations.value() == 0)
    }

    @Test func automaticAdvancesToIrohOnlyWhenHTTPSAvailabilityFailsBeforeOperation() async throws {
        let events = ShortLivedTransportEvents()
        let managerCreations = AsyncCounter()

        let result = try await ServerTransportAPIClient.withClient(
            for: server(mode: .automatic),
            lanEndpointProvider: { _ in nil },
            managerFactory: { metadata in
                managerCreations.increment()
                return IrohConnectionManager(iroh: metadata)
            },
            irohRelayPreparer: { _ in await events.append("irohRelayPreparation") },
            httpAvailabilityProbe: { _ in
                await events.append("httpsProbe")
                throw URLError(.cannotConnectToHost)
            },
            irohAvailabilityProbe: { _ in await events.append("irohProbe") },
            operation: { client in
                let host = await client.baseURL.host ?? ""
                await events.append("operation:\(host)")
                return host
            }
        )

        #expect(result == "127.0.0.1")
        #expect(await events.snapshot() == [
            "httpsProbe",
            "irohRelayPreparation",
            "irohProbe",
            "operation:127.0.0.1",
        ])
        #expect(managerCreations.value() == 1)
    }

    @Test func httpsOnlyNeverStartsIroh() async throws {
        let events = ShortLivedTransportEvents()
        let managerCreations = AsyncCounter()

        _ = try await ServerTransportAPIClient.withClient(
            for: server(mode: .httpsOnly),
            lanEndpointProvider: { _ in nil },
            managerFactory: { metadata in
                managerCreations.increment()
                return IrohConnectionManager(iroh: metadata)
            },
            httpAvailabilityProbe: { _ in await events.append("httpsProbe") },
            irohAvailabilityProbe: { _ in
                Issue.record("Iroh must not be probed in HTTPS Only mode")
            },
            operation: { _ in await events.append("operation") }
        )

        #expect(await events.snapshot() == ["httpsProbe", "operation"])
        #expect(managerCreations.value() == 0)
    }

    @Test func irohOnlyNeverConstructsHTTP() async throws {
        let events = ShortLivedTransportEvents()

        _ = try await ServerTransportAPIClient.withClient(
            for: server(mode: .irohOnly),
            lanEndpointProvider: { _ in
                Issue.record("LAN discovery must not start in Iroh Only mode")
                return nil
            },
            irohRelayPreparer: { _ in await events.append("irohRelayPreparation") },
            httpAvailabilityProbe: { _ in
                Issue.record("HTTP must not be constructed in Iroh Only mode")
            },
            irohAvailabilityProbe: { _ in await events.append("irohProbe") },
            operation: { client in
                let host = await client.baseURL.host ?? ""
                await events.append("operation:\(host)")
            }
        )

        #expect(await events.snapshot() == [
            "irohRelayPreparation",
            "irohProbe",
            "operation:127.0.0.1",
        ])
    }

    @Test func startedOperationIsInvokedOnceAndNeverReplayedAcrossRoutes() async throws {
        let events = ShortLivedTransportEvents()
        let managerCreations = AsyncCounter()

        await #expect(throws: URLError(.networkConnectionLost)) {
            _ = try await ServerTransportAPIClient.withClient(
                for: server(mode: .automatic),
                lanEndpointProvider: { _ in nil },
                managerFactory: { metadata in
                    managerCreations.increment()
                    return IrohConnectionManager(iroh: metadata)
                },
                httpAvailabilityProbe: { _ in await events.append("httpsProbe") },
                irohAvailabilityProbe: { _ in await events.append("irohProbe") },
                operation: { _ in
                    await events.append("operation")
                    throw URLError(.networkConnectionLost)
                }
            )
        }

        #expect(await events.snapshot() == ["httpsProbe", "operation"])
        #expect(managerCreations.value() == 0)
    }

    @Test func malformedTrailingIrohIsIgnoredWhenHTTPSWins() async throws {
        let events = ShortLivedTransportEvents()
        let managerCreations = AsyncCounter()

        let result = try await ServerTransportAPIClient.withClient(
            for: server(mode: .automatic, irohAddressMode: .ticket, irohTicket: nil),
            lanEndpointProvider: { _ in nil },
            managerFactory: { metadata in
                managerCreations.increment()
                return IrohConnectionManager(iroh: metadata)
            },
            irohRelayPreparer: { _ in await events.append("irohRelayPreparation") },
            httpAvailabilityProbe: { client in
                let host = await client.baseURL.host ?? ""
                await events.append("httpsProbe:\(host)")
            },
            irohAvailabilityProbe: { _ in await events.append("irohProbe") },
            operation: { client in
                let host = await client.baseURL.host ?? ""
                await events.append("operation:\(host)")
                return host
            }
        )

        #expect(result == "server.example.test")
        #expect(await events.snapshot() == [
            "httpsProbe:server.example.test",
            "operation:server.example.test",
        ])
        #expect(managerCreations.value() == 0)
    }

    @Test func malformedIrohFailsBeforeRelayPrepWhenReached() async throws {
        let events = ShortLivedTransportEvents()
        let managerCreations = AsyncCounter()

        await #expect(throws: IrohTransportError.missingTicket) {
            _ = try await ServerTransportAPIClient.withClient(
                for: server(mode: .automatic, irohAddressMode: .ticket, irohTicket: nil),
                lanEndpointProvider: { _ in nil },
                managerFactory: { metadata in
                    managerCreations.increment()
                    return IrohConnectionManager(iroh: metadata)
                },
                irohRelayPreparer: { _ in await events.append("irohRelayPreparation") },
                httpAvailabilityProbe: { _ in
                    await events.append("httpsProbe")
                    throw URLError(.cannotConnectToHost)
                },
                irohAvailabilityProbe: { _ in await events.append("irohProbe") },
                operation: { _ in
                    await events.append("operation")
                    return "unused"
                }
            )
        }

        #expect(await events.snapshot() == ["httpsProbe"])
        #expect(managerCreations.value() == 0)
    }

    private func server(
        mode: PairedServerRouteMode,
        irohAddressMode: IrohAddressMode = .nodeId,
        irohTicket: String? = nil
    ) -> PairedServer {
        let credentials = ServerCredentials(
            host: "server.example.test",
            port: 443,
            token: "device-token",
            name: "Test server",
            scheme: .https,
            serverFingerprint: "sha256:server",
            transports: ServerTransports(
                preference: .irohPreferred,
                iroh: IrohServerTransport(
                    version: 2,
                    nodeId: "signed-node",
                    alpns: [IrohTunnelProtocol.alpn],
                    addressMode: irohAddressMode,
                    ticket: irohTicket
                ),
                http: HTTPServerTransport(
                    host: "server.example.test",
                    port: 443,
                    scheme: .https,
                    tlsCertFingerprint: nil
                )
            )
        )
        guard var server = PairedServer(from: credentials) else {
            preconditionFailure("Test credentials must produce a paired server")
        }
        server.routeMode = mode
        return server
    }
}

private actor ShortLivedTransportEvents {
    private var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }

    func snapshot() -> [String] {
        events
    }
}

@Suite("Iroh connection manager lifecycle")
struct IrohConnectionManagerTests {
    @Test func pairingReachabilityProbeOpensPairingALPNWithoutWritingAFrame() async throws {
        let provider = RecordingIrohConnectionProvider(responses: [Data()])
        let manager = IrohConnectionManager(
            iroh: IrohServerTransport(
                version: 2,
                nodeId: "signed-node",
                alpns: ["oppi/pair/1"],
                addressMode: .nodeId,
                ticket: nil
            ),
            provider: provider
        )

        try await manager.probeReachability(alpn: "oppi/pair/1")

        #expect(await provider.openedALPNs() == ["oppi/pair/1"])
        #expect(await provider.writtenChunks().isEmpty)
        #expect(await provider.resetCount() == 1)
        await manager.shutdown()
    }

    @Test func frameExchangesReuseProviderAndShutdownCoherently() async throws {
        let first = try IrohFrameCodec.encode(header: ["kind": "first"])
        let second = try IrohFrameCodec.encode(header: ["kind": "second"])
        let provider = RecordingIrohConnectionProvider(responses: [first, second])
        let manager = IrohConnectionManager(
            iroh: IrohServerTransport(
                version: 2,
                nodeId: "signed-node",
                alpns: ["oppi/pair/1", IrohTunnelProtocol.alpn],
                addressMode: .nodeId,
                ticket: nil
            ),
            provider: provider
        )

        let response1 = try await manager.exchange(
            alpn: "oppi/pair/1",
            requestFrame: Data("one".utf8),
            maxResponseBytes: 1024
        )
        let response2 = try await manager.exchange(
            alpn: "oppi/pair/1",
            requestFrame: Data("two".utf8),
            maxResponseBytes: 1024
        )
        await manager.prepareForBackground()
        await manager.shutdown()

        #expect(response1 == first)
        #expect(response2 == second)
        #expect(await provider.openedALPNs() == ["oppi/pair/1", "oppi/pair/1"])
        #expect(await provider.suspendCount() == 2)
        #expect(await provider.shutdownCount() == 1)
    }

    @Test func timedOutTunnelOpenClearsProviderAndAllowsFreshRetry() async throws {
        let provider = RecoveringTunnelOpenProvider()
        let manager = IrohConnectionManager(
            iroh: IrohServerTransport(
                version: 2,
                nodeId: "signed-node",
                alpns: [IrohTunnelProtocol.alpn],
                addressMode: .nodeId,
                ticket: nil
            ),
            provider: provider
        )

        let timedOutOpen = Task {
            try await manager.openTunnelStream(timeout: .milliseconds(20))
        }
        while !(await provider.firstOpenIsWaiting) {
            await Task.yield()
        }
        await #expect(throws: IrohTransportError.unavailable("Iroh connectivity operation timed out")) {
            _ = try await timedOutOpen.value
        }
        #expect(await provider.suspendCount() == 1)

        _ = try await manager.openTunnelStream(timeout: .seconds(1))
        #expect(await provider.openCount() == 2)
        await provider.releaseFirstOpen()
        await manager.shutdown()
    }

    @Test func overlappingEstablishedFailureReportsCoalesceDuringRecovery() async {
        let provider = EstablishedFailureCallbackProvider()
        let manager = IrohConnectionManager(
            iroh: IrohServerTransport(
                version: 2,
                nodeId: "signed-node",
                alpns: [IrohTunnelProtocol.alpn],
                addressMode: .nodeId,
                ticket: nil
            ),
            provider: provider
        )
        let gate = EstablishedFailureReportGate()
        await manager.setAvailabilityFailureHandlers(
            tunnelOpen: nil,
            establishedStream: { await gate.handleReport() }
        )

        let first = Task { await provider.reportFailure() }
        await gate.waitForFirstReport()
        await provider.reportFailure()
        await gate.releaseFirstReport()
        await first.value

        #expect(await gate.reportCount == 1)
        await manager.shutdown()
    }

    @Test func plannedSharedRecycleDoesNotEscalateOldConnectionFailure() async throws {
        let provider = EstablishedFailureCallbackProvider()
        let manager = IrohConnectionManager(
            iroh: IrohServerTransport(
                version: 2,
                nodeId: "signed-node",
                alpns: [IrohTunnelProtocol.alpn],
                addressMode: .nodeId,
                ticket: nil
            ),
            provider: provider
        )
        let counter = AsyncCounter()
        await manager.setAvailabilityFailureHandlers(
            tunnelOpen: nil,
            establishedStream: { counter.increment() }
        )

        try await IrohEndpointRecycleCoordinator.shared.run {}
        await provider.reportFailure()

        #expect(counter.value() == 0)
        await manager.shutdown()
    }

    @Test func inFlightSharedRecycleSuppressesPlannedFailuresAcrossManagers() async throws {
        let firstProvider = EstablishedFailureCallbackProvider()
        let secondProvider = EstablishedFailureCallbackProvider()
        let metadata = IrohServerTransport(
            version: 2,
            nodeId: "signed-node",
            alpns: [IrohTunnelProtocol.alpn],
            addressMode: .nodeId,
            ticket: nil
        )
        let firstManager = IrohConnectionManager(iroh: metadata, provider: firstProvider)
        let secondManager = IrohConnectionManager(iroh: metadata, provider: secondProvider)
        let firstCounter = AsyncCounter()
        let secondCounter = AsyncCounter()
        await firstManager.setAvailabilityFailureHandlers(
            tunnelOpen: nil,
            establishedStream: { firstCounter.increment() }
        )
        await secondManager.setAvailabilityFailureHandlers(
            tunnelOpen: nil,
            establishedStream: { secondCounter.increment() }
        )
        let gate = EndpointRecycleSingleFlightGate()
        let recycling = Task {
            try await IrohEndpointRecycleCoordinator.shared.run {
                await gate.blockOperation()
            }
        }
        await gate.waitUntilBlocked()

        await firstProvider.reportFailure()
        await secondProvider.reportFailure()
        #expect(firstCounter.value() == 0)
        #expect(secondCounter.value() == 0)

        await gate.releaseOperation()
        try await recycling.value
        await firstManager.shutdown()
        await secondManager.shutdown()
    }

    @Test func recyclePublishedDuringStreamOpenDoesNotRelabelOldStream() async throws {
        let provider = RecoveringTunnelOpenProvider()
        let manager = IrohConnectionManager(
            iroh: IrohServerTransport(
                version: 2,
                nodeId: "signed-node",
                alpns: [IrohTunnelProtocol.alpn],
                addressMode: .nodeId,
                ticket: nil
            ),
            provider: provider
        )
        let counter = AsyncCounter()
        await manager.setAvailabilityFailureHandlers(
            tunnelOpen: nil,
            establishedStream: { counter.increment() }
        )
        let opening = Task { try await manager.openTunnelStream() }
        while !(await provider.firstOpenIsWaiting) {
            await Task.yield()
        }

        try await IrohEndpointRecycleCoordinator.shared.run {}
        await provider.releaseFirstOpen()
        _ = try await opening.value
        await provider.reportFailure()

        #expect(counter.value() == 0)
        await manager.shutdown()
    }

    @Test func endpointRecycleIsSingleFlightAcrossManagers() async throws {
        let gate = EndpointRecycleSingleFlightGate()
        let operationCount = AsyncCounter()

        let first = Task {
            try await IrohEndpointRecycleCoordinator.shared.run {
                operationCount.increment()
                await gate.blockOperation()
            }
        }
        await gate.waitUntilBlocked()
        let second = Task {
            try await IrohEndpointRecycleCoordinator.shared.run {
                operationCount.increment()
            }
        }
        for _ in 0..<20 { await Task.yield() }

        #expect(operationCount.value() == 1)
        await gate.releaseOperation()
        try await first.value
        try await second.value
        #expect(operationCount.value() == 1)
    }

    @Test func loopbackProxyCarriesHTTPBytesAfterAuthenticatedPreface() async throws {
        let httpResponse = Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello".utf8)
        let provider = RecordingIrohConnectionProvider(responses: [httpResponse])
        let manager = IrohConnectionManager(
            iroh: IrohServerTransport(
                version: 2,
                nodeId: "signed-node",
                alpns: [IrohTunnelProtocol.alpn],
                addressMode: .nodeId,
                ticket: nil
            ),
            provider: provider
        )
        let url = try await manager.startProxy(token: "dt_proxy")
        var request = URLRequest(url: url.appendingPathComponent("health"))
        request.setValue("Bearer dt_proxy", forHTTPHeaderField: "Authorization")

        let (body, response) = try await URLSession.shared.data(for: request)
        await manager.shutdown()

        #expect(String(data: body, encoding: .utf8) == "hello")
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(url.host == "127.0.0.1")
        let writes = await provider.writtenChunks()
        let preface = try IrohFrameCodec.decode(writes[0], maxBodyBytes: 0)
        #expect(preface.header["authorization"] == "Bearer dt_proxy")
        #expect(writes.dropFirst().contains { chunk in
            guard let request = String(data: chunk, encoding: .utf8) else { return false }
            return request.contains("GET /health")
                && request.contains("Authorization: Bearer dt_proxy")
        })
    }

    @Test func oversizedResponseResetsStream() async throws {
        let provider = RecordingIrohConnectionProvider(responses: [Data(repeating: 1, count: 8)])
        let manager = IrohConnectionManager(
            iroh: IrohServerTransport(
                version: 2,
                nodeId: "signed-node",
                alpns: ["oppi/pair/1"],
                addressMode: .nodeId,
                ticket: nil
            ),
            provider: provider
        )

        await #expect(throws: IrohTransportError.framing("Iroh response exceeds 4 bytes")) {
            _ = try await manager.exchange(
                alpn: "oppi/pair/1",
                requestFrame: Data(),
                maxResponseBytes: 4
            )
        }
        #expect(await provider.resetCount() == 1)
    }
}

private actor EstablishedFailureCallbackProvider: IrohConnectionProviding {
    private var failureHandler: (@Sendable () async -> Void)?

    func openStream(alpn: String) async throws -> any IrohByteStream {
        throw IrohTransportError.unavailable("unused")
    }

    func setEstablishedStreamFailureHandler(
        _ handler: (@Sendable () async -> Void)?
    ) async {
        failureHandler = handler
    }

    func reportFailure() async {
        await failureHandler?()
    }

    func suspendConnections() async {}
    func shutdown() async {}
}

private actor EstablishedFailureReportGate {
    private(set) var reportCount = 0
    private var firstReportWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstReleaseContinuation: CheckedContinuation<Void, Never>?

    func handleReport() async {
        reportCount += 1
        guard reportCount == 1 else { return }
        let waiters = firstReportWaiters
        firstReportWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { firstReleaseContinuation = $0 }
    }

    func waitForFirstReport() async {
        guard reportCount == 0 else { return }
        await withCheckedContinuation { firstReportWaiters.append($0) }
    }

    func releaseFirstReport() {
        firstReleaseContinuation?.resume()
        firstReleaseContinuation = nil
    }
}

private actor EndpointRecycleSingleFlightGate {
    private var blocked = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func blockOperation() async {
        blocked = true
        let waiters = blockedWaiters
        blockedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilBlocked() async {
        guard !blocked else { return }
        await withCheckedContinuation { blockedWaiters.append($0) }
    }

    func releaseOperation() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor PumpFailureGate {
    private var failureSignaled = false
    private var failureWaiters: [CheckedContinuation<Void, Never>] = []
    private var localPumpReleased = false
    private var localPumpWaiters: [CheckedContinuation<Void, Never>] = []

    func signalFailure() {
        failureSignaled = true
        let waiters = failureWaiters
        failureWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitForFailure() async {
        guard !failureSignaled else { return }
        await withCheckedContinuation { failureWaiters.append($0) }
    }

    func blockLocalPump() async {
        guard !localPumpReleased else { return }
        await withCheckedContinuation { localPumpWaiters.append($0) }
    }

    func releaseLocalPump() {
        localPumpReleased = true
        let waiters = localPumpWaiters
        localPumpWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private final class PeerCancellationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded = false

    func record() {
        lock.withLock { recorded = true }
    }

    func wasRecorded() -> Bool {
        lock.withLock { recorded }
    }
}

private actor FailingIrohResponseSource {
    private var firstChunk: Data?
    private let error: IrohTransportError

    init(firstChunk: Data, error: IrohTransportError) {
        self.firstChunk = firstChunk
        self.error = error
    }

    func read() throws -> Data {
        if let firstChunk {
            self.firstChunk = nil
            return firstChunk
        }
        throw error
    }
}

private actor ForwardedChunkSink {
    private var bytes = 0

    func send(_ data: Data) {
        bytes += data.count
    }

    func byteCount() -> Int { bytes }
}

private actor FragmentedRequestSource {
    private var fragments: [Data]

    init(_ fragments: [Data]) {
        self.fragments = fragments
    }

    func next() throws -> (Data, Bool) {
        guard !fragments.isEmpty else {
            throw IrohTransportError.protocolViolation("Test request source exhausted")
        }
        return (fragments.removeFirst(), false)
    }
}

private final class AsyncCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.withLock { count += 1 }
    }

    func value() -> Int {
        lock.withLock { count }
    }
}

private actor RecoveringTunnelOpenProvider: IrohConnectionProviding {
    private var opens = 0
    private var suspends = 0
    private var failureHandler: (@Sendable () async -> Void)?
    private(set) var firstOpenIsWaiting = false
    private var firstOpenContinuation: CheckedContinuation<Void, Never>?

    func openStream(alpn: String) async throws -> any IrohByteStream {
        opens += 1
        if opens == 1 {
            firstOpenIsWaiting = true
            await withCheckedContinuation { firstOpenContinuation = $0 }
        }
        return RecordingIrohByteStream(
            response: Data(),
            minimumWritesBeforeResponse: 0,
            onWrite: { _ in },
            onReset: {}
        )
    }

    func suspendConnections() async {
        suspends += 1
    }

    func shutdown() async {
        await suspendConnections()
    }

    func releaseFirstOpen() {
        firstOpenContinuation?.resume()
        firstOpenContinuation = nil
    }

    func setEstablishedStreamFailureHandler(
        _ handler: (@Sendable () async -> Void)?
    ) async {
        failureHandler = handler
    }

    func reportFailure() async {
        await failureHandler?()
    }

    func openCount() -> Int { opens }
    func suspendCount() -> Int { suspends }
}

private actor RecordingIrohConnectionProvider: IrohConnectionProviding {
    private var responses: [Data]
    private var alpns: [String] = []
    private var suspends = 0
    private var shutdowns = 0
    private var resets = 0
    private var writes: [Data] = []

    init(responses: [Data]) {
        self.responses = responses
    }

    func openStream(alpn: String) async throws -> any IrohByteStream {
        alpns.append(alpn)
        guard !responses.isEmpty else {
            throw IrohTransportError.unavailable("no response")
        }
        return RecordingIrohByteStream(
            response: responses.removeFirst(),
            minimumWritesBeforeResponse: alpn == IrohTunnelProtocol.alpn ? 2 : 1,
            onWrite: { [weak self] data in await self?.recordWrite(data) },
            onReset: { [weak self] in await self?.recordReset() }
        )
    }

    func suspendConnections() async {
        suspends += 1
    }

    func shutdown() async {
        shutdowns += 1
        await suspendConnections()
    }

    func openedALPNs() -> [String] { alpns }
    func suspendCount() -> Int { suspends }
    func shutdownCount() -> Int { shutdowns }
    func resetCount() -> Int { resets }
    func writtenChunks() -> [Data] { writes }

    private func recordWrite(_ data: Data) {
        writes.append(data)
    }

    private func recordReset() {
        resets += 1
    }
}

private actor RecordingIrohByteStream: IrohByteStream {
    private var response: Data?
    private let minimumWritesBeforeResponse: Int
    private var writeCount = 0
    private let onWrite: @Sendable (Data) async -> Void
    private let onReset: @Sendable () async -> Void

    init(
        response: Data,
        minimumWritesBeforeResponse: Int,
        onWrite: @escaping @Sendable (Data) async -> Void,
        onReset: @escaping @Sendable () async -> Void
    ) {
        self.response = response
        self.minimumWritesBeforeResponse = minimumWritesBeforeResponse
        self.onWrite = onWrite
        self.onReset = onReset
    }

    func write(_ data: Data) async throws {
        writeCount += 1
        await onWrite(data)
    }
    func finishWriting() async throws {}

    func read(maxBytes: UInt32) async throws -> Data {
        while writeCount < minimumWritesBeforeResponse {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard let response else { return Data() }
        self.response = nil
        return response
    }

    func reset(errorCode: UInt64) async {
        await onReset()
    }
}
