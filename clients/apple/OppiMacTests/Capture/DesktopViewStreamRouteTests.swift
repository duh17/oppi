import CoreVideo
import Darwin
import Foundation
import ScreenCaptureKit
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
        #expect(hello["width"] == nil)
        #expect(hello["height"] == nil)
        #expect((hello["features"] as? [String]) == [DesktopViewStreamWire.featureAvcc])
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
        harness.capturer.emit(try makeRouteNV12())
        let media = try waitForMedia(fd: stream.fd, leftover: &leftover)
        #expect(media.count > DesktopViewStreamWire.mediaHeaderBytes)
        #expect(harness.encoder.encodedFrameIds == [1])
        #expect(harness.capturer.lastFps == 10)
        #expect(harness.capturer.lastScale == 0.5)
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

    @Test func captureStopOtherThanUnavailableEndsTheStream() throws {
        let harness = try LiveSocketHarness()
        defer { harness.tearDown() }
        pickWindow(harness.session, harness.fake, makeSurface(windowID: 403, title: "Notes"))
        harness.session.grantView()
        _ = try harness.session.viewGrantGate.claim(deviceId: "phone-1", deviceName: "Chen iPhone").get()
        let stream = try unixUpgrade(
            socketPath: harness.socket.socketPath,
            path: DesktopViewStreamWire.path,
            headers: [DesktopViewGrantHTTP.deviceID: "phone-1"]
        )
        defer { Darwin.close(stream.fd) }
        var leftover = stream.leftover
        _ = try waitForJSON(fd: stream.fd, leftover: &leftover) { $0["type"] as? String == "hello" }
        #expect(harness.session.viewGrantStatusText.contains("live to Chen iPhone"))
        harness.capturer.emitEnded()
        let error = try waitForJSON(fd: stream.fd, leftover: &leftover) { $0["type"] as? String == "error" }
        #expect(error["code"] as? Int == DesktopViewStreamWire.errorSurfaceGone)
        #expect(!harness.session.viewGrantGate.isLiveDelivery)
        #expect(!harness.session.viewGrantStatusText.contains("live to"))
    }

    @Test func lateEncodeAfterFailIsNotWrittenToANewAttach() throws {
        let harness = try LiveSocketHarness()
        defer { harness.tearDown() }
        pickWindow(harness.session, harness.fake, makeSurface(windowID: 404, title: "Mail"))
        harness.session.grantView()
        _ = try harness.session.viewGrantGate.claim(deviceId: "phone-1", deviceName: "Chen iPhone").get()
        harness.encoder.holdDeliveries = true
        let first = try unixUpgrade(
            socketPath: harness.socket.socketPath,
            path: DesktopViewStreamWire.path,
            headers: [DesktopViewGrantHTTP.deviceID: "phone-1"]
        )
        var leftover = first.leftover
        _ = try waitForJSON(fd: first.fd, leftover: &leftover) { $0["type"] as? String == "hello" }
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
        try writeAll(fd: first.fd, data: encode)
        harness.capturer.emit(try makeRouteNV12())
        let encodedDeadline = Date().addingTimeInterval(1)
        while Date() < encodedDeadline, harness.encoder.encodedFrameIds != [1] {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        #expect(harness.encoder.encodedFrameIds == [1])
        harness.live.stop()
        _ = try waitForJSON(fd: first.fd, leftover: &leftover) { $0["type"] as? String == "error" }

        let second = try unixUpgrade(
            socketPath: harness.socket.socketPath,
            path: DesktopViewStreamWire.path,
            headers: [DesktopViewGrantHTTP.deviceID: "phone-1"]
        )
        defer { Darwin.close(second.fd) }
        var secondLeftover = second.leftover
        _ = try waitForJSON(fd: second.fd, leftover: &secondLeftover) { $0["type"] as? String == "hello" }
        harness.encoder.releaseHeld()
        var timeout = timeval(tv_sec: 0, tv_usec: 150_000)
        _ = setsockopt(second.fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var secondSawMedia = false
        do {
            let media = try waitForMedia(fd: second.fd, leftover: &secondLeftover)
            secondSawMedia = !media.isEmpty
        } catch {
            secondSawMedia = false
        }
        #expect(!secondSawMedia)
    }

    @Test func scStreamStopWithNonUnavailableErrorEndsTheProducer() {
        let flags = StopFlags()
        let producer = DesktopSCStreamLiveViewProducer(
            surface: makeSurface(windowID: 405, title: "Notes"),
            offer: { _, _ in },
            ended: { flags.ended = true },
            surfaceUnavailable: { _ in flags.unavailable = true },
            finished: { _ in flags.finished = true }
        )
        let error = NSError(
            domain: SCStreamErrorDomain,
            code: SCStreamError.Code.userStopped.rawValue
        )
        producer.handleDidStop(error)
        #expect(flags.ended)
        #expect(flags.finished)
        #expect(!flags.unavailable)
    }

    @Test func stopDuringRetireDoesNotStartQueuedCapture() throws {
        let harness = try LiveSocketHarness()
        defer { harness.tearDown() }
        pickWindow(harness.session, harness.fake, makeSurface(windowID: 406, title: "Notes"))
        harness.session.grantView()
        _ = try harness.session.viewGrantGate.claim(deviceId: "phone-1", deviceName: "Chen iPhone").get()
        let first = try unixUpgrade(
            socketPath: harness.socket.socketPath,
            path: DesktopViewStreamWire.path,
            headers: [DesktopViewGrantHTTP.deviceID: "phone-1"]
        )
        var leftover = first.leftover
        _ = try waitForJSON(fd: first.fd, leftover: &leftover) { $0["type"] as? String == "hello" }
        #expect(harness.capturer.startCount == 1)
        harness.live.stop()
        _ = try waitForJSON(fd: first.fd, leftover: &leftover) { $0["type"] as? String == "error" }
        #expect(harness.capturer.isRetiring)

        let second = try unixUpgrade(
            socketPath: harness.socket.socketPath,
            path: DesktopViewStreamWire.path,
            headers: [DesktopViewGrantHTTP.deviceID: "phone-1"]
        )
        defer { Darwin.close(second.fd) }
        var secondLeftover = second.leftover
        _ = try waitForJSON(fd: second.fd, leftover: &secondLeftover) { $0["type"] as? String == "hello" }
        #expect(harness.capturer.startCount == 1)
        #expect(harness.capturer.hasPendingStart)
        harness.live.stop()
        _ = try waitForJSON(fd: second.fd, leftover: &secondLeftover) { $0["type"] as? String == "error" }
        harness.capturer.completeRetire()
        #expect(harness.capturer.startCount == 1)
        #expect(!harness.capturer.hasPendingStart)
    }
}

private final class StopFlags: @unchecked Sendable {
    var ended = false
    var unavailable = false
    var finished = false
}

@MainActor
private final class LiveSocketHarness {
    let runtimeRoot: URL
    let fake: FakeDesktopCaptureService
    let session: DesktopCaptureSession
    let encoder: FakeDesktopFrameEncoder
    let capturer: FakeLiveViewCapturer
    let live: DesktopLiveViewSession
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
        encoder = FakeDesktopFrameEncoder()
        capturer = FakeLiveViewCapturer()
        live = DesktopLiveViewSession(
            grantGate: viewGrantGate,
            source: source,
            encoder: encoder,
            capturer: capturer
        )
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

final class FakeDesktopFrameEncoder: DesktopFrameEncoding, @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [DesktopH264EncodeCommand] = []

    var encodedFrameIds: [UInt32] {
        lock.lock()
        defer { lock.unlock() }
        return commands.map(\.frameId)
    }

    var holdDeliveries = false
    private var held: [(Data, (Data) -> Void)] = []

    func encode(
        buffer: CVPixelBuffer,
        capturedAt: Date,
        command: DesktopH264EncodeCommand,
        deliver: @escaping (Data) -> Void
    ) {
        lock.lock()
        commands.append(command)
        let media = DesktopViewStreamWire.mediaCompanionFrame(
            header: .init(
                keyframe: command.keyframe,
                frameId: command.frameId,
                capturedAtMs: UInt64(capturedAt.timeIntervalSince1970 * 1000),
                width: UInt16(CVPixelBufferGetWidth(buffer)),
                height: UInt16(CVPixelBufferGetHeight(buffer)),
                payloadBytes: 8
            ),
            avcc: Data(repeating: 0xAA, count: 8)
        )
        if holdDeliveries {
            held.append((media, deliver))
            lock.unlock()
            return
        }
        lock.unlock()
        deliver(media)
    }

    func prepare() {}

    func invalidate() {}

    func releaseHeld() {
        lock.lock()
        let pending = held
        held = []
        lock.unlock()
        for (media, deliver) in pending {
            deliver(media)
        }
    }
}

final class FakeLiveViewCapturer: DesktopLiveViewCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var offer: (@Sendable (CVPixelBuffer, Date) -> Void)?
    private var ended: (@Sendable () -> Void)?
    private(set) var lastFps: Double?
    private(set) var lastScale: Double?
    private(set) var startCount = 0
    private var retiring = false
    private var pending: (
        offer: @Sendable (CVPixelBuffer, Date) -> Void,
        ended: @Sendable () -> Void,
        fps: Double,
        scale: Double
    )?

    var hasPendingStart: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pending != nil
    }

    var isRetiring: Bool {
        lock.lock()
        defer { lock.unlock() }
        return retiring
    }

    func startLiveView(
        offer: @escaping @Sendable (CVPixelBuffer, Date) -> Void,
        ended: @escaping @Sendable () -> Void,
        fps: Double,
        scale: Double
    ) {
        lock.lock()
        if self.offer != nil || retiring {
            pending = (offer, ended, fps, scale)
            lock.unlock()
            return
        }
        applyStartLocked(offer: offer, ended: ended, fps: fps, scale: scale)
        lock.unlock()
    }

    func updateLiveView(fps: Double, scale: Double) {
        lock.lock()
        lastFps = fps
        lastScale = scale
        lock.unlock()
    }

    func stopLiveView() {
        lock.lock()
        pending = nil
        let hadProducer = offer != nil
        offer = nil
        ended = nil
        if hadProducer {
            retiring = true
        }
        lock.unlock()
    }

    func completeRetire() {
        lock.lock()
        retiring = false
        let queued = pending
        pending = nil
        if let queued {
            applyStartLocked(offer: queued.offer, ended: queued.ended, fps: queued.fps, scale: queued.scale)
        }
        lock.unlock()
    }

    private func applyStartLocked(
        offer: @escaping @Sendable (CVPixelBuffer, Date) -> Void,
        ended: @escaping @Sendable () -> Void,
        fps: Double,
        scale: Double
    ) {
        self.offer = offer
        self.ended = ended
        lastFps = fps
        lastScale = scale
        startCount += 1
    }

    func emit(_ buffer: CVPixelBuffer, at capturedAt: Date = Date()) {
        lock.lock()
        let offer = self.offer
        lock.unlock()
        offer?(buffer, capturedAt)
    }

    func emitEnded() {
        lock.lock()
        let ended = self.ended
        lock.unlock()
        ended?()
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
    case pixelBuffer
}

private func makeRouteNV12() throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        64,
        36,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        nil,
        &buffer
    )
    guard status == kCVReturnSuccess, let buffer else { throw LiveStreamTestError.pixelBuffer }
    return buffer
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
