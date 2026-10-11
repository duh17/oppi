import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

struct DesktopH264EncodeCommand: Equatable, Sendable {
    var frameId: UInt32
    var bitrate: Int
    var fps: Double
    var scale: Double
    var keyframe: Bool
}

protocol DesktopFrameEncoding: AnyObject {
    func encode(
        buffer: CVPixelBuffer,
        capturedAt: Date,
        command: DesktopH264EncodeCommand,
        deliver: @escaping (Data) -> Void
    )
    func invalidate()
}

/// Per-frame box retained as `sourceFrameRefcon`. The output callback must not touch encoder state.
private final class DesktopH264EncodedFrameBox {
    let command: DesktopH264EncodeCommand
    let capturedAt: Date
    let width: Int
    let height: Int
    let deliver: (Data) -> Void

    init(
        command: DesktopH264EncodeCommand,
        capturedAt: Date,
        width: Int,
        height: Int,
        deliver: @escaping (Data) -> Void
    ) {
        self.command = command
        self.capturedAt = capturedAt
        self.width = width
        self.height = height
        self.deliver = deliver
    }
}

/// Hardware H.264, low-latency, no B-frames. Bitrate/fps via session properties.
/// `lock` guards only the session handle. No VideoToolbox call runs under it.
final class DesktopH264Encoder: DesktopFrameEncoding, @unchecked Sendable {
    private let lock = NSLock()
    private var session: VTCompressionSession?
    private var width = 0
    private var height = 0
    private var bitrate = 0
    private var fps = 0.0
    private(set) var lastCreateStatus: OSStatus = noErr
    private(set) var lastEncodeStatus: OSStatus = noErr

    private static func handleOutput(
        _ refcon: UnsafeMutableRawPointer?,
        _ status: OSStatus,
        _ sampleBuffer: CMSampleBuffer?
    ) {
        guard let refcon else { return }
        let box = Unmanaged<DesktopH264EncodedFrameBox>.fromOpaque(refcon).takeRetainedValue()
        guard status == noErr, let sampleBuffer else { return }
        if let frame = companionMediaFrame(box: box, sampleBuffer: sampleBuffer) {
            box.deliver(frame)
        }
    }

    private static let outputCallback: VTCompressionOutputCallback = { _, sourceFrameRefcon, status, _, sampleBuffer in
        DesktopH264Encoder.handleOutput(sourceFrameRefcon, status, sampleBuffer)
    }

