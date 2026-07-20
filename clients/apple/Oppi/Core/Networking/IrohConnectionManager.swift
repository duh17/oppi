import Foundation
import IrohLib
import OSLog

private let irohManagerLogger = Logger(
    subsystem: AppIdentifiers.subsystem,
    category: "IrohConnection"
)

protocol IrohByteStream: Sendable {
    func write(_ data: Data) async throws
    func finishWriting() async throws
    func read(maxBytes: UInt32) async throws -> Data
    func reset(errorCode: UInt64) async
}

enum IrohPathKind: String, Equatable, Sendable {
    case direct
    case relay
    case unknown
}

struct IrohSelectedPathEvidence: Equatable, Sendable {
    let isIP: Bool
    let isRelay: Bool
    let rttMs: UInt64

    var pathKind: IrohPathKind {
        if isIP, !isRelay { return .direct }
        if isRelay, !isIP { return .relay }
        return .unknown
    }
}

protocol IrohConnectionProviding: Sendable {
    func openStream(alpn: String) async throws -> any IrohByteStream
    func selectedPathEvidence(alpn: String) async throws -> IrohSelectedPathEvidence?
    func suspendConnections() async
    func shutdown() async
}

extension IrohConnectionProviding {
    func selectedPathEvidence(alpn: String) async throws -> IrohSelectedPathEvidence? { nil }
}

struct IrohLibByteStream: IrohByteStream {
    let stream: BiStream
    let onTransportFailure: @Sendable () async -> Void

    func write(_ data: Data) async throws {
        do {
            try await stream.send().writeAll(buf: data)
        } catch {
            await onTransportFailure()
            throw error
        }
    }

    func finishWriting() async throws {
        do {
            try await stream.send().finish()
        } catch {
            await onTransportFailure()
            throw error
        }
    }

    func read(maxBytes: UInt32) async throws -> Data {
        do {
            return try await stream.recv().read(sizeLimit: maxBytes)
        } catch {
            await onTransportFailure()
            throw error
        }
    }

    func reset(errorCode: UInt64) async {
        try? await stream.send().reset(errorCode: errorCode)
        try? await stream.recv().stop(errorCode: errorCode)
    }
}

struct IrohConnectionGenerations: Sendable {
    private var next: UInt64 = 0
    private var currentByALPN: [String: UInt64] = [:]

    mutating func advance(alpn: String) -> UInt64 {
        next &+= 1
        currentByALPN[alpn] = next
        return next
    }

    func current(alpn: String) -> UInt64? {
        currentByALPN[alpn]
    }

    func isCurrent(alpn: String, generation: UInt64) -> Bool {
        currentByALPN[alpn] == generation
    }

    mutating func invalidateIfCurrent(alpn: String, generation: UInt64) -> Bool {
        guard currentByALPN[alpn] == generation else { return false }
        currentByALPN.removeValue(forKey: alpn)
        return true
    }

    mutating func removeAll() {
        currentByALPN.removeAll()
    }
}

/// Process-wide endpoint owner. All paired servers use the same stable
/// Keychain-backed client node identity without binding duplicate endpoints
/// for concurrent requests or concurrent servers.
private actor IrohAppEndpoint {
    static let shared = IrohAppEndpoint()

    private var endpoint: Endpoint?
    private var endpointTask: Task<Endpoint, Error>?

    func get() async throws -> Endpoint {
        if let endpoint, !endpoint.isClosed() { return endpoint }
        if let endpointTask { return try await endpointTask.value }

        let task = Task<Endpoint, Error> {
            let secret = try IrohEndpointSecretStore.loadOrCreateSecretBytes()
            return try await Endpoint.bind(options: EndpointOptions(secretKey: secret))
        }
        endpointTask = task
        do {
            let created = try await task.value
            endpoint = created
            endpointTask = nil
            irohManagerLogger.info("Iroh endpoint ready: \(created.id().fmtShort(), privacy: .public)")
            return created
        } catch {
            endpointTask = nil
            throw IrohTransportError.unavailable("Unable to start Iroh endpoint: \(error.localizedDescription)")
        }
    }
}

