import CoreVideo
import Foundation
import Testing
@testable import Oppi

@Suite("Desktop H.264 encoder")
struct DesktopH264EncoderTests {
    @Test func encodesAvccIdrThenPThenForcedIdrAndAppliesBitrate() throws {
        let encoder = DesktopH264Encoder()
        defer { encoder.invalidate() }
        let buffer = try makeNV12(width: 128, height: 96, seed: 3)

        let first = try encodeAndWait(
            encoder,
            buffer: buffer,
            command: DesktopH264EncodeCommand(frameId: 1, bitrate: 400_000, fps: 10, scale: 1, keyframe: true)
        )
        let firstNals = try nalUnits(fromCompanionMedia: first)
        #expect(firstNals.contains { $0.type == 7 })
        #expect(firstNals.contains { $0.type == 8 })
        #expect(firstNals.contains { $0.type == 5 })
        #expect(try mediaKeyframe(first) == true)

        let second = try encodeAndWait(
            encoder,
            buffer: try makeNV12(width: 128, height: 96, seed: 9),
            command: DesktopH264EncodeCommand(frameId: 2, bitrate: 1_200_000, fps: 24, scale: 1, keyframe: false)
        )
        let secondNals = try nalUnits(fromCompanionMedia: second)
        #expect(!secondNals.contains { $0.type == 5 })
        #expect(secondNals.contains { $0.type == 1 })
        #expect(try mediaKeyframe(second) == false)

        let forced = try encodeAndWait(
            encoder,
            buffer: try makeNV12(width: 128, height: 96, seed: 12),
            command: DesktopH264EncodeCommand(frameId: 3, bitrate: 1_200_000, fps: 24, scale: 1, keyframe: true)
        )
        let forcedNals = try nalUnits(fromCompanionMedia: forced)
        #expect(forcedNals.contains { $0.type == 7 })
        #expect(forcedNals.contains { $0.type == 8 })
        #expect(forcedNals.contains { $0.type == 5 })

        #expect(encoder.copyAverageBitRate() == 1_200_000)
        let profile = try #require(encoder.copyProfileLevel())
        #expect(profile.contains("High"))
    }
}

private enum EncoderTestError: Error, CustomStringConvertible {
    case pixelBuffer
    case noSample(create: OSStatus, encode: OSStatus)
    case framing

    var description: String {
        switch self {
        case .pixelBuffer: "pixelBuffer"
        case .noSample(let create, let encode): "noSample create=\(create) encode=\(encode)"
        case .framing: "framing"
        }
    }
}

private func encodeAndWait(
    _ encoder: DesktopH264Encoder,
    buffer: CVPixelBuffer,
    command: DesktopH264EncodeCommand
) throws -> Data {
    let box = OnceBox<Data>()
    encoder.encode(buffer: buffer, capturedAt: Date(), command: command) { data in
        box.complete(data)
    }
    encoder.completeFrames()
    guard let data = box.wait(seconds: 8) else {
        throw EncoderTestError.noSample(
            create: encoder.lastCreateStatus,
            encode: encoder.lastEncodeStatus
        )
    }
    return data
}

private final class OnceBox<T>: @unchecked Sendable {
    private let condition = NSCondition()
    private var value: T?

    func complete(_ value: T) {
        condition.lock()
        self.value = value
        condition.broadcast()
        condition.unlock()
    }

    func wait(seconds: TimeInterval) -> T? {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(seconds)
        while value == nil {
            if !condition.wait(until: deadline) { return nil }
        }
        return value
    }
}

private struct NAL {
    var type: Int
    var bytes: Data
}

private func mediaKeyframe(_ companion: Data) throws -> Bool {
    guard companion.count >= 5 + DesktopViewStreamWire.mediaHeaderBytes else { throw EncoderTestError.framing }
    let payload = companion.subdata(in: 5..<companion.count)
    return payload[1] & DesktopViewStreamWire.flagKeyframe != 0
}

private func nalUnits(fromCompanionMedia companion: Data) throws -> [NAL] {
    guard companion.count >= 5 + DesktopViewStreamWire.mediaHeaderBytes else { throw EncoderTestError.framing }
    let payload = companion.subdata(in: 5..<companion.count)
    let payloadBytes = Int(readUInt32BE(payload, at: 20))
    let avccStart = DesktopViewStreamWire.mediaHeaderBytes
    guard payload.count >= avccStart + payloadBytes else { throw EncoderTestError.framing }
    let avcc = payload.subdata(in: avccStart..<(avccStart + payloadBytes))
    var offset = 0
    var nals: [NAL] = []
    while offset + 4 <= avcc.count {
        let length = Int(readUInt32BE(avcc, at: offset))
        offset += 4
        guard length > 0, offset + length <= avcc.count else { throw EncoderTestError.framing }
        let bytes = avcc.subdata(in: offset..<(offset + length))
        nals.append(NAL(type: Int(bytes[0] & 0x1F), bytes: bytes))
        offset += length
    }
    return nals
}

private func makeNV12(width: Int, height: Int, seed: UInt8) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        nil,
        &buffer
    )
    guard status == kCVReturnSuccess, let buffer else { throw EncoderTestError.pixelBuffer }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    if let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
        let bytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) * height
        memset(y, Int32(seed), bytes)
    }
    if let uv = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
        let bytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * (height / 2)
        memset(uv, 128, bytes)
    }
    return buffer
}
