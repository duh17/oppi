import Darwin
import Foundation
import Testing
@testable import Oppi

@Suite("Desktop live-view companion stream")
@MainActor
struct DesktopViewStreamRouteTests {
    @Test func upgradeRequiresBoundGrantAndForwardsEncode() throws {
        let harness = try LiveSocketHarness()
        defer { harness.tearDown() }

        let missing = try unixHTTPGet(
            socketPath: harness.socket.socketPath,
            path: DesktopViewStreamWire.path,
            headers: [DesktopViewGrantHTTP.deviceID: "phone-1"]
        )
        #expect(missing.statusCode == 403)

        pickWindow(harness.session, harness.fake, makeSurface(windowID: 401, title: "Notes"))
        harness.session.grantView()
        let unbound = try unixHTTPGet(
            socketPath: harness.socket.socketPath,
            path: DesktopViewStreamWire.path,
            headers: [DesktopViewGrantHTTP.deviceID: "phone-1"]
        )
        #expect(unbound.statusCode == 403)
        #expect(String(data: unbound.body, encoding: .utf8) == DesktopViewGrantHTTP.notBoundBody)

        #expect(try harness.session.viewGrantGate.claim(deviceId: "phone-1", deviceName: "Chen iPhone").get().deviceId == "phone-1")
        let stream = try unixUpgrade(
            socketPath: harness.socket.socketPath,
            path: DesktopViewStreamWire.path,
            headers: [DesktopViewGrantHTTP.deviceID: "phone-1"]
        )
        defer { Darwin.close(stream.fd) }
        #expect(stream.statusCode == 101)
        var leftover = stream.leftover
        let hello = try waitForJSON(fd: stream.fd, leftover: &leftover) { $0["type"] as? String == "hello" }
        #expect(hello["deviceId"] as? String == "phone-1")
        #expect(harness.session.viewGrantStatusText.contains("live to Chen iPhone"))
        #expect(!harness.session.viewGrantStatusText.localizedCaseInsensitiveContains("not live"))

        guard let encode = DesktopViewStreamWire.jsonFrame([
            "type": "encode",
            "frameId": 1,
            "bitrate": 400000,
            "fps": 10,
            "scale": 0.5,
            "keyframe": true,
        ]) else {
            throw LiveStreamTestError.invalidResponse
        }
        try writeAll(fd: stream.fd, data: encode)
        let media = try waitForMedia(fd: stream.fd, leftover: &leftover)
        #expect(media.count > DesktopViewStreamWire.mediaHeaderBytes)
        #expect(harness.live.encodedFrameIds == [1])
    }

    @Test func revokeClosesAnOpenStream() throws {
        let harness = try LiveSocketHarness()
        defer { harness.tearDown() }
        pickWindow(harness.session, harness.fake, makeSurface(windowID: 402, title: "Mail"))
        harness.session.grantView()
        _ = try harness.session.viewGrantGate.claim(deviceId: "phone-1", deviceName: "Chen iPhone").get()
        let stream = try unixUpgrade(
            socketPath: harness.socket.socketPath,
            path: DesktopViewStreamWire.path,
            headers: [DesktopViewGrantHTTP.deviceID: "phone-1"]
        )
        defer { Darwin.close(stream.fd) }
        #expect(stream.statusCode == 101)
        var leftover = stream.leftover
        _ = try waitForJSON(fd: stream.fd, leftover: &leftover) { $0["type"] as? String == "hello" }
        harness.session.revokeViewGrant()
        let error = try waitForJSON(fd: stream.fd, leftover: &leftover) { $0["type"] as? String == "error" }
        #expect(error["code"] as? Int == DesktopViewStreamWire.errorGrantRevoked)
    }
}

@MainActor
private final class LiveSocketHarness {
    let runtimeRoot: URL
    let fake: FakeDesktopCaptureService
    let session: DesktopCaptureSession
    let live: FakeDesktopLiveView
    let socket: DesktopCompanionOwnerSocket
    private var toreDown = false

    init() throws {
        runtimeRoot = URL(fileURLWithPath: "/tmp/oppi-dv-\(UUID().uuidString)", isDirectory: true)
        fake = FakeDesktopCaptureService()
        let shareGate = DesktopStillShareGate()
        let viewGrantGate = DesktopViewGrantGate()
        let source = DesktopLiveViewSource()
        session = DesktopCaptureSession(
            service: fake,
            shareGate: shareGate,
            viewGrantGate: viewGrantGate,
            liveViewSource: source
        )
        live = FakeDesktopLiveView(grantGate: viewGrantGate, source: source)
        socket = DesktopCompanionOwnerSocket(
            shareGate: shareGate,
            viewGrantGate: viewGrantGate,
            liveView: live,
            runtimeRoot: runtimeRoot
        )
        try socket.start()
    }

    func tearDown() {
        guard !toreDown else { return }
        toreDown = true
        socket.stop()
        try? FileManager.default.removeItem(at: runtimeRoot)
    }
}