/// Reuses one QUIC connection per paired server and ALPN. `openBi()` gives
/// each local TCP connection its own ordered, flow-controlled stream.
actor IrohLibConnectionProvider: IrohConnectionProviding {
    private let iroh: IrohServerTransport
    private var connections: [String: Connection] = [:]
    private var connectionTasks: [String: Task<Connection, Error>] = [:]
    private var connectionTaskIDs: [String: UUID] = [:]
    private var connectionGenerations = IrohConnectionGenerations()
    private var selectedPathKinds: [String: IrohPathKind] = [:]

    init(iroh: IrohServerTransport) {
        self.iroh = iroh
    }

    func openStream(alpn: String) async throws -> any IrohByteStream {
        try IrohPeerValidator.validate(iroh, requiredALPN: alpn)

        let lease = try await connection(for: alpn)
        do {
            let stream = try await lease.connection.openBi()
            recordSelectedPath(connection: lease.connection, alpn: alpn, reason: "stream_open")
            return makeByteStream(stream, alpn: alpn, generation: lease.generation)
        } catch {
            // A cached QUIC connection can close between closeReason() and
            // openBi(). Invalidate only the generation that actually failed.
            IrohTransportTelemetry.recordReconnect(status: "attempt", reason: "open_stream")
            invalidateConnectionIfCurrent(alpn: alpn, generation: lease.generation)
            let replacement = try await self.connection(for: alpn)
            do {
                let stream = try await replacement.connection.openBi()
                recordSelectedPath(connection: replacement.connection, alpn: alpn, reason: "reconnected")
                IrohTransportTelemetry.recordReconnect(status: "recovered", reason: "open_stream")
                return makeByteStream(stream, alpn: alpn, generation: replacement.generation)
            } catch {
                invalidateConnectionIfCurrent(alpn: alpn, generation: replacement.generation)
                IrohTransportTelemetry.recordReconnect(
                    status: "failed",
                    reason: IrohTransportTelemetry.errorKind(error)
                )
                throw IrohTransportError.unavailable("Unable to open Iroh stream: \(error.localizedDescription)")
            }
        }
    }

    func selectedPathEvidence(alpn: String) async throws -> IrohSelectedPathEvidence? {
        Self.selectedPathEvidence(connection: try await connection(for: alpn).connection)
    }

    func suspendConnections() async {
        let active = connections.values
        connections.removeAll()
        connectionGenerations.removeAll()
        connectionTasks.values.forEach { $0.cancel() }
        connectionTasks.removeAll()
        connectionTaskIDs.removeAll()
        for connection in active {
            try? connection.close(errorCode: 0, reason: Data("app background".utf8))
        }
    }

    func shutdown() async {
        await suspendConnections()
    }

    private func boundEndpoint() async throws -> Endpoint {
        try await IrohAppEndpoint.shared.get()
    }

    private struct ConnectionLease: Sendable {
        let connection: Connection
        let generation: UInt64
    }

    private func connection(for alpn: String) async throws -> ConnectionLease {
        if let lease = currentLease(alpn: alpn) {
            try IrohPeerValidator.validateConnectedPeer(
                expectedNodeID: iroh.nodeId,
                remoteNodeID: lease.connection.remoteId().description
            )
            return lease
        }
        connections.removeValue(forKey: alpn)

        if let task = connectionTasks[alpn], let taskID = connectionTaskIDs[alpn] {
            let connected = try await task.value
            if let lease = currentLease(alpn: alpn), lease.connection.stableId() == connected.stableId() {
                return lease
            }
            guard connectionTaskIDs[alpn] == taskID else { throw CancellationError() }
            connectionTasks.removeValue(forKey: alpn)
            connectionTaskIDs.removeValue(forKey: alpn)
            return register(connection: connected, alpn: alpn)
        }

        let endpoint = try await boundEndpoint()
        let metadata = iroh
        let startedAtMs = ChatSessionTelemetry.nowMs()
        let taskID = UUID()
        let task = Task<Connection, Error> {
            try await Self.connect(endpoint: endpoint, iroh: metadata, alpn: alpn)
        }
        connectionTasks[alpn] = task
        connectionTaskIDs[alpn] = taskID
        do {
            let connected = try await task.value
            // Another waiter for this same task may resume first and register the result while
            // this actor is reentrant. Reuse that lease instead of closing its shared connection
            // after the waiter clears task bookkeeping.
            if let lease = currentLease(alpn: alpn), lease.connection.stableId() == connected.stableId() {
                return lease
            }
            guard connectionTaskIDs[alpn] == taskID else {
                try? connected.close(errorCode: 0, reason: Data("superseded".utf8))
                throw CancellationError()
            }
            connectionTasks.removeValue(forKey: alpn)
            connectionTaskIDs.removeValue(forKey: alpn)
            let lease = register(connection: connected, alpn: alpn)
            let evidence = Self.selectedPathEvidence(connection: connected)
            IrohTransportTelemetry.recordConnection(
                durationMs: ChatSessionTelemetry.nowMs() - startedAtMs,
                status: "connected",
                evidence: evidence
            )
            recordSelectedPath(connection: connected, alpn: alpn, reason: "connected")
            return lease
        } catch {
            if connectionTaskIDs[alpn] == taskID {
                connectionTasks.removeValue(forKey: alpn)
                connectionTaskIDs.removeValue(forKey: alpn)
            }
            IrohTransportTelemetry.recordConnection(
                durationMs: ChatSessionTelemetry.nowMs() - startedAtMs,
                status: "failed",
                evidence: nil,
                errorKind: IrohTransportTelemetry.errorKind(error)
            )
            throw error
        }
    }

    private func currentLease(alpn: String) -> ConnectionLease? {
        guard let connection = connections[alpn],
              connection.closeReason() == nil,
              let generation = connectionGenerations.current(alpn: alpn) else {
            return nil
        }
        return ConnectionLease(connection: connection, generation: generation)
    }

    private func register(connection: Connection, alpn: String) -> ConnectionLease {
        if let current = currentLease(alpn: alpn), current.connection.stableId() == connection.stableId() {
            return current
        }
        connections[alpn] = connection
        let generation = connectionGenerations.advance(alpn: alpn)
        return ConnectionLease(connection: connection, generation: generation)
    }

    private func makeByteStream(
        _ stream: BiStream,
        alpn: String,
        generation: UInt64
    ) -> IrohLibByteStream {
        IrohLibByteStream(stream: stream) { [weak self] in
            await self?.invalidateConnectionIfCurrent(alpn: alpn, generation: generation)
        }
    }

    private func invalidateConnectionIfCurrent(alpn: String, generation: UInt64) {
        guard connectionGenerations.invalidateIfCurrent(alpn: alpn, generation: generation) else {
            return
        }
        if let failed = connections.removeValue(forKey: alpn) {
            try? failed.close(errorCode: 0, reason: Data("transport failed".utf8))
        }
        selectedPathKinds.removeValue(forKey: alpn)
        IrohTransportTelemetry.recordReconnect(status: "invalidated", reason: "stream_failure")
    }

    private func recordSelectedPath(connection: Connection, alpn: String, reason: String) {
        guard let evidence = Self.selectedPathEvidence(connection: connection) else { return }
        let current = evidence.pathKind
        let previous = selectedPathKinds.updateValue(current, forKey: alpn)
        let transitionFrom = previous != nil && previous != current ? previous : nil
        guard previous == nil || transitionFrom != nil else { return }
        IrohTransportTelemetry.recordPath(
            evidence,
            reason: reason,
            transitionFrom: transitionFrom
        )
    }

    private static func selectedPathEvidence(connection: Connection) -> IrohSelectedPathEvidence? {
        guard let selected = connection.paths().first(where: \.isSelected) else { return nil }
        return IrohSelectedPathEvidence(
            isIP: selected.isIp,
            isRelay: selected.isRelay,
            rttMs: selected.rttMs
        )
    }

    private static func connect(
        endpoint: Endpoint,
        iroh: IrohServerTransport,
        alpn: String
    ) async throws -> Connection {
        let expectedID: EndpointId
        do {
            expectedID = try EndpointId.fromString(s: iroh.nodeId)
        } catch {
            throw IrohTransportError.malformedNodeID
        }

        let nodeAddress = await endpoint.remoteAddr(id: expectedID)
            ?? EndpointAddr(id: expectedID, relayUrl: nil, addresses: [])
        let alpnData = Data(alpn.utf8)

        let connection: Connection
        switch iroh.addressMode {
        case .nodeId:
            connection = try await connectOnce(endpoint: endpoint, address: nodeAddress, alpn: alpnData)

        case .ticket:
            guard let ticketText = iroh.ticket?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !ticketText.isEmpty else {
                throw IrohTransportError.missingTicket
            }
            let ticketAddress: EndpointAddr
            do {
                ticketAddress = try EndpointTicket.fromString(str: ticketText).endpointAddr()
            } catch {
                throw IrohTransportError.malformedTicket
            }
            try IrohPeerValidator.validateTicketPeer(
                expectedNodeID: iroh.nodeId,
                ticketNodeID: ticketAddress.id().description
            )

            do {
                connection = try await connectOnce(endpoint: endpoint, address: ticketAddress, alpn: alpnData)
            } catch IrohTransportError.unavailable {
                // Tickets are address hints and can age as relay/direct addresses
                // rotate. Retry once by signed node ID through Iroh discovery.
                connection = try await connectOnce(endpoint: endpoint, address: nodeAddress, alpn: alpnData)
            } catch {
                throw error
            }
        }

        try IrohPeerValidator.validateConnectedPeer(
            expectedNodeID: iroh.nodeId,
            remoteNodeID: connection.remoteId().description
        )
        return connection
    }

    private static func connectOnce(
        endpoint: Endpoint,
        address: EndpointAddr,
        alpn: Data
    ) async throws -> Connection {
        do {
            return try await endpoint.connect(addr: address, alpn: alpn)
        } catch let error as IrohError {
            throw mapConnectError(kind: error.kind(), detail: error.localizedDescription)
        } catch {
            // Unknown connect failures are not safe downgrade evidence. The
            // FFI exposes connectivity failures through IrohErrorKind.
            throw IrohTransportError.protocolViolation(
                "Unclassified Iroh connection failure: \(error.localizedDescription)"
            )
        }
    }

    static func mapConnectError(kind: IrohErrorKind, detail: String) -> IrohTransportError {
        switch kind {
        case .connect, .connection, .relay, .closed, .timeout:
            return .unavailable("Iroh peer is unreachable: \(detail)")
        case .alpn:
            return .protocolViolation("Iroh ALPN negotiation failed: \(detail)")
        case .invalidInput, .bind, .keyParsing, .ticketParsing,
             .stream, .datagram, .callback, .internal:
            return .protocolViolation("Iroh connection failed: \(detail)")
        }
    }
}

