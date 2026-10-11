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
    func startLiveView(
        offer: @escaping @Sendable (CVPixelBuffer, Date) -> Void,
        ended: @escaping @Sendable () -> Void,
        fps: Double,
        scale: Double
    )
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
    private var generation: UInt64 = 0
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
        generation &+= 1
        let attachedGeneration = generation
        stopped = false
        pending = nil
        held = nil
        lastEncodedCapturedAt = nil
        lastFps = 30
        lastScale = 1
        lock.unlock()
        encoder.prepare()
        grantGate.setLiveDelivery(true)
        capturer?.startLiveView(offer: { [weak self] buffer, capturedAt in
            self?.offer(buffer, capturedAt: capturedAt)
        }, ended: { [weak self] in
            self?.fail(code: DesktopViewStreamWire.errorSurfaceGone, message: "Desktop view surface gone")
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
            writeAll(frame, generation: attachedGeneration)
        }

        readQueue.async { [weak self] in
            self?.readLoop(expectedDevice: deviceId, fd: fd, generation: attachedGeneration)
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
        let gen = generation
        lock.unlock()
        if let command {
            startEncode(buffer: buffer, capturedAt: capturedAt, command: command, generation: gen)
        }
    }

    private func readLoop(expectedDevice: String, fd attachedFd: Int32, generation attachedGeneration: UInt64) {
        var chunk = [UInt8](repeating: 0, count: 16_384)
        let reader = DesktopViewCompanionReader()
        while true {
            if let grant = grantGate.current() {
                if grant.deviceId != expectedDevice {
                    fail(code: DesktopViewStreamWire.errorGrantRevoked, message: "View grant revoked")
                }
            } else {
                fail(code: DesktopViewStreamWire.errorGrantExpired, message: "View grant expired")
            }
            let count = chunk.withUnsafeMutableBytes { raw in
                Darwin.read(attachedFd, raw.baseAddress, raw.count)
            }
            if count < 0, errno == EINTR { continue }

            lock.lock()
            let stillMine = generation == attachedGeneration
            let isStopped = stopped
            lock.unlock()

            if count <= 0 || isStopped || !stillMine {
                if stillMine, !isStopped {
                    fail(code: DesktopViewStreamWire.errorSurfaceGone, message: "Desktop view companion closed")
                }
                Darwin.close(attachedFd)
                return
            }
            let frames: [(type: UInt8, payload: Data)]
            do {
                frames = try reader.push(Data(chunk.prefix(count)))
            } catch {
                fail(code: DesktopViewStreamWire.errorProtocolFatal, message: "Desktop view framing is invalid")
                continue
            }
            for frame in frames {
                handle(frame: frame, generation: attachedGeneration)
            }
        }
    }

    private func handle(frame: (type: UInt8, payload: Data), generation attachedGeneration: UInt64) {
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
            guard !stopped, generation == attachedGeneration else {
                lock.unlock()
                return
            }
            let fpsChanged = lastFps != command.fps
            let scaleChanged = lastScale != command.scale
            lastFps = command.fps
            lastScale = command.scale
            pending = command
            let taken = takePendingLocked(allowStale: command.keyframe)
            let frame = held
            let gen = generation
            lock.unlock()
            if fpsChanged || scaleChanged {
                capturer?.updateLiveView(fps: command.fps, scale: command.scale)
            }
            if let taken, let frame {
                startEncode(buffer: frame.buffer, capturedAt: frame.capturedAt, command: taken, generation: gen)
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
        if stopped {
            lock.unlock()
            return
        }
        let taken = takePendingLocked(allowStale: true)
        let held = self.held
        let gen = generation
        lock.unlock()
        if let taken, let held {
            startEncode(buffer: held.buffer, capturedAt: held.capturedAt, command: taken, generation: gen)
        }
    }

    private func startEncode(
        buffer: CVPixelBuffer,
        capturedAt: Date,
        command: DesktopH264EncodeCommand,
        generation expected: UInt64
    ) {
        encoder.encode(buffer: buffer, capturedAt: capturedAt, command: command) { [weak self] data in
            self?.writeAll(data, generation: expected)
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
        generation &+= 1
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
        }
    }

    private func writeAll(_ data: Data, generation expected: UInt64? = nil, fd override: Int32? = nil) {
        writeLock.lock()
        lock.lock()
        let current = override ?? fd
        let matches = override != nil || (expected != nil && expected == generation)
        lock.unlock()
        var failed = false
        if matches, current >= 0 {
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
