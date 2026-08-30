import Darwin
import Foundation
import Testing
@testable import Oppi

@Suite("Mac Unix WebSocket transport", .serialized)
struct MacUnixWebSocketTransportTests {
    @Test func focusedStreamPathIsUnixNotWSS() {
        let path = MacUnixWebSocketTransport.focusedSessionPath(
            workspaceId: "ws-1",
            sessionId: "sess-1"
        )
        #expect(path == "/workspaces/ws-1/sessions/sess-1/stream")
        #expect(
            MacUnixWebSocketTransport.focusedSessionPath(scope: .control, sessionId: "control-1")
                == "/control-sessions/control-1/stream"
        )
        #expect(!path.contains("wss"))
        #expect(!path.contains("https"))
        #expect(MacUnixWebSocketTransport.appEventPath() == "/app/events/stream")
        #expect(MacUnixWebSocketTransport.dictationStreamPath() == "/dictation/stream")
        #expect(!MacUnixWebSocketTransport.dictationStreamPath().contains("wss"))
        #expect(!MacUnixWebSocketTransport.dictationStreamPath().contains("https"))
        #expect(!MacUnixWebSocketTransport.dictationStreamPath().contains("sk_"))
    }

    @Test func dictationAuthStaysInBearerHeaderNotThePath() {
        let token = "sk_secret"
        let path = MacUnixWebSocketTransport.dictationStreamPath()
        let headers = MacUnixWebSocketTransport.ownerHeaders(token: token)
        #expect(path == DictationComposerPolicy.streamPath)
        #expect(!path.contains(token))
        #expect(!path.contains("wss"))
        #expect(!path.contains("https"))
        #expect(headers["Authorization"] == "Bearer \(token)")
        #expect(headers.keys.contains("Authorization"))
        #expect(!headers.keys.contains(where: { $0.lowercased() == "token" }))
    }

    @Test func connectFailsIfAlreadyFinished() async throws {
        let transport = MacUnixWebSocketTransport(
            socketPath: "/tmp/oppi-ws-unconnected.sock",
            path: "/"
        )
        transport.cancel()
        do {
            try await transport.connect()
            Issue.record("Expected connect to fail closed")
        } catch let error as WebSocketTransportError {
            #expect(error == .cancelled)
        } catch {
            Issue.record("Expected cancelled, got \(error)")
        }
    }

    @Test func sendBeforeConnectCannotEmitDataFrameBefore101() async throws {
        let probe = try UnixHandshakeProbe.start()
        defer { probe.stop() }

        let transport = MacUnixWebSocketTransport(socketPath: probe.socketPath, path: "/stream")
        let sendTask = Task { try await transport.send(.text("early")) }
        let pingTask = Task { try await transport.ping() }
        let connectError: Error?
        do {
            try await transport.connect()
            connectError = nil
        } catch {
            connectError = error
        }
        let sendError: Error?
        do {
            try await sendTask.value
            sendError = nil
        } catch {
            sendError = error
        }
        _ = await pingTask.result

        let before101 = probe.snapshotBefore101()
        #expect(before101.starts(with: Data("GET /stream HTTP/1.1".utf8)))
        let headerRange = before101.range(of: Data("\r\n\r\n".utf8))
        #expect(headerRange?.upperBound == before101.endIndex)

        if connectError != nil || sendError != nil {
            Issue.record(
                "connect/send failed before a post-101 data frame: \(String(describing: connectError)) \(String(describing: sendError))"
            )
            return
        }
        try await probe.waitForFrame(.text("early"))
        await transport.close(code: 1000, reason: nil)
    }

    @Test func loopbackUnixSocketSpeaksWithNodeWS() async throws {
        let echo = try NodeUnixWebSocketEcho.start()
        defer { echo.stop() }

        let first = MacUnixWebSocketTransport(socketPath: echo.socketPath, path: "/")
        try await first.connect()
        try await first.send(.text("hello"))
        #expect(try await first.receive() == .text("hello"))
        try await first.send(.data(Data([0x00, 0xFF, 0x10])))
        #expect(try await first.receive() == .data(Data([0x00, 0xFF, 0x10])))
        try await first.ping()
        try await first.send(.text("close-please"))
        do {
            _ = try await first.receive()
            Issue.record("Expected close after close-please")
        } catch let error as WebSocketTransportError {
            guard case .closed(let close) = error else {
                Issue.record("Expected closed error, got \(error)")
                return
            }
            #expect(close.code == 1000)
        }

        let second = MacUnixWebSocketTransport(socketPath: echo.socketPath, path: "/")
        try await second.connect()
        try await second.send(.text("again"))
        #expect(try await second.receive() == .text("again"))
        await second.close(code: 1000, reason: nil)
    }

    @Test func appEventStreamAgainstLiveOwnerSocket() async throws {
        // Opt in with OTHER_SWIFT_FLAGS=-DOPPI_REQUIRE_LIVE_OWNER_STREAM for
        // release/live-follow gates. The ordinary unit suite must not depend
        // on whichever Oppi build happens to own the shared socket.
#if OPPI_REQUIRE_LIVE_OWNER_STREAM
        let requiresLiveOwnerStream = true
#else
        let requiresLiveOwnerStream = false
#endif
        guard requiresLiveOwnerStream else {
            return
        }

        let dataDir = NSString("~/.config/oppi").expandingTildeInPath
        let socketPath = MacLocalAPISocket.path(dataDir: dataDir)
        #expect(
            FileManager.default.fileExists(atPath: socketPath),
            "Live owner socket is missing at \(socketPath)"
        )
        guard FileManager.default.fileExists(atPath: socketPath) else {
            return
        }
        let token = try #require(MacAPIClient.readOwnerToken(dataDir: dataDir))

        let transport = MacUnixWebSocketTransport(
            socketPath: socketPath,
            path: MacUnixWebSocketTransport.appEventPath(),
            headers: MacUnixWebSocketTransport.ownerHeaders(token: token)
        )
        try await transport.connect()
        let message = try await transport.receive()
        guard case .text(let text) = message else {
            Issue.record("Expected text app-event frame")
            await transport.close(code: 1000, reason: nil)
            return
        }
        let event = try AppEventMessage.decode(from: text)
        guard case .connected(_, let snapshotRequired) = event else {
            Issue.record("Expected app_events_connected, got \(event)")
            await transport.close(code: 1000, reason: nil)
            return
        }
        #expect(snapshotRequired)
        await transport.close(code: 1000, reason: nil)
    }
}

