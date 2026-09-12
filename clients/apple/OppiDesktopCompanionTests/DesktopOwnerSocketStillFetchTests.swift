import CoreGraphics
import Darwin
import Foundation
import ImageIO
import Testing
@testable import OppiDesktopCompanion

@Suite("Desktop owner-socket still fetch")
@MainActor
struct DesktopOwnerSocketStillFetchTests {
    @Test func fetchReturnsImmutableSharedStillWhenSharingIsOn() throws {
        let harness = try SocketHarness()
        defer { harness.tearDown() }
        let still = harness.captureAndShare()
        let captures = harness.fake.captureCount

        let response = try unixHTTPGet(
            socketPath: harness.socket.socketPath,
            path: "/still/\(still.captureID.uuidString)"
        )

        #expect(response.statusCode == 200)
        #expect(response.headers["content-type"] == "image/png")
        #expect(response.headers["x-oppi-capture-id"] == still.captureID.uuidString)
        #expect(response.headers["x-oppi-surface-window-id"] == "91")
        #expect(response.headers["x-oppi-surface-title"] == "Notes")
        #expect(response.headers["x-oppi-caption"] == "Still—not live")
        #expect(response.headers["x-oppi-width"] == "1")
        #expect(response.headers["x-oppi-height"] == "1")
        #expect(response.headers["x-oppi-captured-at"] == DesktopStillShareHTTP.date(still.capturedAt))
        #expect(response.body.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(pngDimensions(response.body)?.0 == 1)
        #expect(pngDimensions(response.body)?.1 == 1)
        #expect(harness.fake.captureCount == captures)
        #expect(harness.runtimePNGFiles().isEmpty)
        #expect(!harness.session.isLivePreview)
    }

    @Test func fetchRejectsWhenSharingIsOff() throws {
        let harness = try SocketHarness()
        defer { harness.tearDown() }
        let still = harness.captureStill()

        let response = try unixHTTPGet(
            socketPath: harness.socket.socketPath,
            path: "/still/\(still.captureID.uuidString)"
        )

        #expect(response.statusCode == 403)
        #expect(!response.body.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(harness.fake.captureCount == 1)
        #expect(harness.session.still?.captureID == still.captureID)
    }

    @Test func fetchRejectsStaleIDAfterClearReselectAndRevoke() throws {
        let harness = try SocketHarness()
        defer { harness.tearDown() }
        let firstSurface = makeSurface(windowID: 92, title: "Code")
        pickWindow(harness.session, harness.fake, firstSurface)
        harness.session.captureOnce()
        let first = makeStill(surface: firstSurface)
        harness.fake.completePending(.success(first))
        harness.session.enableLocalShare()

        let sharedPath = "/still/\(first.captureID.uuidString)"
        let shared = try unixHTTPGet(socketPath: harness.socket.socketPath, path: sharedPath)
        #expect(shared.statusCode == 200)

        harness.session.revokeLocalShare()
        let afterRevoke = try unixHTTPGet(socketPath: harness.socket.socketPath, path: sharedPath)
        #expect(afterRevoke.statusCode == 403)
        #expect(!afterRevoke.body.starts(with: [0x89, 0x50, 0x4E, 0x47]))

        harness.session.enableLocalShare()
        harness.session.clear()
        let afterClear = try unixHTTPGet(socketPath: harness.socket.socketPath, path: sharedPath)
        #expect(afterClear.statusCode == 403)

        pickWindow(harness.session, harness.fake, firstSurface)
        harness.session.captureOnce()
        harness.fake.completePending(.success(first))
        harness.session.enableLocalShare()
        let secondSurface = makeSurface(windowID: 93, title: "Preview")
        pickWindow(harness.session, harness.fake, secondSurface)
        let afterReselect = try unixHTTPGet(socketPath: harness.socket.socketPath, path: sharedPath)
        #expect(afterReselect.statusCode == 403)

        harness.session.captureOnce()
        let second = makeStill(surface: secondSurface)
        harness.fake.completePending(.success(second))
        harness.session.enableLocalShare()
        let staleWhileSharing = try unixHTTPGet(socketPath: harness.socket.socketPath, path: sharedPath)
        #expect(staleWhileSharing.statusCode == 404)
        let current = try unixHTTPGet(
            socketPath: harness.socket.socketPath,
            path: "/still/\(second.captureID.uuidString)"
        )
        #expect(current.statusCode == 200)
        #expect(harness.fake.captureCount == 3)
    }

