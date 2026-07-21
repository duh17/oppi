import Foundation
import IrohLib
import Testing
@testable import Oppi

@Suite("Iroh transport policy and protocol")
struct IrohTransportTests {
    @Test func preferredAndOnlySelectTunnelBeforeHTTP() throws {
        let preferred = credentials(preference: .irohPreferred, includeHTTP: true)
        let only = credentials(preference: .irohOnly, includeHTTP: false)

        guard case .iroh = try IrohTransportPolicy.select(credentials: preferred) else {
            Issue.record("irohPreferred with tunnel metadata must select Iroh")
            return
        }
        guard case .iroh = try IrohTransportPolicy.select(credentials: only) else {
            Issue.record("irohOnly with tunnel metadata must select Iroh")
            return
        }
    }

    @Test func preferredWithoutTunnelUsesHTTPButOnlyFailsClosed() throws {
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

        #expect(try IrohTransportPolicy.select(credentials: preferred) == .http)
        #expect(throws: IrohTransportError.unsupportedALPN(IrohTunnelProtocol.alpn)) {
            _ = try IrohTransportPolicy.select(credentials: only)
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

    @Test func preferredTunnelProtocolErrorsDoNotDowngradeToHTTP() {
        let invalid = credentials(
            preference: .irohPreferred,
            includeHTTP: true,
            alpns: [IrohTunnelProtocol.alpn],
            addressMode: .ticket
        )
        #expect(throws: IrohTransportError.missingTicket) {
            _ = try IrohTransportPolicy.select(credentials: invalid)
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
        addressMode: IrohAddressMode = .nodeId
    ) -> ServerCredentials {
        ServerCredentials(
            host: includeHTTP ? "server.example.test" : "",
            port: includeHTTP ? 443 : 0,
            token: "dt_test",
            name: "Iroh",
            scheme: includeHTTP ? .https : nil,
            serverFingerprint: "sha256:server",
            transports: ServerTransports(
                preference: preference,
                iroh: transport(alpns: alpns, addressMode: addressMode),
                http: includeHTTP
                    ? HTTPServerTransport(
                        host: "server.example.test",
                        port: 443,
                        scheme: .https,
                        tlsCertFingerprint: nil
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

@Suite("Iroh connection manager lifecycle")
struct IrohConnectionManagerTests {
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