/// Records raw Unix bytes and replies 101 only after a complete GET.
/// First-byte mismatches are snapshotted without 101 so a premature data frame fails fast.
private final class UnixHandshakeProbe: @unchecked Sendable {
    let socketPath: String
    private let listenFD: Int32
    private let queue = DispatchQueue(label: "dev.chenda.OppiMac.unix-ws-probe")
    private let lock = NSLock()
    private var listenSource: DispatchSourceRead?
    private var clientSource: DispatchSourceRead?
    private var clientFD: Int32 = -1
    private var buffer = Data()
    private var bytesBefore101 = Data()
    private var didUpgrade = false
    private var stopped = false
    private var decoder = WebSocketFrameDecoder()
    private var frames: [WebSocketDecodedFrame] = []
    private var frameWaiters: [(WebSocketDecodedFrame, CheckedContinuation<Void, Error>)] = []

    private init(socketPath: String, listenFD: Int32) {
        self.socketPath = socketPath
        self.listenFD = listenFD
    }

    static func start() throws -> UnixHandshakeProbe {
        let socketPath = "/tmp/oppi-ws-order-\(UUID().uuidString).sock"
        unlink(socketPath)

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw WebSocketTransportError.handshakeFailed("socket() failed")
        }
        do {
            try bindUnix(fd: fd, path: socketPath)
        } catch {
            Darwin.close(fd)
            throw error
        }
        guard Darwin.listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw WebSocketTransportError.handshakeFailed("listen() failed")
        }
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let probe = UnixHandshakeProbe(socketPath: socketPath, listenFD: fd)
        probe.startAccepting()
        return probe
    }

    func snapshotBefore101() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return bytesBefore101
    }

    func waitForFrame(_ expected: WebSocketDecodedFrame) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if frames.contains(expected) {
                lock.unlock()
                continuation.resume()
                return
            }
            if stopped {
                lock.unlock()
                continuation.resume(throwing: WebSocketTransportError.cancelled)
                return
            }
            frameWaiters.append((expected, continuation))
            lock.unlock()
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        let waiters = frameWaiters
        frameWaiters = []
        let listen = listenSource
        let client = clientSource
        let accepted = clientFD
        listenSource = nil
        clientSource = nil
        clientFD = -1
        lock.unlock()
        waiters.forEach { $0.1.resume(throwing: WebSocketTransportError.cancelled) }
        listen?.cancel()
        client?.cancel()
        if accepted >= 0 {
            Darwin.close(accepted)
        }
        Darwin.close(listenFD)
        unlink(socketPath)
    }

    private func startAccepting() {
        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptClient()
        }
        listenSource = source
        source.resume()
    }

    private func acceptClient() {
        lock.lock()
        if stopped || clientFD >= 0 {
            lock.unlock()
            return
        }
        lock.unlock()

        let fd = Darwin.accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        var nosig: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        lock.lock()
        clientFD = fd
        lock.unlock()

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.readClient()
        }
        lock.lock()
        clientSource = source
        lock.unlock()
        source.resume()
    }

    private func readClient() {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = Darwin.recv(clientFD, &chunk, chunk.count, 0)
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                }
                return
            }
            if count == 0 {
                return
            }
            consume(Data(chunk[0..<count]))
        }
    }

    private func consume(_ data: Data) {
        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        buffer.append(data)
        if didUpgrade {
            let pongs = decodeLocked(data)
            lock.unlock()
            pongs.forEach { sendUnmasked(opcode: 0xA, payload: $0) }
            return
        }

        if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
            bytesBefore101 = buffer
            let request = buffer.subdata(in: buffer.startIndex..<headerEnd.upperBound)
            let remainder = buffer.subdata(in: headerEnd.upperBound..<buffer.endIndex)
            didUpgrade = true
            lock.unlock()
            reply101(request: request)
            if !remainder.isEmpty {
                lock.lock()
                let pongs = decodeLocked(remainder)
                lock.unlock()
                pongs.forEach { sendUnmasked(opcode: 0xA, payload: $0) }
            }
            return
        }

        if let first = buffer.first, first != UInt8(ascii: "G") {
            bytesBefore101 = buffer
            lock.unlock()
            closeClient()
            return
        }
        if buffer.count >= 4, !buffer.starts(with: Data("GET ".utf8)) {
            bytesBefore101 = buffer
            lock.unlock()
            closeClient()
            return
        }
        lock.unlock()
    }

    private func decodeLocked(_ data: Data) -> [Data] {
        do {
            let decoded = try decoder.append(data)
            frames.append(contentsOf: decoded)
            var remaining: [(WebSocketDecodedFrame, CheckedContinuation<Void, Error>)] = []
            for waiter in frameWaiters {
                if frames.contains(waiter.0) {
                    waiter.1.resume()
                } else {
                    remaining.append(waiter)
                }
            }
            frameWaiters = remaining
            return decoded.compactMap { frame in
                if case .ping(let payload) = frame {
                    return payload
                }
                return nil
            }
        } catch {
            frameWaiters.forEach { $0.1.resume(throwing: error) }
            frameWaiters = []
            return []
        }
    }

    private func reply101(request: Data) {
        guard let key = secWebSocketKey(from: request) else {
            closeClient()
            return
        }
        let accept = WebSocketFrameCodec.acceptKey(for: key)
        let response = Data(
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n".utf8
        )
        writeAll(response)
    }

    private func sendUnmasked(opcode: UInt8, payload: Data) {
        guard payload.count <= 125 else { return }
        var frame = Data([0x80 | opcode, UInt8(payload.count)])
        frame.append(payload)
        writeAll(frame)
    }

    private func writeAll(_ data: Data) {
        lock.lock()
        let fd = clientFD
        lock.unlock()
        guard fd >= 0 else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = Darwin.send(fd, base.advanced(by: offset), data.count - offset, 0)
                if written <= 0 {
                    return
                }
                offset += written
            }
        }
    }

    private func closeClient() {
        lock.lock()
        let fd = clientFD
        clientFD = -1
        let source = clientSource
        clientSource = nil
        lock.unlock()
        source?.cancel()
        if fd >= 0 {
            Darwin.close(fd)
        }
    }

    private func secWebSocketKey(from request: Data) -> String? {
        guard let text = String(data: request, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            if parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "sec-websocket-key" {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func bindUnix(fd: Int32, path: String) throws {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathLength = path.utf8.count
        guard pathLength < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw WebSocketTransportError.handshakeFailed("Unix path too long")
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: path.utf8)
            raw[pathLength] = 0
        }
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            throw WebSocketTransportError.handshakeFailed("bind() failed")
        }
    }
}

