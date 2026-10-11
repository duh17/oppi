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

/// Hardware H.264, low-latency, no B-frames. Bitrate/fps via session properties.
final class DesktopH264Encoder: @unchecked Sendable {
    private let lock = NSLock()
    private var session: VTCompressionSession?
    private var format: CMFormatDescription?
    private var width = 0
    private var height = 0
    private var bitrate = 0
    private var fps = 0.0
    private(set) var rebuildCount = 0
    private var pending: [PendingEncode] = []

    var sessionEpoch: Int { rebuildCount }

    private struct PendingEncode {
        var command: DesktopH264EncodeCommand
        var capturedAt: Date
        var width: Int
        var height: Int
        var deliver: (Data) -> Void
    }

    private static let outputCallback: VTCompressionOutputCallback = { refcon, _, status, _, sampleBuffer in
        guard let refcon else { return }
        let encoder = Unmanaged<DesktopH264Encoder>.fromOpaque(refcon).takeUnretainedValue()
        encoder.handleOutput(status: status, sampleBuffer: sampleBuffer)
    }

    func encode(
        buffer: CVPixelBuffer,
        capturedAt: Date,
        command: DesktopH264EncodeCommand,
        deliver: @escaping (Data) -> Void
    ) {
        let frameWidth = CVPixelBufferGetWidth(buffer)
        let frameHeight = CVPixelBufferGetHeight(buffer)
        lock.lock()
        if session == nil || frameWidth != width || frameHeight != height {
            recreateLocked(width: frameWidth, height: frameHeight, bitrate: command.bitrate, fps: command.fps)
        } else {
            applyRateLocked(bitrate: command.bitrate, fps: command.fps)
        }
        guard let current = session else {
            lock.unlock()
            return
        }
        pending.append(
            PendingEncode(
                command: command,
                capturedAt: capturedAt,
                width: frameWidth,
                height: frameHeight,
                deliver: deliver
            )
        )
        lock.unlock()

        let pts = CMTime(seconds: capturedAt.timeIntervalSince1970, preferredTimescale: 90_000)
        let duration = CMTime(seconds: command.fps > 0 ? 1 / command.fps : 1 / 30, preferredTimescale: 90_000)
        var frameProperties: CFDictionary?
        if command.keyframe {
            frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }
        _ = VTCompressionSessionEncodeFrame(
            current,
            imageBuffer: buffer,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: frameProperties,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
    }

    func completeFrames() {
        lock.lock()
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        }
        lock.unlock()
    }

    func invalidate() {
        lock.lock()
        if let session {
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        format = nil
        lock.unlock()
    }

    deinit {
        invalidate()
    }

    private func recreateLocked(width: Int, height: Int, bitrate: Int, fps: Double) {
        if let session {
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
            ] as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: Self.outputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &created
        )
        guard status == noErr, let created else { return }
        session = created
        self.width = width
        self.height = height
        rebuildCount += 1
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(
            created,
            key: kVTCompressionPropertyKey_ProfileLevel,
            value: kVTProfileLevel_H264_Baseline_AutoLevel
        )
        applyRateLocked(bitrate: bitrate, fps: fps)
        VTCompressionSessionPrepareToEncodeFrames(created)
    }

    private func applyRateLocked(bitrate: Int, fps: Double) {
        guard let session else { return }
        if bitrate != self.bitrate {
            let rate = bitrate as CFNumber
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: rate)
            let bytes = max(1, bitrate / 8) as CFNumber
            let window = 1 as CFNumber
            VTSessionSetProperty(
                session,
                key: kVTCompressionPropertyKey_DataRateLimits,
                value: [bytes, window] as CFArray
            )
            self.bitrate = bitrate
        }
        if fps != self.fps {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
            self.fps = fps
        }
    }

    private func handleOutput(status: OSStatus, sampleBuffer: CMSampleBuffer?) {
        lock.lock()
        let item = pending.isEmpty ? nil : pending.removeFirst()
        lock.unlock()
        guard status == noErr, let sampleBuffer, let item else { return }
        let keyframe = item.command.keyframe || Self.isKeyframe(sampleBuffer)
        guard let annexB = annexB(from: sampleBuffer, keyframe: keyframe) else { return }
        let header = DesktopViewStreamWire.MediaHeader(
            keyframe: keyframe,
            frameId: item.command.frameId,
            capturedAtMs: UInt64(item.capturedAt.timeIntervalSince1970 * 1000),
            width: UInt16(item.width),
            height: UInt16(item.height),
            payloadBytes: UInt32(annexB.count)
        )
        item.deliver(DesktopViewStreamWire.mediaCompanionFrame(header: header, annexB: annexB))
    }

    private func annexB(from sampleBuffer: CMSampleBuffer, keyframe: Bool) -> Data? {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer) == noErr,
              let dataPointer
        else {
            return nil
        }
        let avcc = Data(bytes: dataPointer, count: length)
        var startCodes = Data()
        if keyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            self.format = format
            startCodes.append(parameterSets(from: format))
        } else if keyframe, let format {
            startCodes.append(parameterSets(from: format))
        }
        startCodes.append(avccToAnnexB(avcc))
        return startCodes
    }

    private func parameterSets(from format: CMFormatDescription) -> Data {
        var out = Data()
        var count = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: nil
        )
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
            guard status == noErr, let pointer, size > 0 else { continue }
            out.append(contentsOf: [0, 0, 0, 1])
            out.append(pointer, count: size)
        }
        return out
    }

    private func avccToAnnexB(_ avcc: Data) -> Data {
        var offset = 0
        var out = Data()
        let bytes = [UInt8](avcc)
        while offset + 4 <= bytes.count {
            let naluLength = Int(bytes[offset]) << 24
                | Int(bytes[offset + 1]) << 16
                | Int(bytes[offset + 2]) << 8
                | Int(bytes[offset + 3])
            offset += 4
            guard naluLength > 0, offset + naluLength <= bytes.count else { break }
            out.append(contentsOf: [0, 0, 0, 1])
            out.append(contentsOf: bytes[offset..<(offset + naluLength)])
            offset += naluLength
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