    @Test func fetchRejectsUnauthorizedPeerAndDoesNotCapture() throws {
        let harness = try SocketHarness(authorizer: RejectingDesktopOwnerSocketPeerAuthorizer())
        defer { harness.tearDown() }
        let still = harness.captureAndShare()
        let captures = harness.fake.captureCount

        let response = try unixHTTPGet(
            socketPath: harness.socket.socketPath,
            path: "/still/\(still.captureID.uuidString)"
        )

        #expect(response.statusCode == 403)
        #expect(!response.body.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(harness.fake.captureCount == captures)
    }

    @Test func listenerIsUnixOnlyWithPrivateModesAndRefusesConcurrentOwners() throws {
        let harness = try SocketHarness()
        defer { harness.tearDown() }

        #expect(harness.socket.socketAddressFamily == AF_UNIX)
        #expect(posixMode(harness.socket.runtimeDirectory.path) == 0o700)
        #expect(posixMode(harness.socket.socketPath) == 0o600)
        #expect(posixMode(harness.socket.lockPath) == 0o600)
        var socketStat = stat()
        #expect(lstat(harness.socket.socketPath, &socketStat) == 0)
        #expect((socketStat.st_mode & S_IFMT) == S_IFSOCK)

        let second = DesktopCompanionOwnerSocket(
            shareGate: harness.session.shareGate,
            runtimeRoot: harness.runtimeRoot
        )
        #expect(throws: DesktopCompanionOwnerSocketError.self) {
            try second.start()
        }

        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "OppiDesktopCompanion/DesktopCompanionOwnerSocket.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(source.contains("chmod"))
        #expect(source.contains("0o600"))
        #expect(source.contains("0o700"))
        #expect(source.contains("getpeereid"))
        #expect(!source.contains("oppi.sock"))
        #expect(!source.contains("hostPort"))
        #expect(!source.contains("NWListener"))
        #expect(!source.contains("AF_INET"))
        #expect(!source.contains("iroh"))
        #expect(!source.contains("0.0.0.0"))
    }

    @Test func fetchDoesNotIncrementCaptureCountOrChangeOneOutstandingCapture() throws {
        let harness = try SocketHarness()
        defer { harness.tearDown() }
        let surface = makeSurface(windowID: 94, title: "Maps")
        pickWindow(harness.session, harness.fake, surface)
        harness.session.captureOnce()
        harness.session.captureOnce()
        #expect(harness.fake.captureCount == 1)
        #expect(harness.session.isCaptureInFlight)

        let inFlightID = UUID()
        let inFlight = try unixHTTPGet(
            socketPath: harness.socket.socketPath,
            path: "/still/\(inFlightID.uuidString)"
        )
        #expect(inFlight.statusCode == 403)
        #expect(harness.fake.captureCount == 1)
        #expect(harness.session.isCaptureInFlight)
        #expect(harness.session.still == nil)

        let still = makeStill(surface: surface)
        harness.fake.completePending(.success(still))
        harness.session.enableLocalShare()
        let captures = harness.fake.captureCount
        let response = try unixHTTPGet(
            socketPath: harness.socket.socketPath,
            path: "/still/\(still.captureID.uuidString)"
        )
        #expect(response.statusCode == 200)
        #expect(harness.fake.captureCount == captures)

        let post = try unixHTTP(
            socketPath: harness.socket.socketPath,
            method: "POST",
            path: "/still/\(still.captureID.uuidString)"
        )
        #expect(post.statusCode == 405)
        #expect(harness.fake.captureCount == captures)
    }

    @Test func processStopInvalidatesFetchabilityWithoutRecallingBytes() throws {
        let harness = try SocketHarness()
        let still = harness.captureAndShare()
        let path = "/still/\(still.captureID.uuidString)"
        let before = try unixHTTPGet(socketPath: harness.socket.socketPath, path: path)
        #expect(before.statusCode == 200)

        harness.socket.stop()
        #expect(throws: UnixHTTPClientError.self) {
            try unixHTTPGet(socketPath: harness.socket.socketPath, path: path)
        }
        #expect(!FileManager.default.fileExists(atPath: harness.socket.socketPath))
        #expect(!FileManager.default.fileExists(atPath: harness.socket.lockPath))
        harness.tearDownRuntime()
    }

    @Test func captureServiceFencesStayCaptureOnly() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "OppiDesktopCompanion/ScreenCaptureKitDesktopCaptureService.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(source.contains("SCScreenshotManager.captureImage"))
        #expect(!source.contains("fileURL"))
        #expect(!source.contains("SCStream("))
        #expect(!source.contains("startCapture"))
        #expect(!source.contains("CGRequestScreenCaptureAccess"))
        #expect(!source.contains("com.apple.developer.persistent-content-capture"))
    }
}

