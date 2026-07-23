import Foundation
import Network
import OSLog

private let irohProxyLogger = Logger(
    subsystem: AppIdentifiers.subsystem,
    category: "IrohLoopbackProxy"
)

struct IrohTunnelPumpFailure: Error, @unchecked Sendable {
    enum Endpoint: Sendable {
        case localPeer
        case iroh
    }

    let endpoint: Endpoint
    let underlyingError: Error
}

/// App-local TCP bridge. URLSession and URLSessionWebSocketTask keep their
/// existing HTTP semantics while each accepted TCP connection is carried by
/// one authenticated Iroh bidirectional stream.
///
/// The listener binds an ephemeral IPv4 loopback endpoint and also rejects
/// every accepted peer whose remote endpoint is not loopback before opening
/// an Iroh stream.
final class IrohLoopbackProxy: @unchecked Sendable {
    typealias OpenStream = @Sendable () async throws -> any IrohByteStream

    private static let chunkBytes: UInt32 = 64 * 1024
    private static let maxRequestHeaderBytes = 64 * 1024
    private static let maxConcurrentConnections = 64
    static let defaultInitialHeaderTimeout: Duration = .seconds(2)

    typealias ReceiveChunk = @Sendable () async throws -> (Data, Bool)

    private let queue = DispatchQueue(label: "dev.chenda.oppi.iroh-loopback-proxy")
    private let expectedAuthorization: String
    private let initialHeaderTimeout: Duration
    private let openStream: OpenStream
    private var listener: NWListener?
    private var activeConnections: [UUID: NWConnection] = [:]
    private var startWaiters: [CheckedContinuation<URL, Error>] = []
    private(set) var localURL: URL?

    init(
        expectedAuthorization: String,
        initialHeaderTimeout: Duration = defaultInitialHeaderTimeout,
        openStream: @escaping OpenStream
    ) {
        self.expectedAuthorization = expectedAuthorization
        self.initialHeaderTimeout = initialHeaderTimeout
        self.openStream = openStream
    }

