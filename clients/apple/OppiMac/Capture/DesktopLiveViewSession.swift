import CoreVideo
import Darwin
import Foundation

enum DesktopLiveViewAttachFailure: Error, Equatable {
    case unavailable
    case notBound
    case alreadyStreaming
}

protocol DesktopLiveViewStreaming: AnyObject {
    var isActive: Bool { get }
    func attach(fd: Int32, deviceId: String, deviceName: String?) -> Result<Void, DesktopLiveViewAttachFailure>
    func stop()
}

protocol DesktopLiveViewCapturing: AnyObject {
    func startLiveView(mailbox: DesktopLiveViewPixelMailbox, fps: Double, scale: Double)
    func updateLiveView(fps: Double, scale: Double)
    func stopLiveView()
}

final class DesktopLiveViewSource: @unchecked Sendable {
    struct Snapshot: Equatable, Sendable {
        var surface: CaptureSurface
        var width: Int
        var height: Int
    }

    private let lock = NSLock()
    private var snapshot: Snapshot?

    func update(_ snapshot: Snapshot?) {
        lock.lock()
        self.snapshot = snapshot
        lock.unlock()
    }

    func current() -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }
}

final class DesktopLiveViewSession: DesktopLiveViewStreaming, @unchecked Sendable {
    let mailbox = DesktopLiveViewPixelMailbox()
    private let grantGate: DesktopViewGrantGate
    private let source: DesktopLiveViewSource
    private let encoder: DesktopH264Encoder
    private let capturer: (any DesktopLiveViewCapturing)?
    private let queue = DispatchQueue(label: "dev.chenda.OppiMac.live-view")
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var pending: DesktopH264EncodeCommand?
    private var stopped = true

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !stopped && fd >= 0
    }

    init(
        grantGate: DesktopViewGrantGate,
        source: DesktopLiveViewSource,
        encoder: DesktopH264Encoder = DesktopH264Encoder(),
        capturer: (any DesktopLiveViewCapturing)? = nil
    ) {
        self.grantGate = grantGate
        self.source = source
        self.encoder = encoder
        self.capturer = capturer
        grantGate.setInvalidationHandler { [weak self] in
            self?.fail(code: DesktopViewStreamWire.errorGrantRevoked, message: "View grant revoked")
        }
    }

    func attach(fd: Int32, deviceId: String, deviceName: String?) -> Result<Void, DesktopLiveViewAttachFailure> {
        lock.lock()
        if !stopped && self.fd >= 0 {
            lock.unlock()
            return .failure(.alreadyStreaming)
        }
        lock.unlock()
        guard let grant = grantGate.current() else { return .failure(.unavailable) }
        guard let bound = grant.deviceId else { return .failure(.notBound) }
        guard bound == deviceId else { return .failure(.notBound) }
        guard let snapshot = source.current() else { return .failure(.unavailable) }

        var nosig = Int32(1)
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))

        lock.lock()
        self.fd = fd
        stopped = false
        lock.unlock()
        mailbox.reset()
        grantGate.setLiveDelivery(true)
        capturer?.startLiveView(mailbox: mailbox, fps: 30, scale: 1)

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
            "width": snapshot.width,
            "height": snapshot.height,
            "expiresAt": DesktopStillShareHTTP.date(grant.expiresAt),
        ]
        if let frame = DesktopViewStreamWire.jsonFrame(hello) {
            writeAll(frame)
        }

        queue.async { [weak self] in
            self?.readLoop(expectedDevice: deviceId)
        }
        _ = deviceName
        return .success(())
    }

    func stop() {
        fail(code: DesktopViewStreamWire.errorSurfaceGone, message: "Desktop view stopped")
    }

    func offerForTests(_ buffer: CVPixelBuffer) {
        mailbox.offer(buffer)
        encodePendingIfPossible()
    }

    private func readLoop(expectedDevice: String) {
        var chunk = [UInt8](repeating: 0, count: 16_384)
        let reader = DesktopViewCompanionReader()
        while true {
            lock.lock()
            let current = fd
            let isStopped = stopped
            lock.unlock()
            if isStopped || current < 0 { return }
            if grantGate.current()?.deviceId != expectedDevice {
                fail(code: DesktopViewStreamWire.errorGrantRevoked, message: "View grant revoked")
                return
            }
            let count = chunk.withUnsafeMutableBytes { raw in
                Darwin.read(current, raw.baseAddress, raw.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                fail(code: DesktopViewStreamWire.errorSurfaceGone, message: "Desktop view companion closed")
                return
            }
            if count == 0 {
                fail(code: DesktopViewStreamWire.errorSurfaceGone, message: "Desktop view companion closed")
                return
            }
            let frames: [(type: UInt8, payload: Data)]
            do {
                frames = try reader.push(Data(chunk.prefix(count)))
            } catch {
                fail(code: DesktopViewStreamWire.errorGrantRevoked, message: "Desktop view framing is invalid")
                return
            }
            for frame in frames {
                handle(frame: frame)
            }
        }
    }

    private func handle(frame: (type: UInt8, payload: Data)) {
        guard frame.type == DesktopViewStreamWire.jsonType,
              let json = DesktopViewStreamWire.parseJSON(frame.payload),
              let type = json["type"] as? String
        else {
            return
        }
        if type == "encode" {
            let command = DesktopH264EncodeCommand(
                frameId: uint32(json["frameId"]),
                bitrate: intValue(json["bitrate"]) ?? 1_800_000,
                fps: doubleValue(json["fps"]) ?? 30,
                scale: doubleValue(json["scale"]) ?? 1,
                keyframe: json["keyframe"] as? Bool ?? false
            )
            capturer?.updateLiveView(fps: command.fps, scale: command.scale)
            lock.lock()
            pending = command
            lock.unlock()
            encodePendingIfPossible()
        }
    }

    private func encodePendingIfPossible() {
        lock.lock()
        let command = pending
        lock.unlock()
        guard let command, let buffer = mailbox.peek() else { return }
        lock.lock()
        pending = nil
        lock.unlock()
        encoder.encode(buffer: buffer, capturedAt: Date(), command: command) { [weak self] data in
            self?.writeAll(data)
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
        capturer?.stopLiveView()
        mailbox.close()
        encoder.invalidate()
        if current >= 0 {
            if let frame = DesktopViewStreamWire.jsonFrame([
                "type": "error",
                "code": code,
                "message": message,
                "fatal": true,
            ]) {
                writeAll(frame, fd: current)
            }
            Darwin.shutdown(current, SHUT_RDWR)
            Darwin.close(current)
        }
    }

    private func writeAll(_ data: Data, fd override: Int32? = nil) {
        lock.lock()
        let current = override ?? fd
        lock.unlock()
        guard current >= 0 else { return }
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.write(current, base.advanced(by: offset), data.count - offset)
            }
            if written < 0 {
                if errno == EINTR { continue }
                return
            }
            if written == 0 { return }
            offset += written
        }
    }
}

private func uint32(_ value: Any?) -> UInt32 {
    if let number = value as? NSNumber { return number.uint32Value }
    if let int = value as? Int { return UInt32(int) }
    return 0
}

private func intValue(_ value: Any?) -> Int? {
    if let number = value as? NSNumber { return number.intValue }
    return value as? Int
}

private func doubleValue(_ value: Any?) -> Double? {
    if let number = value as? NSNumber { return number.doubleValue }
    return value as? Double
}