@MainActor
private final class SocketHarness {
    let runtimeRoot: URL
    let fake: FakeDesktopCaptureService
    let session: DesktopCaptureSession
    let socket: DesktopCompanionOwnerSocket
    private var toreDown = false

    init(authorizer: any DesktopOwnerSocketPeerAuthorizing = SameUserDesktopOwnerSocketPeerAuthorizer()) throws {
        runtimeRoot = URL(fileURLWithPath: "/tmp/oppi-dc-\(UUID().uuidString)", isDirectory: true)
        fake = FakeDesktopCaptureService()
        let gate = DesktopStillShareGate()
        session = DesktopCaptureSession(service: fake, shareGate: gate)
        socket = DesktopCompanionOwnerSocket(
            shareGate: gate,
            runtimeRoot: runtimeRoot,
            peerAuthorizer: authorizer
        )
        try socket.start()
    }

    func captureStill(windowID: UInt32 = 91, title: String = "Notes") -> CapturedStill {
        let surface = makeSurface(windowID: windowID, title: title)
        pickWindow(session, fake, surface)
        session.captureOnce()
        let still = makeStill(surface: surface)
        fake.completePending(.success(still))
        return still
    }

    func captureAndShare(windowID: UInt32 = 91, title: String = "Notes") -> CapturedStill {
        let still = captureStill(windowID: windowID, title: title)
        session.enableLocalShare()
        return still
    }

    func runtimePNGFiles() -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: runtimeRoot.path) else { return [] }
        var matches: [String] = []
        while let path = enumerator.nextObject() as? String {
            if path.lowercased().hasSuffix(".png") {
                matches.append(path)
            }
        }
        return matches
    }

    func tearDown() {
        socket.stop()
        tearDownRuntime()
    }

    func tearDownRuntime() {
        guard !toreDown else { return }
        toreDown = true
        try? FileManager.default.removeItem(at: runtimeRoot)
    }
}

private struct RejectingDesktopOwnerSocketPeerAuthorizer: DesktopOwnerSocketPeerAuthorizing {
    func isAuthorized(uid: uid_t) -> Bool { false }
}

private struct UnixHTTPResponse {
    var statusCode: Int
    var headers: [String: String]
    var body: Data
}

private enum UnixHTTPClientError: Error {
    case connectFailed
    case incompleteResponse
    case invalidResponse
}

private func unixHTTPGet(socketPath: String, path: String) throws -> UnixHTTPResponse {
    try unixHTTP(socketPath: socketPath, method: "GET", path: path)
}

private func unixHTTP(socketPath: String, method: String, path: String) throws -> UnixHTTPResponse {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw UnixHTTPClientError.connectFailed }
    defer { Darwin.close(fd) }

    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    try connectUnix(fd: fd, path: socketPath)
    let request = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
    try writeAll(fd: fd, data: Data(request.utf8))
    Darwin.shutdown(fd, SHUT_WR)
    let buffer = try readAll(fd: fd)
    return try parseHTTPResponse(buffer)
}

private func connectUnix(fd: Int32, path: String) throws {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
        throw UnixHTTPClientError.connectFailed
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
    guard result == 0 else { throw UnixHTTPClientError.connectFailed }
}