    func encode(
        buffer: CVPixelBuffer,
        capturedAt: Date,
        command: DesktopH264EncodeCommand,
        deliver: @escaping (Data) -> Void
    ) {
        let frameWidth = CVPixelBufferGetWidth(buffer)
        let frameHeight = CVPixelBufferGetHeight(buffer)

        var sessionToUse: VTCompressionSession?
        var sessionToRetire: VTCompressionSession?

        lock.lock()
        if session == nil || frameWidth != width || frameHeight != height {
            sessionToRetire = session
            session = nil
            lock.unlock()
            guard let created = Self.makeSession(
                width: frameWidth,
                height: frameHeight,
                bitrate: command.bitrate,
                fps: command.fps,
                statusOut: &lastCreateStatus
            ) else {
                if let sessionToRetire {
                    VTCompressionSessionCompleteFrames(sessionToRetire, untilPresentationTimeStamp: .invalid)
                    VTCompressionSessionInvalidate(sessionToRetire)
                }
                return
            }
            lock.lock()
            let raced = session
            session = created
            width = frameWidth
            height = frameHeight
            bitrate = command.bitrate
            fps = command.fps
            sessionToUse = created
            lock.unlock()
            sessionToRetire = raced ?? sessionToRetire
        } else {
            sessionToUse = session
            let applyBitrate = command.bitrate != bitrate
            let applyFps = command.fps != fps
            bitrate = command.bitrate
            fps = command.fps
            lock.unlock()
            if let sessionToUse, applyBitrate || applyFps {
                Self.applyRate(sessionToUse, bitrate: command.bitrate, fps: command.fps, applyBitrate: applyBitrate, applyFps: applyFps)
            }
        }

        if let sessionToRetire {
            VTCompressionSessionCompleteFrames(sessionToRetire, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(sessionToRetire)
        }
        guard let sessionToUse else { return }

        let box = DesktopH264EncodedFrameBox(
            command: command,
            capturedAt: capturedAt,
            width: frameWidth,
            height: frameHeight,
            deliver: deliver
        )
        let refcon = Unmanaged.passRetained(box).toOpaque()
        let pts = CMClockGetTime(CMClockGetHostTimeClock())
        let duration = CMTime(seconds: command.fps > 0 ? 1 / command.fps : 1 / 30, preferredTimescale: 90_000)
        var frameProperties: CFDictionary?
        if command.keyframe {
            frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }
        let status = VTCompressionSessionEncodeFrame(
            sessionToUse,
            imageBuffer: buffer,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: frameProperties,
            sourceFrameRefcon: refcon,
            infoFlagsOut: nil
        )
        lastEncodeStatus = status
        if status != noErr {
            Unmanaged<DesktopH264EncodedFrameBox>.fromOpaque(refcon).release()
        }
    }

    func completeFrames() {
        lock.lock()
        let current = session
        lock.unlock()
        if let current {
            VTCompressionSessionCompleteFrames(current, untilPresentationTimeStamp: .invalid)
        }
    }

    func invalidate() {
        lock.lock()
        let current = session
        session = nil
        lock.unlock()
        if let current {
            VTCompressionSessionCompleteFrames(current, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(current)
        }
    }

    func copyAverageBitRate() -> Int? {
        lock.lock()
        let current = session
        lock.unlock()
        guard let current else { return nil }
        var value: CFTypeRef?
        let status = VTSessionCopyProperty(
            current,
            key: kVTCompressionPropertyKey_AverageBitRate,
            allocator: nil,
            valueOut: &value
        )
        guard status == noErr, let number = value as? NSNumber else { return nil }
        return number.intValue
    }

    func copyProfileLevel() -> String? {
        lock.lock()
        let current = session
        lock.unlock()
        guard let current else { return nil }
        var value: CFTypeRef?
        let status = VTSessionCopyProperty(
            current,
            key: kVTCompressionPropertyKey_ProfileLevel,
            allocator: nil,
            valueOut: &value
        )
        guard status == noErr else { return nil }
        return value as? String
    }

    deinit {
        invalidate()
    }

    private static func makeSession(
        width: Int,
        height: Int,
        bitrate: Int,
        fps: Double,
        statusOut: inout OSStatus
    ) -> VTCompressionSession? {
        var created: VTCompressionSession?
        let encoderSpecification: [CFString: Any] = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: kCFBooleanTrue as Any,
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue as Any,
        ]
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: encoderSpecification as CFDictionary,
            imageBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
            ] as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: outputCallback,
            refcon: nil,
            compressionSessionOut: &created
        )
        statusOut = status
        guard status == noErr, let created else { return nil }
        // Low-latency rate control documents High profile only.
        let required: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel),
        ]
        for (key, value) in required {
            let setStatus = VTSessionSetProperty(created, key: key, value: value)
            if setStatus != noErr {
                VTCompressionSessionInvalidate(created)
                return nil
            }
        }
        if !applyRate(created, bitrate: bitrate, fps: fps, applyBitrate: true, applyFps: true) {
            VTCompressionSessionInvalidate(created)
            return nil
        }
        VTCompressionSessionPrepareToEncodeFrames(created)
        return created
    }

    @discardableResult
    private static func applyRate(
        _ session: VTCompressionSession,
        bitrate: Int,
        fps: Double,
        applyBitrate: Bool,
        applyFps: Bool
    ) -> Bool {
        if applyBitrate {
            let rateStatus = VTSessionSetProperty(
                session,
                key: kVTCompressionPropertyKey_AverageBitRate,
                value: bitrate as CFNumber
            )
            if rateStatus != noErr {
                return false
            }
            let bytes = max(1, bitrate / 8) as CFNumber
            let window = 1 as CFNumber
            // Low-latency rate control may reject DataRateLimits; keep AverageBitRate.
            _ = VTSessionSetProperty(
                session,
                key: kVTCompressionPropertyKey_DataRateLimits,
                value: [bytes, window] as CFArray
            )
        }
        if applyFps {
            let fpsStatus = VTSessionSetProperty(
                session,
                key: kVTCompressionPropertyKey_ExpectedFrameRate,
                value: fps as CFNumber
            )
            if fpsStatus != noErr {
                return false
            }
        }
        return true
    }

    private static func companionMediaFrame(
        box: DesktopH264EncodedFrameBox,
        sampleBuffer: CMSampleBuffer
    ) -> Data? {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let keyframe = box.command.keyframe || isKeyframe(sampleBuffer)
        var parameterSets = Data()
        if keyframe {
            guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let sets = lengthPrefixedParameterSets(from: format)
            else {
                return nil
            }
            parameterSets = sets
        }
        let blockLength = CMBlockBufferGetDataLength(dataBuffer)
        let payloadBytes = parameterSets.count + blockLength
        let companionLength = 1 + DesktopViewStreamWire.mediaHeaderBytes + payloadBytes
        var data = Data(count: 4 + companionLength)
        let copied = data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var length = UInt32(companionLength).bigEndian
            memcpy(base, &length, 4)
            base.storeBytes(of: DesktopViewStreamWire.mediaType, toByteOffset: 4, as: UInt8.self)
            var header = Data(count: DesktopViewStreamWire.mediaHeaderBytes)
            DesktopViewStreamWire.writeMediaHeader(
                DesktopViewStreamWire.MediaHeader(
                    keyframe: keyframe,
                    frameId: box.command.frameId,
                    capturedAtMs: UInt64(box.capturedAt.timeIntervalSince1970 * 1000),
                    width: UInt16(box.width),
                    height: UInt16(box.height),
                    payloadBytes: UInt32(payloadBytes)
                ),
                payloadBytes: UInt32(payloadBytes),
                into: &header,
                at: 0
            )
            header.withUnsafeBytes { bytes in
                guard let src = bytes.baseAddress else { return }
                base.advanced(by: 5).copyMemory(from: src, byteCount: DesktopViewStreamWire.mediaHeaderBytes)
            }
            if !parameterSets.isEmpty {
                parameterSets.withUnsafeBytes { bytes in
                    guard let src = bytes.baseAddress else { return }
                    base.advanced(by: 5 + DesktopViewStreamWire.mediaHeaderBytes)
                        .copyMemory(from: src, byteCount: parameterSets.count)
                }
            }
            let dest = base.advanced(by: 5 + DesktopViewStreamWire.mediaHeaderBytes + parameterSets.count)
            let copyStatus = CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: blockLength, destination: dest)
            return copyStatus == noErr
        }
        return copied ? data : nil
    }

    private static func lengthPrefixedParameterSets(from format: CMFormatDescription) -> Data? {
        var count = 0
        var naluHeaderLength: Int32 = 0
        let probe = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: &naluHeaderLength
        )
        guard probe == noErr, naluHeaderLength == 4, count > 0 else { return nil }
        var out = Data()
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )
            guard status == noErr, let pointer, size > 0 else { return nil }
            var length = UInt32(size).bigEndian
            out.append(Data(bytes: &length, count: 4))
            out.append(pointer, count: size)
        }
        return out
    }

    private static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first
        else {
            return false
        }
        let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool
        return notSync != true
    }
}
