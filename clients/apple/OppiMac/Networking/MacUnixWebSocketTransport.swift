import Foundation
import Network
import Security

/// RFC 6455 WebSocket over the owner Unix socket.
///
/// Opens `NWConnection(to: .unix, using: .tcp)`, performs the HTTP upgrade
/// for a canonical stream path, then handles masked client frames. `sk_` is
/// sent only on this socket.
final class MacUnixWebSocketTransport: WebSocketTransporting, @unchecked Sendable {
    let socketPath: String
    let path: String
    let headers: [String: String]

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "dev.chenda.OppiMac.unix-ws")
    private let lock = NSLock()
    private var decoder = WebSocketFrameDecoder()
    private var handshakeBuffer = Data()
    private var handshakeContinuation: CheckedContinuation<Void, Error>?
    private var handshakeKey: String?
    private var didCompleteHandshake = false
    private var incoming: [WebSocketTransportMessage] = []
    private var receiveWaiters: [CheckedContinuation<WebSocketTransportMessage, Error>] = []
    private var pongWaiters: [CheckedContinuation<Void, Error>] = []
    private var isWriting = false
    private var pendingHandshake: Data?
    private var pendingWrites: [PendingWrite] = []
    private var finishedError: Error?
    private var started = false

    private struct PendingWrite {
        let data: Data
        let continuation: CheckedContinuation<Void, Error>?
    }

    init(socketPath: String, path: String, headers: [String: String] = [:]) {
        self.socketPath = socketPath
        self.path = path
        self.headers = headers
        connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
    }

    func connect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if let finishedError {
                lock.unlock()
                continuation.resume(throwing: finishedError)
                return
            }
            if started {
                lock.unlock()
                continuation.resume(throwing: WebSocketTransportError.handshakeFailed("Already started"))
                return
            }
            started = true
            handshakeContinuation = continuation
            lock.unlock()

            connection.stateUpdateHandler = { [weak self] state in
                self?.handle(state)
            }
            connection.start(queue: queue)
        }
    }

    func send(_ message: WebSocketTransportMessage) async throws {
        let payload: (WebSocketOpcode, Data)
        switch message {
        case .text(let text):
            payload = (.text, Data(text.utf8))
        case .data(let data):
            payload = (.binary, data)
        }
        let frame = try WebSocketFrameCodec.encodeFrame(
            opcode: payload.0,
            payload: payload.1,
            mask: Self.randomMask()
        )
        try await sendRaw(frame)
    }

    func receive() async throws -> WebSocketTransportMessage {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let finishedError {
                lock.unlock()
                continuation.resume(throwing: finishedError)
                return
            }
            if !incoming.isEmpty {
                let message = incoming.removeFirst()
                lock.unlock()
                continuation.resume(returning: message)
                return
            }
            receiveWaiters.append(continuation)
            lock.unlock()
        }
    }

    func ping() async throws {
        let payload = Data(UUID().uuidString.utf8)
        let frame = try WebSocketFrameCodec.encodeFrame(
            opcode: .ping,
            payload: payload,
            mask: Self.randomMask()
        )
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if let finishedError {
                lock.unlock()
                continuation.resume(throwing: finishedError)
                return
            }
            pongWaiters.append(continuation)
            lock.unlock()
            enqueueWrite(frame, continuation: nil)
        }
    }

    func close(code: UInt16, reason: Data?) async {
        if let frame = try? WebSocketFrameCodec.encodeClose(
            code: code,
            reason: reason ?? Data(),
            mask: Self.randomMask()
        ) {
            enqueueWrite(frame, continuation: nil)
        }
        failAll(WebSocketTransportError.closed(WebSocketTransportClose(code: code, reason: reason ?? Data())))
        connection.cancel()
    }

    func cancel() {
        failAll(WebSocketTransportError.cancelled)
        connection.cancel()
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            startHandshake()
        case .failed(let error):
            failAll(WebSocketTransportError.handshakeFailed(error.localizedDescription))
            connection.cancel()
        case .cancelled:
            failAll(WebSocketTransportError.cancelled)
        default:
            break
        }
    }

    private func startHandshake() {
        let key = WebSocketFrameCodec.makeKey()
        lock.lock()
        if finishedError != nil {
            lock.unlock()
            return
        }
        handshakeKey = key
        lock.unlock()
        // RFC 6455: the HTTP upgrade is the only write until 101 completes.
        enqueueHandshake(WebSocketFrameCodec.encodeUpgradeRequest(path: path, headers: headers, key: key))
    }

    private func receiveMore() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.failAll(WebSocketTransportError.handshakeFailed(error.localizedDescription))
                self.connection.cancel()
                return
            }
            if let data, !data.isEmpty {
                self.consume(data)
            }
            if isComplete {
                self.failAll(WebSocketTransportError.closed(WebSocketTransportClose(code: 1006, reason: Data())))
                return
            }
            self.lock.lock()
            let finished = self.finishedError != nil
            self.lock.unlock()
            if !finished {
                self.receiveMore()
            }
        }
    }

    private func consume(_ data: Data) {
        lock.lock()
        let handshakeDone = didCompleteHandshake
        lock.unlock()
        if !handshakeDone {
            finishHandshakeIfPossible(data)
            return
        }
        deliverFrames(data)
    }

    private func finishHandshakeIfPossible(_ data: Data) {
        lock.lock()
        handshakeBuffer.append(data)
        let buffer = handshakeBuffer
        let key = handshakeKey
        lock.unlock()
        do {
            guard let parsed = try WebSocketFrameCodec.parseUpgradeResponse(buffer), let key else {
                return
            }
            try WebSocketFrameCodec.validateUpgrade(
                status: parsed.status,
                headers: parsed.headers,
                clientKey: key
            )
            lock.lock()
            didCompleteHandshake = true
            handshakeBuffer = Data()
            let continuation = handshakeContinuation
            handshakeContinuation = nil
            let shouldStart = !isWriting && !pendingWrites.isEmpty
            if shouldStart {
                isWriting = true
            }
            lock.unlock()
            continuation?.resume()
            if shouldStart {
                writeNext()
            }
            if !parsed.remainder.isEmpty {
                deliverFrames(parsed.remainder)
            }
        } catch {
            failAll(error)
            connection.cancel()
        }
    }

    private func deliverFrames(_ data: Data) {
        let frames: [WebSocketDecodedFrame]
        lock.lock()
        do {
            frames = try decoder.append(data)
            lock.unlock()
        } catch {
            lock.unlock()
            failAll(error)
            connection.cancel()
            return
        }
        for frame in frames {
            handle(frame)
        }
    }

    private func handle(_ frame: WebSocketDecodedFrame) {
        switch frame {
        case .text(let text):
            deliver(.text(text))
        case .binary(let data):
            deliver(.data(data))
        case .ping(let payload):
            if let pong = try? WebSocketFrameCodec.encodeFrame(
                opcode: .pong,
                payload: payload,
                mask: Self.randomMask()
            ) {
                enqueueWrite(pong, continuation: nil)
            }
        case .pong:
            lock.lock()
            let waiter = pongWaiters.isEmpty ? nil : pongWaiters.removeFirst()
            lock.unlock()
            waiter?.resume()
        case .close(let code, let reason):
            failAll(WebSocketTransportError.closed(WebSocketTransportClose(code: code, reason: reason)))
            connection.cancel()
        }
    }

    private func deliver(_ message: WebSocketTransportMessage) {
        lock.lock()
        if !receiveWaiters.isEmpty {
            let waiter = receiveWaiters.removeFirst()
            lock.unlock()
            waiter.resume(returning: message)
            return
        }
        incoming.append(message)
        lock.unlock()
    }

    private func sendRaw(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if let finishedError {
                lock.unlock()
                continuation.resume(throwing: finishedError)
                return
            }
            lock.unlock()
            enqueueWrite(data, continuation: continuation)
        }
    }

    private func enqueueHandshake(_ data: Data) {
        lock.lock()
        if finishedError != nil {
            lock.unlock()
            return
        }
        pendingHandshake = data
        let shouldStart = !isWriting
        if shouldStart {
            isWriting = true
        }
        lock.unlock()
        if shouldStart {
            writeNext()
        }
    }

    private func enqueueWrite(_ data: Data, continuation: CheckedContinuation<Void, Error>?) {
        lock.lock()
        if let finishedError {
            lock.unlock()
            continuation?.resume(throwing: finishedError)
            return
        }
        pendingWrites.append(PendingWrite(data: data, continuation: continuation))
        // Queue send/ping until 101; never let a data frame beat the GET upgrade.
        let shouldStart = !isWriting && didCompleteHandshake
        if shouldStart {
            isWriting = true
        }
        lock.unlock()
        if shouldStart {
            writeNext()
        }
    }

    private func writeNext() {
        lock.lock()
        if finishedError != nil {
            isWriting = false
            lock.unlock()
            return
        }
        if !didCompleteHandshake {
            if let handshake = pendingHandshake {
                pendingHandshake = nil
                lock.unlock()
                connection.send(content: handshake, completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if let error {
                        self.failAll(WebSocketTransportError.handshakeFailed(error.localizedDescription))
                        self.connection.cancel()
                        return
                    }
                    self.lock.lock()
                    let finished = self.finishedError != nil
                    self.lock.unlock()
                    if finished {
                        return
                    }
                    self.receiveMore()
                    self.writeNext()
                })
                return
            }
            isWriting = false
            lock.unlock()
            return
        }
        guard !pendingWrites.isEmpty else {
            isWriting = false
            lock.unlock()
            return
        }
        let next = pendingWrites.removeFirst()
        lock.unlock()
        connection.send(content: next.data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                next.continuation?.resume(
                    throwing: WebSocketTransportError.handshakeFailed(error.localizedDescription)
                )
                self.failAll(WebSocketTransportError.handshakeFailed(error.localizedDescription))
                self.connection.cancel()
                return
            }
            next.continuation?.resume()
            self.writeNext()
        })
    }

    private func failAll(_ error: Error) {
        lock.lock()
        if finishedError != nil {
            lock.unlock()
            return
        }
        finishedError = error
        pendingHandshake = nil
        let handshake = handshakeContinuation
        handshakeContinuation = nil
        let receives = receiveWaiters
        receiveWaiters = []
        let pongs = pongWaiters
        pongWaiters = []
        let writes = pendingWrites
        pendingWrites = []
        lock.unlock()
        handshake?.resume(throwing: error)
        receives.forEach { $0.resume(throwing: error) }
        pongs.forEach { $0.resume(throwing: error) }
        writes.forEach { $0.continuation?.resume(throwing: error) }
    }

    private static func randomMask() -> Data {
        var bytes = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, 4, &bytes)
        return Data(bytes)
    }
}

extension MacUnixWebSocketTransport {
    static func ownerHeaders(token: String) -> [String: String] {
        ["Authorization": "Bearer \(token)"]
    }

    static func appEventPath() -> String { "/app/events/stream" }

    static func dictationStreamPath() -> String { DictationComposerPolicy.streamPath }

    static func focusedSessionPath(workspaceId: String, sessionId: String) -> String {
        focusedSessionPath(scope: .workspace(workspaceId), sessionId: sessionId)
    }

    static func focusedSessionPath(scope: SessionRouteScope, sessionId: String) -> String {
        "\(MacWorkspaceClient.focusedSessionPath(scope: scope, sessionId: sessionId))/stream"
    }
}