/// Persistent per-server owner used by pairing frames and the HTTP/WebSocket
/// tunnel. The proxy is app-local and its URL is never written to credentials.
actor IrohConnectionManager {
    let iroh: IrohServerTransport
    private let provider: any IrohConnectionProviding
    private var proxy: IrohLoopbackProxy?
    private var proxyToken: String?

    init(
        iroh: IrohServerTransport,
        provider: (any IrohConnectionProviding)? = nil
    ) {
        self.iroh = iroh
        self.provider = provider ?? IrohLibConnectionProvider(iroh: iroh)
    }

    func exchange(
        alpn: String,
        requestFrame: Data,
        maxResponseBytes: UInt32
    ) async throws -> Data {
        let stream = try await provider.openStream(alpn: alpn)
        do {
            try await stream.write(requestFrame)
            try await stream.finishWriting()

            var response = Data()
            while true {
                let remaining = Int(maxResponseBytes) - response.count
                let chunk = try await stream.read(
                    maxBytes: UInt32(min(max(1, remaining + 1), 64 * 1024))
                )
                if chunk.isEmpty { break }
                guard chunk.count <= remaining else {
                    throw IrohTransportError.framing("Iroh response exceeds \(maxResponseBytes) bytes")
                }
                response.append(chunk)
            }
            return response
        } catch {
            await stream.reset(errorCode: 1)
            throw error
        }
    }

    func startProxy(token: String) async throws -> URL {
        if let proxy, proxyToken == token, let url = proxy.localURL {
            return url
        }

        proxy?.stop()
        let preface = try IrohTunnelProtocol.makePreface(token: token)
        let proxy = IrohLoopbackProxy(
            expectedAuthorization: ServerAuthorization.headerValue(token: token)
        ) { [provider] in
            let stream = try await provider.openStream(alpn: IrohTunnelProtocol.alpn)
            try await stream.write(preface)
            return stream
        }
        let url = try await proxy.start()
        self.proxy = proxy
        proxyToken = token
        return url
    }

    func selectedPathEvidence() async throws -> IrohSelectedPathEvidence? {
        try await provider.selectedPathEvidence(alpn: IrohTunnelProtocol.alpn)
    }

    func prepareForBackground() async {
        await provider.suspendConnections()
    }

    func shutdown() async {
        proxy?.stop()
        proxy = nil
        proxyToken = nil
        await provider.shutdown()
    }
}

