import Foundation
import Network

/// HTTP/1.1 client for the owner-only Unix socket.
///
/// This is the Mac equivalent of the CLI local API client: bearer `sk_` over
/// `$OPPI_DATA_DIR/run/oppi.sock`. It must not be used against HTTPS.
actor MacUnixSocketHTTPClient: MacLocalHTTPPerforming {
    let socketPath: String
    private let timeout: Duration

    init(socketPath: String, timeout: TimeInterval = 10) {
        self.socketPath = socketPath
        self.timeout = .seconds(timeout)
    }

    func perform(_ request: MacLocalHTTPRequest) async throws -> MacLocalHTTPResponse {
        let payload = MacLocalHTTPCodec.encode(request)
        let timeout = self.timeout
        return try await withThrowingTaskGroup(of: MacLocalHTTPResponse.self) { group in
            group.addTask { try await self.exchange(payload) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw MacLocalHTTPError.timeout
            }
            guard let result = try await group.next() else {
                throw MacLocalHTTPError.incompleteResponse
            }
            group.cancelAll()
            return result
        }
    }

    private func exchange(_ payload: Data) async throws -> MacLocalHTTPResponse {
        let session = UnixHTTPExchange(socketPath: socketPath, payload: payload)
        return try await withTaskCancellationHandler {
            try await session.run()
        } onCancel: {
            session.cancel()
        }
    }
}

/// Owns one NWConnection so send/receive callbacks stay on a Sendable object.
private final class UnixHTTPExchange: @unchecked Sendable {
    private let connection: NWConnection
    private let payload: Data
    private let once = ResumeOnce<MacLocalHTTPResponse>()
    private let queue = DispatchQueue(label: "dev.chenda.OppiMac.unix-http")
    private let lock = NSLock()
    private var buffer = Data()

    init(socketPath: String, payload: Data) {
        self.payload = payload
        connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
    }

    func run() async throws -> MacLocalHTTPResponse {
        try await withCheckedThrowingContinuation { continuation in
            once.arm(continuation)
            connection.stateUpdateHandler = { [weak self] state in
                self?.handle(state)
            }
            connection.start(queue: queue)
        }
    }

    func cancel() {
        connection.cancel()
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            connection.send(content: payload, completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.fail(MacLocalHTTPError.connectionFailed(error.localizedDescription))
                    return
                }
                self?.receiveMore()
            })
        case .failed(let error):
            fail(MacLocalHTTPError.connectionFailed(error.localizedDescription))
        case .cancelled:
            once.resume(throwing: CancellationError())
        default:
            break
        }
    }

    private func receiveMore() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.fail(MacLocalHTTPError.connectionFailed(error.localizedDescription))
                return
            }
            if let data, !data.isEmpty {
                self.lock.lock()
                self.buffer.append(data)
                let buffer = self.buffer
                self.lock.unlock()
                self.finishIfPossible(buffer: buffer, connectionClosed: isComplete)
            } else {
                self.lock.lock()
                let buffer = self.buffer
                self.lock.unlock()
                self.finishIfPossible(buffer: buffer, connectionClosed: isComplete)
            }
        }
    }

    private func finishIfPossible(buffer: Data, connectionClosed: Bool) {
        do {
            if let response = try MacLocalHTTPCodec.parse(buffer, connectionClosed: connectionClosed) {
                succeed(response)
                return
            }
            if connectionClosed {
                fail(MacLocalHTTPError.incompleteResponse)
                return
            }
            receiveMore()
        } catch {
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        connection.cancel()
        once.resume(throwing: error)
    }

    private func succeed(_ response: MacLocalHTTPResponse) {
        connection.cancel()
        once.resume(returning: response)
    }
}

/// Resumes a checked continuation at most once across NWConnection callbacks.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var finished = false

    func arm(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func resume(returning value: T) {
        lock.lock()
        let continuation = takeContinuation()
        lock.unlock()
        continuation?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        let continuation = takeContinuation()
        lock.unlock()
        continuation?.resume(throwing: error)
    }

    private func takeContinuation() -> CheckedContinuation<T, Error>? {
        guard !finished else { return nil }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        return continuation
    }
}