    func start() async throws -> URL {
        if let localURL { return localURL }

        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: IrohTransportError.listener("Iroh proxy was released"))
                    return
                }
                if let localURL = self.localURL {
                    continuation.resume(returning: localURL)
                    return
                }
                self.startWaiters.append(continuation)
                guard self.listener == nil else { return }
                self.startListener()
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.listener?.stateUpdateHandler = nil
            self.listener?.newConnectionHandler = nil
            self.listener?.cancel()
            self.listener = nil
            self.localURL = nil
            let connections = self.activeConnections.values
            self.activeConnections.removeAll()
            for connection in connections {
                connection.cancel()
            }
            self.resumeStartWaiters(
                with: .failure(IrohTransportError.listener("Iroh loopback proxy stopped"))
            )
        }
    }

    private func startListener() {
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = false
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            let listener = try NWListener(using: parameters, on: .any)
            self.listener = listener

            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener else { return }
                self.handleListenerState(state, listener: listener)
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        } catch {
            listener = nil
            resumeStartWaiters(
                with: .failure(IrohTransportError.listener("Unable to create Iroh loopback proxy: \(error.localizedDescription)"))
            )
        }
    }

    private func handleListenerState(_ state: NWListener.State, listener: NWListener) {
        switch state {
        case .ready:
            guard let port = listener.port,
                  port.rawValue != 0,
                  let url = URL(string: "http://127.0.0.1:\(port.rawValue)") else {
                resumeStartWaiters(
                    with: .failure(IrohTransportError.listener("Iroh proxy did not receive an ephemeral port"))
                )
                return
            }
            localURL = url
            irohProxyLogger.info("Iroh loopback proxy ready on ephemeral port \(port.rawValue)")
            resumeStartWaiters(with: .success(url))

        case .failed(let error):
            self.listener = nil
            localURL = nil
            resumeStartWaiters(
                with: .failure(IrohTransportError.listener("Iroh proxy listener failed: \(error.localizedDescription)"))
            )

        case .cancelled:
            self.listener = nil
            localURL = nil

        case .setup, .waiting:
            break

        @unknown default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard Self.isLoopback(connection.endpoint) else {
            irohProxyLogger.error("Rejected non-loopback connection to Iroh proxy")
            connection.cancel()
            return
        }
        guard activeConnections.count < Self.maxConcurrentConnections else {
            irohProxyLogger.error("Rejected Iroh proxy connection at concurrency limit")
            connection.cancel()
            return
        }

        let id = UUID()
        activeConnections[id] = connection
        connection.start(queue: queue)

        Task { [weak self, openStream] in
            guard let self else {
                connection.cancel()
                return
            }
            await self.bridge(connection: connection, openStream: openStream)
            self.queue.async { [weak self] in
                self?.activeConnections.removeValue(forKey: id)
            }
        }
    }

    private func bridge(connection: NWConnection, openStream: OpenStream) async {
        let startedAtMs = ChatSessionTelemetry.nowMs()
        let stream: any IrohByteStream
        let initialRequest: (data: Data, complete: Bool)
        do {
            try await Self.waitUntilReady(connection)
            initialRequest = try await Self.receiveAuthenticatedRequest(
                expectedAuthorization: expectedAuthorization,
                timeout: initialHeaderTimeout,
                onTimeout: {
                    // Cancelling the NWConnection releases a pending receive
                    // continuation and lets the bridge remove this peer.
                    connection.cancel()
                },
                receive: {
                    try await Self.receive(from: connection)
                }
            )
            stream = try await openStream()
            try await stream.write(initialRequest.data)
            if initialRequest.complete {
                try await stream.finishWriting()
            }
        } catch {
            irohProxyLogger.error("Iroh proxy stream setup failed: \(error.localizedDescription, privacy: .public)")
            IrohTransportTelemetry.recordTunnelError(
                phase: "setup",
                errorKind: IrohTransportTelemetry.errorKind(error)
            )
            IrohTransportTelemetry.recordTunnel(
                durationMs: ChatSessionTelemetry.nowMs() - startedAtMs,
                requestBytes: 0,
                responseBytes: 0,
                status: "setup_failed"
            )
            connection.cancel()
            return
        }

        let byteCounter = IrohTunnelByteCounter(requestBytes: initialRequest.data.count)
        var status = "completed"
        do {
            try await Self.runBidirectionalPumps(
                includeLocalToIroh: !initialRequest.complete,
                localToIroh: {
                    try await Self.pumpLocalToIroh(
                        connection: connection,
                        stream: stream,
                        counter: byteCounter
                    )
                },
                irohToLocal: {
                    try await Self.pumpIrohToLocal(
                        stream: stream,
                        connection: connection,
                        counter: byteCounter
                    )
                },
                cancelPeer: { connection.cancel() },
                cancelTransport: { await stream.reset(errorCode: 2) }
            )
        } catch is CancellationError {
            status = "cancelled"
            await stream.reset(errorCode: 2)
        } catch {
            let failure = error as? IrohTunnelPumpFailure
            let underlyingError = failure?.underlyingError ?? error
            let responseBytes = byteCounter.snapshot().responseBytes
            if !Self.shouldRecordTunnelPumpError(error, responseBytes: responseBytes) {
                status = "peer_closed"
                irohProxyLogger.debug("Iroh proxy local peer closed after receiving a response")
            } else {
                status = "failed"
                irohProxyLogger.debug(
                    "Iroh proxy connection ended: \(underlyingError.localizedDescription, privacy: .public)"
                )
                IrohTransportTelemetry.recordTunnelError(
                    phase: "pump",
                    errorKind: IrohTransportTelemetry.errorKind(underlyingError)
                )
            }
            await stream.reset(errorCode: 2)
        }
        let byteSnapshot = byteCounter.snapshot()
        IrohTransportTelemetry.recordTunnel(
            durationMs: ChatSessionTelemetry.nowMs() - startedAtMs,
            requestBytes: byteSnapshot.requestBytes,
            responseBytes: byteSnapshot.responseBytes,
            status: status
        )
        connection.cancel()
    }

    static func runBidirectionalPumps(
        includeLocalToIroh: Bool,
        localToIroh: @escaping @Sendable () async throws -> Void,
        irohToLocal: @escaping @Sendable () async throws -> Void,
        cancelPeer: @escaping @Sendable () -> Void,
        cancelTransport: @escaping @Sendable () async -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: PumpDirection.self) { group in
            if includeLocalToIroh {
                group.addTask {
                    try await localToIroh()
                    return .localToIroh
                }
            }
            group.addTask {
                try await irohToLocal()
                return .irohToLocal
            }

            do {
                while let completed = try await group.next() {
                    if completed == .irohToLocal {
                        cancelPeer()
                        group.cancelAll()
                        return
                    }
                }
            } catch {
                // Release both potentially non-cooperative continuations before the
                // task-group scope drains: NWConnection.receive on the local side and
                // the Iroh FFI read on the remote side. Delaying either cancellation
                // can hide the failure from URLSession or pin this bridge forever.
                cancelPeer()
                await cancelTransport()
                group.cancelAll()
                throw error
            }
        }
    }

    private enum PumpDirection: Sendable {
        case localToIroh
        case irohToLocal
    }

    static func shouldRecordTunnelPumpError(_ error: Error, responseBytes: Int) -> Bool {
        guard let failure = error as? IrohTunnelPumpFailure,
              failure.endpoint == .localPeer,
              responseBytes > 0 else {
            return true
        }
        let error = failure.underlyingError
        if error is CancellationError { return false }
        if let urlError = error as? URLError, urlError.code == .cancelled { return false }

        let code: POSIXErrorCode?
        if case .posix(let posixCode) = error as? NWError {
            code = posixCode
        } else {
            let nsError = error as NSError
            code = nsError.domain == NSPOSIXErrorDomain
                ? POSIXErrorCode(rawValue: Int32(nsError.code))
                : nil
        }
        guard let code else { return true }
        return code != .ECANCELED
            && code != .ECONNRESET
            && code != .EPIPE
            && code != .ENOTCONN
    }

    private static func pumpLocalToIroh(
        connection: NWConnection,
        stream: any IrohByteStream,
        counter: IrohTunnelByteCounter
    ) async throws {
        while !Task.isCancelled {
            let data: Data
            let complete: Bool
            do {
                (data, complete) = try await receive(from: connection)
            } catch {
                throw IrohTunnelPumpFailure(endpoint: .localPeer, underlyingError: error)
            }
            if !data.isEmpty {
                do {
                    try await stream.write(data)
                } catch {
                    throw IrohTunnelPumpFailure(endpoint: .iroh, underlyingError: error)
                }
                counter.addRequestBytes(data.count)
            }
            if complete {
                do {
                    try await stream.finishWriting()
                } catch {
                    throw IrohTunnelPumpFailure(endpoint: .iroh, underlyingError: error)
                }
                return
            }
        }
        throw CancellationError()
    }

    private static func pumpIrohToLocal(
        stream: any IrohByteStream,
        connection: NWConnection,
        counter: IrohTunnelByteCounter
    ) async throws {
        try await pumpIrohToLocal(
            counter: counter,
            read: {
                do {
                    return try await stream.read(maxBytes: chunkBytes)
                } catch {
                    throw IrohTunnelPumpFailure(endpoint: .iroh, underlyingError: error)
                }
            },
            send: { data, isComplete in
                do {
                    try await send(data, isComplete: isComplete, over: connection)
                } catch {
                    throw IrohTunnelPumpFailure(endpoint: .localPeer, underlyingError: error)
                }
            }
        )
    }

    static func pumpIrohToLocal(
        counter: IrohTunnelByteCounter,
        read: @escaping @Sendable () async throws -> Data,
        send: @escaping @Sendable (Data, Bool) async throws -> Void
    ) async throws {
        while !Task.isCancelled {
            let data = try await read()
            if data.isEmpty {
                try await send(Data(), true)
                return
            }
            try await send(data, false)
            counter.addResponseBytes(data.count)
        }
        throw CancellationError()
    }

    static func receiveAuthenticatedRequest(
        expectedAuthorization: String,
        timeout: Duration,
        onTimeout: @escaping @Sendable () -> Void,
        receive: @escaping ReceiveChunk
    ) async throws -> (data: Data, complete: Bool) {
        try await withThrowingTaskGroup(of: InitialRequest.self) { group in
            group.addTask {
                let request = try await collectAuthenticatedRequest(
                    expectedAuthorization: expectedAuthorization,
                    receive: receive
                )
                return InitialRequest(data: request.data, complete: request.complete)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                guard !Task.isCancelled else { throw CancellationError() }
                onTimeout()
                throw IrohTransportError.authentication("Local tunnel request header timed out")
            }

            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return (first.data, first.complete)
        }
    }

    static func collectAuthenticatedRequest(
        expectedAuthorization: String,
        receive: ReceiveChunk
    ) async throws -> (data: Data, complete: Bool) {
        var buffered = Data()
        while true {
            let (data, complete) = try await receive()
            buffered.append(data)
            if try validateLocalRequest(
                buffered,
                expectedAuthorization: expectedAuthorization
            ) {
                return (buffered, complete)
            }
            if complete {
                throw IrohTransportError.authentication("Local tunnel request is missing Authorization")
            }
        }
    }

    /// Returns false until the complete HTTP header is buffered. Once complete,
    /// exactly one matching Authorization header is required before any Iroh
    /// stream is opened.
    static func validateLocalRequest(
        _ data: Data,
        expectedAuthorization: String
    ) throws -> Bool {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator) else {
            if data.count > maxRequestHeaderBytes {
                throw IrohTransportError.framing("Local tunnel request headers exceed \(maxRequestHeaderBytes) bytes")
            }
            return false
        }
        guard headerRange.lowerBound <= maxRequestHeaderBytes else {
            throw IrohTransportError.framing("Local tunnel request headers exceed \(maxRequestHeaderBytes) bytes")
        }

        guard let headerText = String(
            data: data[..<headerRange.lowerBound],
            encoding: .isoLatin1
        ) else {
            throw IrohTransportError.protocolViolation("Local tunnel request headers are malformed")
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first,
              requestLine.split(separator: " ").count == 3 else {
            throw IrohTransportError.protocolViolation("Local tunnel request line is malformed")
        }

        let authorizationValues = lines.dropFirst().compactMap { line -> String? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard name.caseInsensitiveCompare("Authorization") == .orderedSame else { return nil }
            return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard authorizationValues.count == 1,
              authorizationValues[0] == expectedAuthorization else {
            throw IrohTransportError.authentication("Local tunnel request Authorization does not match tunnel context")
        }
        return true
    }

    private struct InitialRequest: Sendable {
        let data: Data
        let complete: Bool
    }

    private static func waitUntilReady(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let resolver = IrohProxyContinuationResolver<Void>(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resolver.resume(.success(()))
                case .failed(let error):
                    resolver.resume(.failure(error))
                case .cancelled:
                    resolver.resume(.failure(CancellationError()))
                case .setup, .preparing, .waiting:
                    break
                @unknown default:
                    break
                }
            }
        }
    }

    private static func receive(from connection: NWConnection) async throws -> (Data, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: Int(chunkBytes)
            ) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data ?? Data(), isComplete))
                }
            }
        }
    }

    private static func send(
        _ data: Data,
        isComplete: Bool,
        over connection: NWConnection
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                contentContext: isComplete ? .finalMessage : .defaultMessage,
                isComplete: isComplete,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            return address == .loopback
        case .ipv6(let address):
            return address == .loopback
        case .name(let name, _):
            return name.caseInsensitiveCompare("localhost") == .orderedSame
        @unknown default:
            return false
        }
    }

    private func resumeStartWaiters(with result: Result<URL, Error>) {
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(with: result)
        }
    }
}

final class IrohTunnelByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var requestBytes: Int
    private var responseBytes = 0

    init(requestBytes: Int = 0) {
        self.requestBytes = requestBytes
    }

    func addRequestBytes(_ count: Int) {
        lock.withLock { requestBytes += count }
    }

    func addResponseBytes(_ count: Int) {
        lock.withLock { responseBytes += count }
    }

    func snapshot() -> (requestBytes: Int, responseBytes: Int) {
        lock.withLock { (requestBytes, responseBytes) }
    }
}

/// Lock-protected one-shot resolver for NWConnection callback races.
private final class IrohProxyContinuationResolver<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<Value, Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}