final class FakeDesktopLiveView: DesktopLiveViewStreaming, @unchecked Sendable {
    private(set) var encodedFrameIds: [UInt32] = []
    private let grantGate: DesktopViewGrantGate
    private let source: DesktopLiveViewSource
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var stopped = true
    private let queue = DispatchQueue(label: "dev.chenda.OppiMacTests.fake-live")

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !stopped && fd >= 0
    }

    init(grantGate: DesktopViewGrantGate, source: DesktopLiveViewSource) {
        self.grantGate = grantGate
        self.source = source
        grantGate.setInvalidationHandler { [weak self] in
            self?.fail(code: DesktopViewStreamWire.errorGrantRevoked, message: "View grant revoked")
        }
    }

    func attach(fd: Int32, deviceId: String, deviceName: String?) -> Result<Void, DesktopLiveViewAttachFailure> {
        guard let grant = grantGate.current(), grant.deviceId == deviceId else {
            return .failure(grantGate.current() == nil ? .unavailable : .notBound)
        }
        guard let snapshot = source.current() else { return .failure(.unavailable) }
        lock.lock()
        self.fd = fd
        stopped = false
        lock.unlock()
        grantGate.setLiveDelivery(true)
        let hello: [String: Any] = [
            "type": "hello",
            "version": Int(DesktopViewStreamWire.version),
            "features": [DesktopViewStreamWire.featureAnnexB],
            "grantId": grant.grantId.uuidString,
            "deviceId": deviceId,
            "surface": [
                "windowId": Int(snapshot.surface.surfaceID.windowID),
                "title": snapshot.surface.title,
            ],
            "width": 64,
            "height": 36,
        ]
        if let data = DesktopViewStreamWire.jsonFrame(hello) {
            write(data)
        }
        queue.async { [weak self] in
            self?.readLoop()
        }
        _ = deviceName
        return .success(())
    }

    func stop() {
        fail(code: DesktopViewStreamWire.errorSurfaceGone, message: "stopped")
    }

    private func readLoop() {
        var chunk = [UInt8](repeating: 0, count: 4096)
        let reader = DesktopViewCompanionReader()
        while true {
            lock.lock()
            let current = fd
            let isStopped = stopped
            lock.unlock()
            if isStopped || current < 0 { return }
            let count = chunk.withUnsafeMutableBytes { raw in
                Darwin.read(current, raw.baseAddress, raw.count)
            }
            if count <= 0 { return }
            let frames = (try? reader.push(Data(chunk.prefix(count)))) ?? []
            for frame in frames {
                guard frame.type == DesktopViewStreamWire.jsonType,
                      let json = DesktopViewStreamWire.parseJSON(frame.payload),
                      json["type"] as? String == "encode"
                else { continue }
                let frameId = (json["frameId"] as? NSNumber)?.uint32Value ?? 0
                lock.lock()
                encodedFrameIds.append(frameId)
                lock.unlock()
                let media = DesktopViewStreamWire.mediaCompanionFrame(
                    header: .init(
                        keyframe: true,
                        frameId: frameId,
                        capturedAtMs: 1_770_000_000_000,
                        width: 64,
                        height: 36,
                        payloadBytes: 8
                    ),
                    annexB: Data(repeating: 0xAA, count: 8)
                )
                write(media)
            }
        }
    }

    private func fail(code: Int, message: String) {
        lock.lock()
        let current = fd
        let already = stopped
        stopped = true
        fd = -1
        lock.unlock()
        if already { return }
        grantGate.setLiveDelivery(false)
        if current >= 0 {
            if let data = DesktopViewStreamWire.jsonFrame([
                "type": "error",
                "code": code,
                "message": message,
                "fatal": true,
            ]) {
                write(data, fd: current)
            }
            Darwin.shutdown(current, SHUT_RDWR)
            Darwin.close(current)
        }
    }

    private func write(_ data: Data, fd override: Int32? = nil) {
        lock.lock()
        let current = override ?? fd
        lock.unlock()
        guard current >= 0 else { return }
        _ = data.withUnsafeBytes { raw in
            Darwin.write(current, raw.baseAddress, data.count)
        }
    }
}

private struct UpgradeResponse {
    var statusCode: Int
    var fd: Int32
    var leftover: Data
}

private enum LiveStreamTestError: Error {
    case connectFailed
    case timeout
    case invalidResponse
}

private func unixHTTPGet(
    socketPath: String,
    path: String,
    headers: [String: String] = [:]
) throws -> (statusCode: Int, body: Data) {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw LiveStreamTestError.connectFailed }
    defer { Darwin.close(fd) }
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    try connectUnix(fd: fd, path: socketPath)
    var request = "GET \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n"
    for (name, value) in headers {
        request += "\(name): \(value)\r\n"
    }
    request += "\r\n"
    try writeAll(fd: fd, data: Data(request.utf8))
    Darwin.shutdown(fd, SHUT_WR)
    let buffer = try readAvailable(fd: fd, stopAtClose: true)
    return try parseHTTP(buffer)
}