private final class NodeUnixWebSocketEcho {
    let socketPath: String
    private let process: Process

    private init(socketPath: String, process: Process) {
        self.socketPath = socketPath
        self.process = process
    }

    static func start() throws -> NodeUnixWebSocketEcho {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixture = testsDir.appendingPathComponent("Fixtures/unix-ws-echo.mjs")
        let serverRoot = testsDir
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("server")
        #expect(FileManager.default.fileExists(atPath: fixture.path))
        #expect(FileManager.default.fileExists(atPath: serverRoot.appendingPathComponent("package.json").path))

        let socketPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("oppi-unix-ws-\(UUID().uuidString).sock")
            .path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/node")
        process.arguments = [fixture.path, socketPath]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "OPPI_SERVER_ROOT": serverRoot.path,
        ]) { _, new in new }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()

        let ready = waitForReady(pipe: pipe, process: process)
        if !ready {
            process.terminate()
            throw WebSocketTransportError.handshakeFailed("Node ws echo did not become ready")
        }
        return NodeUnixWebSocketEcho(socketPath: socketPath, process: process)
    }

    func stop() {
        process.terminate()
        process.waitUntilExit()
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private static func waitForReady(pipe: Pipe, process: Process) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        var buffer = Data()
        while Date() < deadline, process.isRunning {
            let available = pipe.fileHandleForReading.availableData
            if !available.isEmpty {
                buffer.append(available)
                if let text = String(data: buffer, encoding: .utf8), text.contains("ready ") {
                    return true
                }
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }
}