private func writeAll(fd: Int32, data: Data) throws {
    var offset = 0
    while offset < data.count {
        let written = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return Darwin.write(fd, base.advanced(by: offset), data.count - offset)
        }
        if written <= 0 { throw UnixHTTPClientError.connectFailed }
        offset += written
    }
}

private func readAll(fd: Int32) throws -> Data {
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 4_096)
    while true {
        let count = chunk.withUnsafeMutableBytes { raw in
            Darwin.read(fd, raw.baseAddress, raw.count)
        }
        if count == 0 { break }
        if count < 0 { throw UnixHTTPClientError.incompleteResponse }
        buffer.append(contentsOf: chunk.prefix(count))
        if buffer.count > 2_000_000 { throw UnixHTTPClientError.incompleteResponse }
    }
    return buffer
}

private func parseHTTPResponse(_ buffer: Data) throws -> UnixHTTPResponse {
    let separator = Data("\r\n\r\n".utf8)
    guard let headerRange = buffer.range(of: separator),
          let headerText = String(data: buffer.subdata(in: buffer.startIndex..<headerRange.lowerBound), encoding: .utf8)
    else {
        throw UnixHTTPClientError.invalidResponse
    }
    let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
    guard let statusLine = lines.first else { throw UnixHTTPClientError.invalidResponse }
    let statusParts = statusLine.split(separator: " ", maxSplits: 2)
    guard statusParts.count >= 2, let statusCode = Int(statusParts[1]) else {
        throw UnixHTTPClientError.invalidResponse
    }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
        let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        headers[name] = value
    }
    let body = buffer.subdata(in: headerRange.upperBound..<buffer.endIndex)
    return UnixHTTPResponse(statusCode: statusCode, headers: headers, body: body)
}

private func pngDimensions(_ data: Data) -> (Int, Int)? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
        return nil
    }
    return (image.width, image.height)
}

private func posixMode(_ path: String) -> Int? {
    var st = stat()
    guard lstat(path, &st) == 0 else { return nil }
    return Int(st.st_mode & 0o777)
}

@MainActor
private func pickWindow(
    _ session: DesktopCaptureSession,
    _ fake: FakeDesktopCaptureService,
    _ surface: CaptureSurface
) {
    session.selectWindow()
    fake.simulateUserSelection(surface)
}

private func makeSurface(windowID: UInt32, title: String) -> CaptureSurface {
    CaptureSurface(surfaceID: CaptureSurfaceID(windowID: windowID), title: title)
}

private func makeStill(surface: CaptureSurface) -> CapturedStill {
    CapturedStill(captureID: UUID(), surfaceID: surface.surfaceID, capturedAt: Date(), image: makePixel())
}

private func makePixel() -> CGImage {
    let space = CGColorSpaceCreateDeviceRGB()
    guard
        let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ),
        let image = context.makeImage()
    else {
        fatalError("Unable to create a 1×1 test still")
    }
    return image
}

@MainActor
private final class FakeDesktopCaptureService: DesktopCaptureServicing {
    weak var delegate: DesktopCaptureServiceDelegate?
    var availability: CaptureAvailability = .ready
    private(set) var captureCount = 0
    private var pendingCompletion: (@MainActor (Result<CapturedStill, DesktopCaptureFailure>) -> Void)?

    func presentWindowPicker() {}

    func captureStill(
        surface: CaptureSurface,
        completion: @escaping @MainActor (Result<CapturedStill, DesktopCaptureFailure>) -> Void
    ) {
        captureCount += 1
        pendingCompletion = completion
    }

    func currentAvailability() -> CaptureAvailability {
        availability
    }

    func simulateUserSelection(_ surface: CaptureSurface) {
        delegate?.desktopCaptureServiceDidSelect(surface)
    }

    func simulateSurfaceUnavailable(_ surface: CaptureSurface) {
        delegate?.desktopCaptureServiceSurfaceBecameUnavailable(surface)
    }

    func completePending(_ result: Result<CapturedStill, DesktopCaptureFailure>) {
        let completion = pendingCompletion
        pendingCompletion = nil
        completion?(result)
    }
}