private func unixUpgrade(
    socketPath: String,
    path: String,
    headers: [String: String]
) throws -> UpgradeResponse {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw LiveStreamTestError.connectFailed }
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    try connectUnix(fd: fd, path: socketPath)
    var request =
        "GET \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: \(DesktopViewStreamWire.companionUpgrade)\r\n"
    for (name, value) in headers {
        request += "\(name): \(value)\r\n"
    }
    request += "\r\n"
    try writeAll(fd: fd, data: Data(request.utf8))
    var buffer = Data()
    let separator = Data("\r\n\r\n".utf8)
    while buffer.range(of: separator) == nil {
        buffer.append(try readChunk(fd: fd))
        if buffer.count > 65_536 { throw LiveStreamTestError.invalidResponse }
    }
    let parsed = try parseHTTP(buffer)
    let leftover: Data
    if let range = buffer.range(of: separator) {
        leftover = buffer.subdata(in: range.upperBound..<buffer.endIndex)
    } else {
        leftover = Data()
    }
    return UpgradeResponse(statusCode: parsed.statusCode, fd: fd, leftover: leftover)
}

private func waitForJSON(
    fd: Int32,
    leftover: inout Data,
    match: ([String: Any]) -> Bool
) throws -> [String: Any] {
    let reader = DesktopViewCompanionReader()
    if !leftover.isEmpty {
        let frames = try reader.push(leftover)
        leftover = Data()
        for frame in frames where frame.type == DesktopViewStreamWire.jsonType {
            if let json = DesktopViewStreamWire.parseJSON(frame.payload), match(json) {
                leftover.append(contentsOf: [])
                return json
            }
        }
    }
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
        let chunk = try readChunk(fd: fd)
        let frames = try reader.push(chunk)
        for frame in frames where frame.type == DesktopViewStreamWire.jsonType {
            if let json = DesktopViewStreamWire.parseJSON(frame.payload), match(json) {
                return json
            }
        }
    }
    throw LiveStreamTestError.timeout
}

private func waitForMedia(fd: Int32, leftover: inout Data) throws -> Data {
    let reader = DesktopViewCompanionReader()
    if !leftover.isEmpty {
        let frames = try reader.push(leftover)
        leftover = Data()
        if let media = frames.first(where: { $0.type == DesktopViewStreamWire.mediaType }) {
            return media.payload
        }
    }
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
        let chunk = try readChunk(fd: fd)
        let frames = try reader.push(chunk)
        if let media = frames.first(where: { $0.type == DesktopViewStreamWire.mediaType }) {
            return media.payload
        }
    }
    throw LiveStreamTestError.timeout
}

private func connectUnix(fd: Int32, path: String) throws {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
        throw LiveStreamTestError.connectFailed
    }
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.copyBytes(from: pathBytes)
        raw[pathBytes.count] = 0
    }
    let result = withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else { throw LiveStreamTestError.connectFailed }
}

private func writeAll(fd: Int32, data: Data) throws {
    var offset = 0
    while offset < data.count {
        let written = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return Darwin.write(fd, base.advanced(by: offset), data.count - offset)
        }
        if written <= 0 { throw LiveStreamTestError.connectFailed }
        offset += written
    }
}

private func readChunk(fd: Int32) throws -> Data {
    var chunk = [UInt8](repeating: 0, count: 4096)
    let count = chunk.withUnsafeMutableBytes { raw in
        Darwin.read(fd, raw.baseAddress, raw.count)
    }
    if count <= 0 { throw LiveStreamTestError.timeout }
    return Data(chunk.prefix(count))
}

private func readAvailable(fd: Int32, stopAtClose: Bool) throws -> Data {
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = chunk.withUnsafeMutableBytes { raw in
            Darwin.read(fd, raw.baseAddress, raw.count)
        }
        if count == 0 { break }
        if count < 0 { throw LiveStreamTestError.timeout }
        buffer.append(contentsOf: chunk.prefix(count))
        if buffer.count > 2_000_000 { break }
        if !stopAtClose, buffer.count > 0 { break }
    }
    return buffer
}

private func parseHTTP(_ buffer: Data) throws -> (statusCode: Int, body: Data) {
    let separator = Data("\r\n\r\n".utf8)
    guard let headerRange = buffer.range(of: separator),
          let headerText = String(
            data: buffer.subdata(in: buffer.startIndex..<headerRange.lowerBound),
            encoding: .utf8
          )
    else {
        throw LiveStreamTestError.invalidResponse
    }
    let statusLine = headerText.split(separator: "\r\n", omittingEmptySubsequences: false).first ?? ""
    let parts = statusLine.split(separator: " ")
    guard parts.count >= 2, let status = Int(parts[1]) else {
        throw LiveStreamTestError.invalidResponse
    }
    return (status, buffer.subdata(in: headerRange.upperBound..<buffer.endIndex))
}