enum IrohTransportTelemetry {
    static func recordConnection(
        durationMs: Int64,
        status: String,
        evidence: IrohSelectedPathEvidence?,
        errorKind: String? = nil
    ) {
        var tags = [
            "transport": "iroh",
            "status": status,
            "path": evidence?.pathKind.rawValue ?? IrohPathKind.unknown.rawValue,
        ]
        if let errorKind { tags["error_kind"] = errorKind }
        ChatSessionTelemetry.recordTimingMetric(
            .networkIrohConnectionMs,
            durationMs: durationMs,
            tags: tags
        )
        ClientLog.info("Iroh", "Connection result", metadata: tags)
    }

    static func recordPath(
        _ evidence: IrohSelectedPathEvidence,
        reason: String,
        transitionFrom: IrohPathKind?
    ) {
        let path = evidence.pathKind
        let tags = [
            "transport": "iroh",
            "path": path.rawValue,
            "reason": reason,
        ]
        ChatSessionTelemetry.recordTimingMetric(
            .networkIrohPathRttMs,
            durationMs: Int64(clamping: evidence.rttMs),
            tags: tags
        )
        ClientLog.info("Iroh", "Selected path", metadata: [
            "transport": "iroh",
            "path": path.rawValue,
            "reason": reason,
            "rttMs": String(evidence.rttMs),
        ])
        if let transitionFrom {
            ChatSessionTelemetry.recordCountMetric(
                .networkIrohPathTransition,
                tags: [
                    "transport": "iroh",
                    "from": transitionFrom.rawValue,
                    "to": path.rawValue,
                ]
            )
            ClientLog.info("Iroh", "Path transitioned", metadata: [
                "transport": "iroh",
                "from": transitionFrom.rawValue,
                "to": path.rawValue,
            ])
        }
    }

