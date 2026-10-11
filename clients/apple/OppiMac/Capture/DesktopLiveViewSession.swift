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
    func attach(fd: Int32, deviceId: String) -> Result<Void, DesktopLiveViewAttachFailure>
    func stop()
}

protocol DesktopLiveViewCapturing: AnyObject {
    func startLiveView(offer: @escaping @Sendable (CVPixelBuffer, Date) -> Void, fps: Double, scale: Double)
    func updateLiveView(fps: Double, scale: Double)
    func stopLiveView()
}

final class DesktopLiveViewSource: @unchecked Sendable {
    struct Snapshot: Equatable, Sendable {
        var surface: CaptureSurface
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
    private let grantGate: DesktopViewGrantGate
    private let source: DesktopLiveViewSource
    private let encoder: any DesktopFrameEncoding
    private let capturer: (any DesktopLiveViewCapturing)?
    private let readQueue = DispatchQueue(label: "dev.chenda.OppiMac.live-view.read")
    private let timerQueue = DispatchQueue(label: "dev.chenda.OppiMac.live-view.timer")
    private let lock = NSLock()
    private let writeLock = NSLock()
    private var fd: Int32 = -1
    private var pending: DesktopH264EncodeCommand?
    private var held: (buffer: CVPixelBuffer, capturedAt: Date)?
    private var lastEncodedCapturedAt: Date?
    private var lastFps: Double?
    private var lastScale: Double?
    private var stopped = true
    private var idleWork: DispatchWorkItem?
    private var expiryWork: DispatchWorkItem?

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !stopped && fd >= 0
    }

    init(
        grantGate: DesktopViewGrantGate,
        source: DesktopLiveViewSource,
        encoder: any DesktopFrameEncoding = DesktopH264Encoder(),
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

    func attach(fd: Int32, deviceId: String) -> Result<Void, DesktopLiveViewAttachFailure> {
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
        pending = nil
        held = nil
        lastEncodedCapturedAt = nil
        lastFps = 30
        lastScale = 1
        lock.unlock()
        grantGate.setLiveDelivery(true)
        capturer?.startLiveView(offer: { [weak self] buffer, capturedAt in
            self?.offer(buffer, capturedAt: capturedAt)
        }, fps: 30, scale: 1)
        scheduleExpiry(grant.expiresAt)

        let hello: [String: Any] = [
            "type": "hello",
            "version": Int(DesktopViewStreamWire.version),
            "features": [DesktopViewStreamWire.featureAvcc],
            "grantId": grant.grantId.uuidString,
            "deviceId": deviceId,
            "surface": [
                "windowId": Int(snapshot.surface.surfaceID.windowID),
                "title": snapshot.surface.title,
            ],
            "expiresAt": DesktopStillShareHTTP.date(grant.expiresAt),
        ]
        if let frame = DesktopViewStreamWire.jsonFrame(hello) {
            writeAll(frame)
        }

        readQueue.async { [weak self] in
            self?.readLoop(expectedDevice: deviceId)
        }
        return .success(())
    }

    func stop() {
        fail(code: DesktopViewStreamWire.errorSurfaceGone, message: "Desktop view stopped")
    }

    func offer(_ buffer: CVPixelBuffer, capturedAt: Date) {
        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        held = (buffer, capturedAt)
        let command = takePendingLocked(allowStale: false)
        lock.unlock()
        if let command {
            startEncode(buffer: buffer, capturedAt: capturedAt, command: command)
        }
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
            if let grant = grantGate.current() {
                if grant.deviceId != expectedDevice {
                    fail(code: DesktopViewStreamWire.errorGrantRevoked, message: "View grant revoked")
                    return
                }
            } else {
                fail(code: DesktopViewStreamWire.errorGrantExpired, message: "View grant expired")
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
                fail(code: DesktopViewStreamWire.errorProtocolFatal, message: "Desktop view framing is invalid")
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
            lock.lock()
            let fpsChanged = lastFps != command.fps
            let scaleChanged = lastScale != command.scale
            lastFps = command.fps
            lastScale = command.scale
            pending = command
            let taken = takePendingLocked(allowStale: command.keyframe)
            let frame = held
            lock.unlock()
            if fpsChanged || scaleChanged {
                capturer?.updateLiveView(fps: command.fps, scale: command.scale)
            }
            if let taken, let frame {
                startEncode(buffer: frame.buffer, capturedAt: frame.capturedAt, command: taken)
            } else {
                armIdleRefresh()
            }
        }
    }

    private func takePendingLocked(allowStale: Bool) -> DesktopH264EncodeCommand? {
        guard let command = pending, let held else { return nil }
        if !allowStale, let last = lastEncodedCapturedAt, held.capturedAt <= last {
            return nil
        }
        pending = nil
        lastEncodedCapturedAt = held.capturedAt
        idleWork?.cancel()
        idleWork = nil
        return command
    }

    private func armIdleRefresh() {
        idleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.idleEncode()
        }
        idleWork = work
        timerQueue.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func idleEncode() {
        lock.lock()
        let taken = takePendingLocked(allowStale: true)
        let held = self.held
        lock.unlock()
        if let taken, let held {
            startEncode(buffer: held.buffer, capturedAt: held.capturedAt, command: taken)
        }
    }

    private func startEncode(buffer: CVPixelBuffer, capturedAt: Date, command: DesktopH264EncodeCommand) {
        encoder.encode(buffer: buffer, capturedAt: capturedAt, command: command) { [weak self] data in
            self?.writeAll(data)
        }
    }

    private func scheduleExpiry(_ expiresAt: Date) {
        expiryWork?.cancel()
        let delay = expiresAt.timeIntervalSinceNow
        let work = DispatchWorkItem { [weak self] in
            self?.fail(code: DesktopViewStreamWire.errorGrantExpired, message: "View grant expired")
        }
        expiryWork = work
        if delay <= 0 {
            timerQueue.async(execute: work)
        } else {
            timerQueue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func fail(code: Int, message: String) {
        lock.lock()
        let current = fd
        let already = stopped
        stopped = true
        fd = -1
        pending = nil
        held = nil
        idleWork?.cancel()
        idleWork = nil
        expiryWork?.cancel()
        expiryWork = nil
        lock.unlock()
        if already { return }
        grantGate.setLiveDelivery(false)
        capturer?.stopLiveView()
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
        writeLock.lock()
        lock.lock()
        let current = override ?? fd
        lock.unlock()
        var failed = false
        if current >= 0 {
            var offset = 0
            while offset < data.count {
                let written = data.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return Darwin.write(current, base.advanced(by: offset), data.count - offset)
                }
                if written < 0 {
                    if errno == EINTR { continue }
                    failed = true
                    break
                }
                if written == 0 {
                    failed = true
                    break
                }
                offset += written
            }
        }
        writeLock.unlock()
        if failed {
            fail(code: DesktopViewStreamWire.errorSurfaceGone, message: "Desktop view companion closed")
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
