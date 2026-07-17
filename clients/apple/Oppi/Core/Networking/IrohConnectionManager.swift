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

struct IrohSelectedPathEvidence: Equatable, Sendable {
    let isIP: Bool
    let isRelay: Bool
    let rttMs: UInt64
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

    func write(_ data: Data) async throws {
        try await stream.send().writeAll(buf: data)
    }

    func finishWriting() async throws {
        try await stream.send().finish()
    }

    func read(maxBytes: UInt32) async throws -> Data {
        try await stream.recv().read(sizeLimit: maxBytes)
    }

    func reset(errorCode: UInt64) async {
        try? await stream.send().reset(errorCode: errorCode)
        try? await stream.recv().stop(errorCode: errorCode)
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

    init(iroh: IrohServerTransport) {
        self.iroh = iroh
    }

    func openStream(alpn: String) async throws -> any IrohByteStream {
        try IrohPeerValidator.validate(iroh, requiredALPN: alpn)

        let connection = try await connection(for: alpn)
        do {
            return IrohLibByteStream(stream: try await connection.openBi())
        } catch {
            // A cached QUIC connection can close between closeReason() and
            // openBi(). Invalidate only that ALPN and reconnect once.
            connections.removeValue(forKey: alpn)
            let replacement = try await self.connection(for: alpn)
            do {
                return IrohLibByteStream(stream: try await replacement.openBi())
            } catch {
                throw IrohTransportError.unavailable("Unable to open Iroh stream: \(error.localizedDescription)")
            }
        }
    }

    func selectedPathEvidence(alpn: String) async throws -> IrohSelectedPathEvidence? {
        let connection = try await connection(for: alpn)
        guard let selected = connection.paths().first(where: \.isSelected) else { return nil }
        return IrohSelectedPathEvidence(
            isIP: selected.isIp,
            isRelay: selected.isRelay,
            rttMs: selected.rttMs
        )
    }

    func suspendConnections() async {
        let active = connections.values
        connections.removeAll()
        connectionTasks.values.forEach { $0.cancel() }
        connectionTasks.removeAll()
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

    private func connection(for alpn: String) async throws -> Connection {
        if let connection = connections[alpn], connection.closeReason() == nil {
            try IrohPeerValidator.validateConnectedPeer(
                expectedNodeID: iroh.nodeId,
                remoteNodeID: connection.remoteId().description
            )
            return connection
        }
        connections.removeValue(forKey: alpn)

        if let task = connectionTasks[alpn] {
            return try await task.value
        }

        let endpoint = try await boundEndpoint()
        let metadata = iroh
        let task = Task<Connection, Error> {
            try await Self.connect(endpoint: endpoint, iroh: metadata, alpn: alpn)
        }
        connectionTasks[alpn] = task
        do {
            let connected = try await task.value
            connectionTasks.removeValue(forKey: alpn)
            connections[alpn] = connected
            return connected
        } catch {
            connectionTasks.removeValue(forKey: alpn)
            throw error
        }
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
        } catch {
            throw IrohTransportError.unavailable("Iroh peer is unreachable: \(error.localizedDescription)")
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