    static func recordReconnect(status: String, reason: String) {
        let tags = [
            "transport": "iroh",
            "status": status,
            "reason": reason,
        ]
        ChatSessionTelemetry.recordCountMetric(.networkIrohReconnect, tags: tags)
        ClientLog.info("Iroh", "Reconnect", metadata: tags)
    }

    static func recordTunnel(
        durationMs: Int64,
        requestBytes: Int,
        responseBytes: Int,
        status: String
    ) {
        let tags = ["transport": "iroh", "status": status]
        ChatSessionTelemetry.recordTimingMetric(
            .networkIrohTunnelDurationMs,
            durationMs: durationMs,
            tags: tags
        )
        guard requestBytes > 0 || responseBytes > 0 else { return }
        ChatSessionTelemetry.recordCountMetric(
            .networkIrohTunnelRequestBytes,
            value: requestBytes,
            tags: tags
        )
        ChatSessionTelemetry.recordCountMetric(
            .networkIrohTunnelResponseBytes,
            value: responseBytes,
            tags: tags
        )
    }

    static func recordTunnelError(phase: String, errorKind: String) {
        ChatSessionTelemetry.recordCountMetric(
            .networkIrohTunnelError,
            tags: [
                "transport": "iroh",
                "phase": phase,
                "error_kind": errorKind,
            ]
        )
        ClientLog.warning("Iroh", "Tunnel error", metadata: [
            "transport": "iroh",
            "phase": phase,
            "errorKind": errorKind,
        ])
    }

    static func errorKind(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let error = error as? IrohLib.IrohError {
            return switch error.kind() {
            case .invalidInput: "invalid_input"
            case .bind: "bind"
            case .connect: "connect"
            case .connection: "connection"
            case .alpn: "alpn"
            case .keyParsing: "key_parsing"
            case .ticketParsing: "ticket_parsing"
            case .relay: "relay"
            case .stream: "stream"
            case .datagram: "datagram"
            case .callback: "callback"
            case .closed: "closed"
            case .timeout: "timeout"
            case .internal: "internal"
            }
        }
        guard let error = error as? IrohTransportError else { return "other" }
        return switch error {
        case .unsupportedMetadataVersion: "metadata_version"
        case .unsupportedALPN: "alpn"
        case .malformedNodeID: "node_id"
        case .missingTicket: "missing_ticket"
        case .malformedTicket: "malformed_ticket"
        case .ticketPeerMismatch: "ticket_peer"
        case .remotePeerMismatch: "remote_peer"
        case .unavailable: "unavailable"
        case .authentication: "authentication"
        case .framing: "framing"
        case .protocolViolation: "protocol"
        case .listener: "listener"
        }
    }
}

actor IrohTransportRegistry {
    static let shared = IrohTransportRegistry()

    private var managers: [String: IrohConnectionManager] = [:]
    private var metadata: [String: IrohServerTransport] = [:]

    func manager(for iroh: IrohServerTransport) async -> IrohConnectionManager {
        if let manager = managers[iroh.nodeId], metadata[iroh.nodeId] == iroh {
            return manager
        }

        if let old = managers.removeValue(forKey: iroh.nodeId) {
            await old.shutdown()
        }
        let manager = IrohConnectionManager(iroh: iroh)
        managers[iroh.nodeId] = manager
        metadata[iroh.nodeId] = iroh
        return manager
    }

    func startProxy(iroh: IrohServerTransport, token: String) async throws -> (IrohConnectionManager, URL) {
        let manager = await manager(for: iroh)
        return (manager, try await manager.startProxy(token: token))
    }

    func remove(nodeID: String) async {
        metadata.removeValue(forKey: nodeID)
        if let manager = managers.removeValue(forKey: nodeID) {
            await manager.shutdown()
        }
    }
}
